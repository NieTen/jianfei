import Foundation
import Network
import SwiftUI
import UIKit
import Vision

/// 手机端的状态与流程协调入口：页面发起操作，领域层计算，存储与网络层负责副作用。
/// 不在这里重复定义营养、重量等计算规则；完整调用链见 docs/代码导读.md。
@MainActor
final class AppModel: ObservableObject {
    // MARK: - 页面状态、本机偏好与服务依赖
    static let weightUnitPreferenceKey = "preferred_weight_unit"
    @Published private(set) var weightUnit = WeightUnit(rawValue: UserDefaults.standard.string(forKey: AppModel.weightUnitPreferenceKey) ?? "") ?? .kg
    @Published var records: [AppRecord] = []
    @Published private(set) var localDataContext = UUID()
    @Published private(set) var entitlements: JSONObject = [:]
    @Published private(set) var cloudAccount: JSONObject = [:]
    @Published private(set) var cloudAI: JSONObject = [:]
    @Published private(set) var cloudConsent: JSONObject = [:]
    @Published private(set) var cloudReady = false
    @Published private(set) var cloudAccessError: String?
    @Published private(set) var serverDeploymentMode = ""
    private var entitlementLeaseUntil: TimeInterval = 0
    private var cloudRefreshID = UUID()
    private var deploymentChecked = false
    private let officialCloudURL: URL?

    @Published var selectedDate = Date() {
        didSet {
            followingToday = false
            Task { await refreshSelectedSummary() }
        }
    }
    @Published private(set) var recordIndex = RecordIndex(records: [])
    @Published private(set) var dataRevision = 0
    @Published private(set) var selectedSummary = DailySummary(day: TimeFormat.day())
    @Published private(set) var summaryRefreshing = false
    @Published private(set) var activeProfile = BodyProfile()
    @Published var session: SessionCredentials?
    @Published var syncing = false
    @Published var pendingCount = 0
    @Published var syncStatus = "记录保存在本机"
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var conflicts: [SyncConflict] = []
    @Published var challenges: [JSONObject] = []
    @Published var capabilities: JSONObject = [:]
    @Published var deletionPending = false
    @Published private(set) var hasLoadedRecords = false
    @Published private(set) var profileSetupCompleted = false
    @Published var setupCompleted = UserDefaults.standard.object(forKey: "setup_completed") as? Bool
        ?? !(UserDefaults.standard.string(forKey: "server_url") ?? "").isEmpty
    @Published var aiConfiguration = AIConfiguration()
    @Published var aiConfigurationPending = false
    @Published var aiHasServerKey = false
    @Published var availableAIModels: [AIModelOption] = []
    @Published var serverURL = UserDefaults.standard.string(forKey: "server_url") ?? ""
    @Published var syncEnabled = UserDefaults.standard.bool(forKey: "sync_enabled") {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "sync_enabled") }
    }
    @Published var healthEnabled = UserDefaults.standard.bool(forKey: "health_enabled") {
        didSet { UserDefaults.standard.set(healthEnabled, forKey: "health_enabled") }
    }
    @Published var aiMode = UserDefaults.standard.string(forKey: "ai_mode") ?? "device" {
        didSet { UserDefaults.standard.set(aiMode, forKey: "ai_mode") }
    }
    @Published var externalAIConsent = false {
        didSet { UserDefaults.standard.set(externalAIConsent, forKey: "external_ai_consent:" + namespace) }
    }
    let api = APIClient()
    let responses: ResponsesClient
    let health = HealthManager()
    let reminders = ReminderManager()
    let watch = PhoneWatchBridge()
    private(set) var store: LocalDatabase?
    private var syncEngine: SyncEngine?
    private var networkMonitor: NWPathMonitor?
    private var namespace: String
    private var profileSetupNamespace: String?
    private var refreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var syncOperation: Task<SyncReport, Error>?
    private var changingAccount = false
    private var syncContext = UUID()
    private var syncRequested = false
    private var followingToday = true
    private var reloadToken = UUID()
    private var summaryToken = UUID()
    private let thumbnailCache = NSCache<NSString, NSData>()
    var deviceId: String

    // MARK: - 创建当前本地身份的存储及服务回调

    init(responses: ResponsesClient = ResponsesClient(), cloudServerURL: URL? = CloudDeployment.serverURL) {
        self.responses = responses
        self.officialCloudURL = cloudServerURL
        let savedURL = UserDefaults.standard.string(forKey: "server_url") ?? ""
        serverDeploymentMode = UserDefaults.standard.string(forKey: "server_deployment:" + savedURL) ?? ""
        namespace = UserDefaults.standard.string(forKey: "local_namespace") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(namespace, forKey: "local_namespace")
        deviceId = UserDefaults.standard.string(forKey: "device_id") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(deviceId, forKey: "device_id")
        do {
            let database = try LocalDatabase(namespace: namespace)
            store = database
            syncEngine = SyncEngine(api: api, store: database)
        } catch { errorMessage = error.localizedDescription }
        health.onUpdate = { [weak self] in self?.scheduleHealthRefresh() }
        health.onAccessIssue = { [weak self] in self?.healthEnabled = false }
        watch.onRecord = { [weak self] payload in
            guard let self else { throw APIError(code: "PHONE_NOT_READY", message: "请打开手机应用") }
            try await self.receiveWatchRecord(payload)
        }
        ApplicationDelegate.pushTokenHandler = { [weak self] token in
            self?.perform {
                _ = try await self?.api.send("devices/push", method: "POST",
                    body: ["token": .string(token), "enabled": .bool(true)])
            }
        }
        loadAIConfiguration()
        thumbnailCache.totalCostLimit = 12 * 1024 * 1024
        thumbnailCache.countLimit = 100
        BackgroundCoordinator.onRefresh = { [weak self] in
            guard let self else { return false }
            try? await self.processPendingDeletion()
            if self.healthEnabled && !self.deletionPending { try? await self.refreshHealth() }
            if self.syncEnabled { await self.sync() }
            await self.resumePendingRecognition()
            return !Task.isCancelled
        }
    }

    // MARK: - 当前档案、业务日与本机显示单位

    var profile: BodyProfile { activeProfile }
    var editableProfile: BodyProfile { pendingProfileRecord?.decode(BodyProfile.self) ?? profile }
    func setWeightUnit(_ unit: WeightUnit) {
        UserDefaults.standard.set(unit.rawValue, forKey: Self.weightUnitPreferenceKey)
        weightUnit = unit
        publishWatchContext()
    }
    private var pendingProfileRecord: AppRecord? {
        recordIndex.profiles.first {
            ($0.payload["effective_at"]?.string.flatMap(TimeFormat.parse) ?? .distantPast) > Date()
        }
    }
    var day: String {
        TimeFormat.day(followingToday ? Date() : selectedDate, timezone: profile.timezone,
                       startMinutes: followingToday ? profile.dayStartMinutes : 0)
    }
    var displayDate: Date { TimeFormat.window(day, timezone: profile.timezone)?.start ?? selectedDate }
    var entryDate: Date {
        if followingToday { return Date() }
        return RecordDate.timestamp(for: day, profile: profile)
    }
    var summary: DailySummary { selectedSummary.day == day ? selectedSummary : DailySummary(day: day) }
    var goal: GoalEntry { recordIndex.goal }
    var meals: [AppRecord] {
        (recordIndex.byDay[day] ?? []).filter { $0.kind == "meal" }
            .sorted { $0.payload.text("eaten_at") < $1.payload.text("eaten_at") }
    }
    var favorites: [FavoriteFood] {
        (recordIndex.byKind["favorite"] ?? []).compactMap { $0.decode(FavoriteFood.self) }
    }

    // MARK: - 启动、重载与汇总刷新

    func start() async {
        if clockTask == nil {
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                    guard let self else { return }
                    if self.isCloudMode, self.session != nil, self.entitlementLeaseUntil > 0,
                       ProcessInfo.processInfo.systemUptime + 65 >= self.entitlementLeaseUntil {
                        await self.refreshCloudAccount()
                    }
                    self.activeProfile = self.recordIndex.currentProfile()
                    await self.refreshSelectedSummary()
                }
            }
        }
        if serverURL.isEmpty, let officialCloudURL {
            try? await api.configure(officialCloudURL.absoluteString)
            serverURL = officialCloudURL.absoluteString
        }
        session = await api.currentSession()
        // 登录凭据不可读不等于用户切换了身份，继续使用已选中的本地记录。
        // 同步仍要求有效会话；主动退出、切换服务器或账号时再切换数据空间。
        await reload()
        watch.activate()
        // 云端超时不能挡住离线首屏，先呈现本机记录再核实在线能力。
        if isCloudMode || session != nil { await refreshCloudAccount() }
        if healthEnabled { health.installObservers() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor in
                    guard let self, self.session != nil else { return }
                    try? await self.processPendingDeletion()
                    if self.syncEnabled { await self.sync() }
                    await self.resumePendingRecognition()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "bingjian.network"))
        networkMonitor = monitor
        deletionPending = KeychainStore.read("pending_delete:" + namespace) != nil
        try? await processPendingDeletion()
        try? await synchronizeAIConfiguration()
        if syncEnabled, session != nil { await sync() }
        BackgroundCoordinator.schedule()
    }

    func enteredForeground() {
        Task { await refreshCloudAccount() }
        activeProfile = recordIndex.currentProfile()
        Task { await refreshSelectedSummary() }
        if healthEnabled { scheduleHealthRefresh() }
        if syncEnabled, session != nil { Task { await sync() } }
    }

    func requireStore() throws -> LocalDatabase {
        guard let store else { throw APIError(code: "LOCAL_DATABASE", message: "本地数据库尚不可用") }
        return store
    }

    func reload() async {
        let token = UUID()
        let context = localDataContext
        reloadToken = token
        do {
            let store = try requireStore()
            let rows = try await store.allRecords()
            let prepared = await Task.detached(priority: .userInitiated) { RecordIndex(records: rows) }.value
            guard reloadToken == token else { return }
            records = rows
            recordIndex = prepared
            activeProfile = prepared.currentProfile()
            if profileSetupNamespace != namespace {
                profileSetupNamespace = namespace
                let today = TimeFormat.day(timezone: activeProfile.timezone, startMinutes: activeProfile.dayStartMinutes)
                profileSetupCompleted = UserDefaults.standard.bool(forKey: "body_setup_completed:" + namespace)
                    || OnboardingInput.isComplete(profile: activeProfile, weight: EnergyCalculator.weight(prepared.forSummary(day: today), day: today))
            }
            hasLoadedRecords = true
            // 只迁移一次旧版档案单位；后续同步、换账号都不覆盖本机选择。
            if UserDefaults.standard.string(forKey: Self.weightUnitPreferenceKey) == nil, !prepared.profiles.isEmpty {
                setWeightUnit(WeightUnit(rawValue: activeProfile.weightUnit) ?? .kg)
            }
            dataRevision += 1
            let count = try await store.pendingCount()
            guard reloadToken == token, context == localDataContext else { return }
            pendingCount = count
            // 冲突列表由状态页按游标读取，不在全局刷新中加载全部冲突。
            await refreshSelectedSummary()
            publishWatchContext()
        } catch { if context == localDataContext { errorMessage = error.localizedDescription } }
    }

    func selectToday() {
        followingToday = true
        Task { await refreshSelectedSummary() }
    }

    private func refreshSelectedSummary() async {
        let token = UUID()
        summaryToken = token
        let index = recordIndex
        let target = day
        summaryRefreshing = true
        let result = await Task.detached(priority: .userInitiated) {
            EnergyCalculator.summary(records: index.forSummary(day: target), day: target)
        }.value
        guard summaryToken == token else { return }
        selectedSummary = result
        summaryRefreshing = false
    }

    // MARK: - 页面操作入口与本地记录写入

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                await reload()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveRecord(_ record: AppRecord, expectedPayload: JSONObject? = nil) async throws {
        let context = localDataContext
        let store = try requireStore()
        let sourceDevice = deviceId
        let statusRecord = record.kind == "meal" ? records.first {
            $0.kind == "daily_status" && $0.businessDate == record.businessDate && $0.deletedAt == nil
        } : nil
        try await store.save(record, deviceId: sourceDevice, expectedPayload: expectedPayload)
        try checkLocalContext(context)
        if let existing = statusRecord, var status = existing.decode(DailyStatus.self), status.intakeComplete {
            status.intakeComplete = false
            status.confirmedAt = nil
            var value = existing
            value.payload = try Codec.object(status)
            try await store.save(value, deviceId: sourceDevice)
            try checkLocalContext(context)
        }
        await reload()
        try checkLocalContext(context)
        scheduleSync()
    }

    func deleteRecord(_ record: AppRecord) async throws {
        var value = record
        if record.kind == "weight", var weight = record.decode(WeightEntry.self), weight.source == "healthkit" {
            weight.hidden = true
            value.payload = try Codec.object(weight)
        } else { value.deletedAt = TimeFormat.iso() }
        try await saveRecord(value)
    }

    func saveProfile(_ value: BodyProfile) async throws {
        let pendingProfile = pendingProfileRecord
        let clockChanged = value.timezone != profile.timezone || value.dayStartMinutes != profile.dayStartMinutes
        if clockChanged && challenges.contains(where: { ["scheduled", "active", "paused", "settling"].contains($0.text("status")) }) {
            throw APIError(code: "CHALLENGE_CLOCK_LOCKED", message: "当前挑战结束后可修改统计时区和日界线")
        }
        let mealsChanged = Set(value.routineMeals) != Set(profile.routineMeals)
        var immediate = value
        immediate.effectiveAt = TimeFormat.iso()
        if mealsChanged { immediate.routineMeals = profile.routineMeals }
        let currentDay = TimeFormat.day(timezone: value.timezone, startMinutes: value.dayStartMinutes)
        try await saveRecord(AppRecord(kind: "profile", day: currentDay, value: immediate))
        if mealsChanged || pendingProfile != nil, let window = TimeFormat.window(currentDay, timezone: value.timezone, startMinutes: value.dayStartMinutes) {
            var scheduled = value
            scheduled.effectiveAt = TimeFormat.iso(window.end)
            let nextDay = TimeFormat.day(window.end, timezone: value.timezone, startMinutes: value.dayStartMinutes)
            try await saveRecord(AppRecord(kind: "profile", day: nextDay, value: scheduled,
                                           id: pendingProfile?.id ?? UUID().uuidString.lowercased()))
            notice = "档案已保存，常规餐次将在下一个统计日生效"
        }
    }

    func saveGoal(_ value: GoalEntry) async throws {
        try await saveRecord(AppRecord(kind: "goal", day: TimeFormat.day(), value: value))
    }

    func saveWeight(_ value: WeightEntry, existing: AppRecord? = nil) async throws {
        var record = try existing ?? AppRecord(kind: "weight",
            day: TimeFormat.day(TimeFormat.parse(value.measuredAt) ?? Date(), timezone: profile.timezone, startMinutes: profile.dayStartMinutes), value: value)
        record.payload = try Codec.object(value)
        if value.source != "healthkit", let date = TimeFormat.parse(value.measuredAt) {
            record.businessDate = TimeFormat.day(date, timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
        }
        try await saveRecord(record)
    }

    func recordWeight(_ amount: Double, unit: WeightUnit, measuredAt: Date, note: String,
                      representative: Bool, existing: AppRecord? = nil) async throws {
        let kilograms = unit.kilograms(from: amount)
        guard kilograms.isFinite, kilograms > 0, kilograms <= 600 else {
            throw APIError(code: "INVALID_WEIGHT", message: "请核对体重和单位")
        }
        var value = existing?.decode(WeightEntry.self) ?? WeightEntry(weightKg: kilograms)
        if value.source == "healthkit" { value.correctedWeightKg = kilograms }
        else { value.weightKg = kilograms; value.measuredAt = TimeFormat.iso(measuredAt) }
        value.note = note
        value.representative = representative
        try await saveWeight(value, existing: existing)
        setWeightUnit(unit)
    }

    func markComplete(_ complete: Bool) async throws {
        let store = try requireStore()
        let computed = summary
        let drafts = meals.contains { $0.decode(MealEntry.self)?.status == "draft" }
        if complete && (!computed.missingMeals.isEmpty || computed.missingNutrients.contains("热量") || drafts) {
            throw APIError(code: "MEALS_INCOMPLETE", message: "请先处理常规餐次、待确认食物和缺失热量。未进食可明确标记")
        }
        let historicalProfile = EnergyCalculator.latestProfile(recordIndex.forSummary(day: day), day: day)
        let status = DailyStatus(timezone: historicalProfile.timezone, routineMeals: historicalProfile.routineMeals,
                                 intakeComplete: complete, checkedIn: complete, confirmedAt: complete ? TimeFormat.iso() : nil)
        let existing = records.first { $0.kind == "daily_status" && $0.businessDate == day && $0.deletedAt == nil }
        let record = try AppRecord(kind: "daily_status", day: day, value: status, id: existing?.id ?? UUID().uuidString.lowercased())
        try await store.save(record, deviceId: deviceId)
        await reload()
        scheduleSync()
    }

    func skipMeal(_ type: String) async throws {
        let meal = MealEntry(eatenAt: TimeFormat.iso(entryDate), timezone: profile.timezone, mealType: type, status: "skipped")
        try await saveRecord(AppRecord(kind: "meal", day: day, value: meal))
    }

    func copyMeal(_ record: AppRecord) async throws {
        guard var value = record.decode(MealEntry.self) else { return }
        value.eatenAt = TimeFormat.iso(entryDate)
        value.aiTaskId = nil
        value.aiResult = nil
        value.photoIds = []
        value.items = value.items.map { item in
            var copy = item
            copy.id = UUID().uuidString.lowercased()
            copy.evidencePhotoIds = []
            return copy
        }
        try await saveRecord(AppRecord(kind: "meal", day: day, value: value))
    }

    func favorite(_ food: FoodItem) async throws {
        try await saveRecord(AppRecord(kind: "favorite", day: day, value: FavoriteFood(name: food.name, food: food)))
    }

    func saveFoodPreference(_ preference: FoodPreference) async throws {
        let old = records.first { $0.kind == "food_preference" && $0.payload.text("food_name") == preference.foodName && $0.deletedAt == nil }
        try await saveRecord(AppRecord(kind: "food_preference", day: day, value: preference, id: old?.id ?? UUID().uuidString.lowercased()))
    }

    // MARK: - 餐食照片与三种识别路径

    func savePhoto(_ data: Data, mealId: String) async throws -> String {
        let context = localDataContext
        let store = try requireStore()
        let encoded = try await ImageProcessor.jpeg(data)
        try checkLocalContext(context)
        let id = UUID().uuidString.lowercased()
        try await store.savePhoto(encoded, id: id, mealId: mealId)
        try checkLocalContext(context)
        return id
    }

    func thumbnailData(_ id: String) async -> Data? {
        let context = localDataContext
        if let cached = thumbnailCache.object(forKey: id as NSString) { return cached as Data }
        guard let url = await photoURL(id), let data = try? await ImageProcessor.thumbnail(url) else { return nil }
        guard context == localDataContext, !Task.isCancelled else { return nil }
        thumbnailCache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return data
    }

    func photoURL(_ id: String) async -> URL? {
        let context = localDataContext
        guard let store else { return nil }
        let local = await store.photoURL(id)
        guard context == localDataContext, !Task.isCancelled else { return nil }
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard session != nil else { return nil }
        do {
            let apiContext = await api.requestContext()
            try checkLocalContext(context)
            let data = try await api.request("media/\(id)", expectedContext: apiContext)
            try checkLocalContext(context)
            try data.write(to: local, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return local
        } catch { return nil }
    }

    func recognize(record: AppRecord) async throws -> JSONObject {
        let context = localDataContext
        if !deploymentChecked, !serverURL.isEmpty { await refreshCloudAccount() }
        try checkLocalContext(context)
        try await requireCloudAI()
        try checkLocalContext(context)
        guard canUseAI else { throw APIError(code: "SVIP_REQUIRED", message: aiAccessMessage) }
        guard let meal = record.decode(MealEntry.self), !meal.photoIds.isEmpty else {
            throw APIError(code: "PHOTO_REQUIRED", message: "请先添加餐食照片")
        }
        let store = try requireStore()
        if !isCloudMode && aiMode == "device" {
            var urls: [URL] = []
            for id in meal.photoIds { urls.append(await store.photoURL(id)) }
            try checkLocalContext(context)
            let preferences = records.filter { $0.kind == "food_preference" && $0.deletedAt == nil }.compactMap { $0.decode(FoodPreference.self) }
            let result = try await OnDeviceRecognizer.recognize(urls: urls, photoIds: meal.photoIds, preferences: preferences)
            try checkLocalContext(context)
            return ["items": .array(try result.items.map { .object(try Codec.object($0)) }),
                    "uncertainty_note": .string(result.note), "model_name": .string("Apple Vision"),
                    "model_version": .string(String(VNRevision.current)), "needs_user_confirmation": .bool(true),
                    "meal_version": .number(Double(record.version))]
        }
        if !isCloudMode && aiConfiguration.execution == "direct" {
            return try await recognizeDirect(record: record, meal: meal)
        }
        guard session != nil else { throw APIError(code: "AUTH_REQUIRED", message: "连接并登录服务器后可调用远程识别") }
        var request: JSONObject = [
            "request_key": .string(UUID().uuidString.lowercased()), "meal_id": .string(record.id),
            "meal_version": .number(Double(record.version)), "photo_ids": .array(meal.photoIds.map(JSONValue.string)),
            "note": .string(meal.note), "allow_external": .bool(externalAIConsent)
        ]
        if isCloudMode {
            request["consent_revision"] = cloudConsent["revision"] ?? .number(0)
            request["provider_revision"] = cloudConsent["provider_revision"] ?? .number(0)
            request["allow_external"] = .bool(cloudConsent.flag("allowed"))
        }
        try await store.setMetadata("ai_waiting:" + record.id, value: Codec.json(request))
        try checkLocalContext(context)
        do {
            try await synchronizeAIConfiguration()
            try checkLocalContext(context)
            return try await submitRecognition(request)
        }
        catch let error as URLError {
            try checkLocalContext(context)
            let disconnected = [URLError.cannotFindHost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code)
            if !isCloudMode && disconnected && aiConfiguration.allowOutsideLan && !aiConfiguration.useServerDefaults {
                let result = try await recognizeDirect(record: record, meal: meal)
                try checkLocalContext(context)
                try await store.setMetadata("ai_waiting:" + record.id, value: nil)
                try checkLocalContext(context)
                return result
            }
            try await store.log("识别等待连接。\(error.localizedDescription)")
            try checkLocalContext(context)
            return ["status": .string("waiting")]
        }
    }

    private func recognizeDirect(record: AppRecord, meal: MealEntry) async throws -> JSONObject {
        guard !isCloudMode else { throw cloudConfigurationError() }
        let context = localDataContext
        guard aiConfiguration.configured, !aiConfiguration.useServerDefaults else {
            throw APIError(code: "AI_CONFIGURATION", message: "请在 AI 设置中填写接口地址、模型和自己的密钥")
        }
        guard !aiConfiguration.external || externalAIConsent else {
            throw APIError(code: "AI_CONSENT", message: "请先同意将本餐照片发送到配置的外部 AI 服务")
        }
        let store = try requireStore()
        var photos: [(String, URL)] = []
        for id in meal.photoIds { photos.append((id, await store.photoURL(id))) }
        try checkLocalContext(context)
        let preferences = records.filter { $0.kind == "food_preference" && $0.deletedAt == nil }.compactMap { $0.decode(FoodPreference.self) }
        let result = try await responses.recognize(configuration: aiConfiguration, apiKey: aiAPIKey(),
            photos: photos, note: meal.note, mealVersion: record.version, preferences: preferences)
        try checkLocalContext(context)
        return result
    }

    private func submitRecognition(_ request: JSONObject) async throws -> JSONObject {
        let context = localDataContext
        try await requireCloudAI()
        try checkLocalContext(context)
        guard let syncEngine else { throw APIError(code: "NO_SERVER", message: "请先连接服务器") }
        let mealId = request.text("meal_id")
        let store = try requireStore()
        let sourceDevice = deviceId
        let apiContext = await api.requestContext()
        try checkLocalContext(context)
        guard var current = try await store.record(mealId), current.deletedAt == nil,
              var savedMeal = current.decode(MealEntry.self) else {
            try await store.setMetadata("ai_waiting:" + mealId, value: nil)
            throw APIError(code: "ENTITY_DELETED", message: "餐次已经删除")
        }
        try checkLocalContext(context)
        if isCloudMode {
            guard request.number("consent_revision") == cloudConsent.number("revision"),
                  request.number("provider_revision") == cloudConsent.number("provider_revision"),
                  cloudConsent.flag("allowed"), request.flag("allow_external") else {
                try await store.setMetadata("ai_waiting:" + mealId, value: nil)
                throw APIError(code: "AI_CONSENT_CHANGED", message: "外部处理授权或提供方已变化，请确认后重新识别")
            }
        }
        let requestedPhotos = request.strings("photo_ids")
        guard Set(requestedPhotos) == Set(savedMeal.photoIds), request.text("note") == savedMeal.note else {
            try await store.setMetadata("ai_waiting:" + mealId, value: nil)
            throw APIError(code: "PHOTO_CHANGED", message: "照片已改变，请重新提交识别")
        }
        let expectedPayload = current.payload
        try await syncEngine.uploadRecognitionPhotos(mealId: mealId, photoIds: requestedPhotos,
                                                    authorization: request, expectedContext: apiContext)
        try checkLocalContext(context)
        guard let beforeSubmission = try await store.record(mealId), beforeSubmission.deletedAt == nil,
              recognitionPayload(beforeSubmission.payload) == recognitionPayload(expectedPayload) else {
            try await store.setMetadata("ai_waiting:" + mealId, value: nil)
            throw APIError(code: "MEAL_VERSION_CHANGED", message: "餐次内容已修改，请重新确认后识别")
        }
        try checkLocalContext(context)
        let response = try await api.send("ai/food-recognition", method: "POST", body: request, expectedContext: apiContext)
        try checkLocalContext(context)
        guard let task = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "识别任务创建失败") }
        guard let latest = try await store.record(mealId), latest.deletedAt == nil,
              recognitionPayload(latest.payload) == recognitionPayload(expectedPayload) else {
            throw APIError(code: "MEAL_VERSION_CHANGED", message: "餐次已修改，识别任务不会覆盖当前记录")
        }
        try checkLocalContext(context)
        current = latest
        savedMeal = latest.decode(MealEntry.self) ?? savedMeal
        savedMeal.aiTaskId = task.text("id")
        current.payload = try Codec.object(savedMeal)
        try await store.save(current, deviceId: sourceDevice, expectedPayload: expectedPayload)
        try checkLocalContext(context)
        try await store.setMetadata("ai_waiting:" + mealId, value: nil)
        try checkLocalContext(context)
        await reload()
        try checkLocalContext(context)
        return task
    }

    private func recognitionPayload(_ payload: JSONObject) -> JSONObject {
        var value = payload
        for key in ["ai_task_id", "ai_result"] { value.removeValue(forKey: key) }
        return value
    }

    func resumePendingRecognition() async {
        guard session != nil, !deletionPending, !changingAccount, let store else { return }
        let context = localDataContext
        if isCloudMode {
            await refreshCloudAccount()
            guard context == localDataContext, canUseAI else { return }
        }
        let waiting = (try? await store.metadataPrefix("ai_waiting:")) ?? [:]
        for (_, value) in waiting {
            guard context == localDataContext, !changingAccount else { return }
            guard let request = try? JSONDecoder().decode(JSONObject.self, from: Data(value.utf8)) else { continue }
            do { _ = try await submitRecognition(request) }
            catch { try? await store.log("待识别照片尚未提交。\(error.localizedDescription)") }
        }
    }

    func pollRecognition(_ taskId: String) async throws -> JSONObject {
        let context = localDataContext
        if isCloudMode, ProcessInfo.processInfo.systemUptime + 30 >= entitlementLeaseUntil {
            try await requireCloudAI()
            try checkLocalContext(context)
        }
        guard !isCloudMode || canUseAI else { throw APIError(code: "SVIP_REQUIRED", message: aiAccessMessage) }
        guard let task = try await api.send("ai/tasks/\(taskId)").object else {
            throw APIError(code: "INVALID_RESPONSE", message: "识别任务响应无效")
        }
        try checkLocalContext(context)
        if task.flag("result_withheld") {
            entitlementLeaseUntil = 0
            throw APIError(code: "SVIP_REQUIRED", message: "AI 权益或授权已变化，基础记录仍可使用")
        }
        return task
    }

    // MARK: - 后台连接、登录与本地身份切换

    func checkConnection() async throws {
        try await saveServerAddress(serverURL)
        let response = try await api.send("health", authenticated: false)
        guard response.object?.text("status") == "ok" else { throw APIError(code: "CONNECTION_FAILED", message: "服务器尚未准备好") }
        notice = (URL(string: serverURL)?.scheme?.uppercased() ?? "后台") + " 连接成功"
    }

    func authenticate(username: String, password: String, displayName: String, register: Bool, mergeLocal: Bool) async throws {
        let input = try AccountInput(username: username, password: password, displayName: displayName).validated(registration: register)
        await stopBackgroundWork()
        defer { changingAccount = false }
        session = nil
        let context = localDataContext
        try await api.configure(serverURL)
        let deviceKey = "device:" + serverURL + ":" + input.username
        let accountDeviceId = UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString.lowercased()
        do {
            let credentials: SessionCredentials
            if register {
                credentials = try await api.register(username: input.username, password: input.password, name: input.displayName, deviceId: accountDeviceId)
            } else {
                credentials = try await api.login(username: input.username, password: input.password, deviceId: accountDeviceId, name: UIDevice.current.name)
            }
            try checkLocalContext(context)
            try await finishAuthentication(credentials, loginName: input.username, mergeLocal: mergeLocal)
        } catch {
            if context == localDataContext, session == nil { await api.clearSession() }
            throw error
        }
    }

    private func finishAuthentication(_ credentials: SessionCredentials, loginName: String, mergeLocal: Bool) async throws {
        let context = localDataContext
        let current = try requireStore()
        let bound = try await current.metadata("bound_user")
        try checkLocalContext(context)
        let bindingKey = credentials.instanceId + ":" + credentials.userId
        var targetNamespace = namespace
        var targetStore = current
        if bound != bindingKey && !(bound == nil && mergeLocal) {
            let key = "namespace:" + bindingKey
            targetNamespace = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.lowercased()
            targetStore = try LocalDatabase(namespace: targetNamespace)
        }
        // 服务器绑定失败时保留当前本地空间，不让旧记录出现在新账号的页面中。
        _ = try await api.send("identity/bind", method: "POST", body: ["local_user_id": .string(targetNamespace)])
        try checkLocalContext(context)
        try await targetStore.setMetadata("bound_user", value: bindingKey)
        try checkLocalContext(context)
        namespace = targetNamespace
        store = targetStore
        localDataContext = UUID()
        let accountContext = localDataContext
        syncEngine = SyncEngine(api: api, store: targetStore)
        deviceId = credentials.deviceId
        UserDefaults.standard.set(deviceId, forKey: "device:" + serverURL + ":" + loginName)
        UserDefaults.standard.set(deviceId, forKey: "device_id")
        UserDefaults.standard.set(namespace, forKey: "local_namespace")
        UserDefaults.standard.set(namespace, forKey: "namespace:" + bindingKey)
        session = credentials
        records = []
        recordIndex = RecordIndex(records: [])
        activeProfile = BodyProfile()
        selectedSummary = DailySummary(day: TimeFormat.day())
        thumbnailCache.removeAllObjects()
        challenges = []
        capabilities = [:]
        UserDefaults.standard.set(loginName, forKey: "last_username")
        await reload()
        try checkLocalContext(accountContext)
        await refreshCloudAccount()
        try checkLocalContext(accountContext)
        loadAIConfiguration()
        try? await synchronizeAIConfiguration()
        try checkLocalContext(accountContext)
        // 已完成身份绑定；能力列表临时离线不应把成功登录当成失败。
        if let value = try? await api.send("capabilities").object {
            try checkLocalContext(accountContext)
            try await updateCapabilities(value)
        }
        try checkLocalContext(accountContext)
        try? await processPendingDeletion()
        try checkLocalContext(accountContext)
        changingAccount = false
        if syncEnabled { await sync() }
    }

    func logout() async {
        await stopBackgroundWork()
        defer { changingAccount = false }
        try? await api.send("auth/logout", method: "POST", body: [:])
        await api.clearSession()
        session = nil
        syncEnabled = false
        healthEnabled = false
        try? await activateUnboundStorage()
        await reload()
        syncStatus = "已退出登录，原账号记录已锁定保留"
    }

    private func activateUnboundStorage() async throws {
        var candidate = UserDefaults.standard.string(forKey: "anonymous_namespace") ?? UUID().uuidString.lowercased()
        var database = try LocalDatabase(namespace: candidate)
        if try await database.metadata("bound_user") != nil {
            candidate = UUID().uuidString.lowercased()
            database = try LocalDatabase(namespace: candidate)
        }
        namespace = candidate
        store = database
        localDataContext = UUID()
        syncEngine = SyncEngine(api: api, store: database)
        UserDefaults.standard.set(candidate, forKey: "anonymous_namespace")
        UserDefaults.standard.set(candidate, forKey: "local_namespace")
        records = []
        recordIndex = RecordIndex(records: [])
        activeProfile = BodyProfile()
        selectedSummary = DailySummary(day: TimeFormat.day())
        thumbnailCache.removeAllObjects()
        challenges = []
        capabilities = [:]
        loadAIConfiguration()
    }

    // MARK: - 同步调度与后台任务取消

    func sync() async {
        guard syncEnabled, session != nil, !changingAccount, !deletionPending, let syncEngine else { return }
        if syncing { syncRequested = true; return }
        syncing = true
        let context = syncContext
        syncStatus = "正在同步"
        defer {
            syncing = false
            if syncRequested {
                syncRequested = false
                scheduleSync()
            }
        }
        do {
            try? await synchronizeAIConfiguration()
            guard context == syncContext, !changingAccount else { return }
            let apiContext = await api.requestContext()
            guard context == syncContext, !changingAccount else { return }
            let operation = Task { try await syncEngine.synchronize() }
            syncOperation = operation
            let result = try await operation.value
            guard context == syncContext else { return }
            syncOperation = nil
            if result.failed > 0 { syncStatus = "\(result.failed) 条记录同步失败，可在同步状态中查看并重试" }
            else if result.conflicts > 0 { syncStatus = "有 \(result.conflicts) 条记录需要合并" }
            else { syncStatus = "已同步 · \(Date().formatted(date: .omitted, time: .shortened))" }
            let value = try await api.send("capabilities", expectedContext: apiContext).object ?? [:]
            guard context == syncContext else { return }
            try await updateCapabilities(value)
            guard context == syncContext else { return }
            let challengeList = try await api.send("challenges", expectedContext: apiContext).array?.compactMap(\.object) ?? []
            guard context == syncContext else { return }
            challenges = challengeList
            await reload()
        } catch {
            if context == syncContext { syncStatus = error.localizedDescription }
        }
    }

    private func stopBackgroundWork() async {
        changingAccount = true
        localDataContext = UUID()
        reloadToken = UUID()
        summaryToken = UUID()
        clearCloudAccess()
        syncContext = UUID()
        syncRequested = false
        refreshTask?.cancel()
        syncOperation?.cancel()
        _ = try? await syncOperation?.value
        await refreshTask?.value
        syncOperation = nil
        refreshTask = nil
    }

    private func scheduleSync() {
        guard syncEnabled, session != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await sync()
        }
    }

    private func updateCapabilities(_ value: JSONObject) async throws {
        let context = localDataContext
        if value.text("deployment_mode") == "cloud" {
            serverDeploymentMode = "cloud"
            UserDefaults.standard.set("cloud", forKey: "server_deployment:" + serverURL)
        }
        if isCloudMode { capabilities = value; return }
        let ai = value["ai"]?.object ?? [:]
        let signature = ai.text("host") + "|" + ai.text("model") + "|" + String(ai.flag("external"))
        let store = try requireStore()
        if aiConfiguration.execution == "gateway",
           let previous = try await store.metadata("ai_provider_signature"), previous != signature {
            try checkLocalContext(context)
            externalAIConsent = false
            notice = "AI 提供方配置已变化，请重新核对外部处理授权"
        }
        try checkLocalContext(context)
        try await store.setMetadata("ai_provider_signature", value: signature)
        try checkLocalContext(context)
        aiHasServerKey = ai.flag("has_api_key")
        capabilities = value
    }

    // MARK: - 地址持久化与首次引导

    func saveServerAddress(_ value: String) async throws {
        if let officialCloudURL, try ServerAddress.normalize(value) != officialCloudURL {
            throw APIError(code: "CLOUD_SERVER_LOCKED", message: "云端版本只能连接已配置的官方服务")
        }
        let changed = try ServerAddress.normalize(value).absoluteString != UserDefaults.standard.string(forKey: "server_url")
        if changed { await stopBackgroundWork() }
        defer { if changed { changingAccount = false } }
        try await api.configure(value)
        deploymentChecked = false
        cloudReady = false
        serverURL = UserDefaults.standard.string(forKey: "server_url") ?? value
        serverDeploymentMode = UserDefaults.standard.string(forKey: "server_deployment:" + serverURL) ?? ""
        session = await api.currentSession()
        if changed && session == nil, (try? await store?.metadata("bound_user")) != nil {
            try await activateUnboundStorage()
            syncEnabled = false
            healthEnabled = false
            await reload()
        }
        await refreshCloudAccount()
    }

    func completeSetup(offline: Bool = false) async throws {
        if !offline && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await saveServerAddress(serverURL)
        }
        setupCompleted = true
        UserDefaults.standard.set(true, forKey: "setup_completed")
    }

    func finishOnboarding(_ input: OnboardingInput, profileId: String, weightId: String, offline: Bool) async throws {
        let value = try input.profile(basedOn: profile)
        if !offline && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await saveServerAddress(serverURL)
        }
        let now = Date()
        let day = TimeFormat.day(now, timezone: value.timezone, startMinutes: value.dayStartMinutes)
        let body = try AppRecord(kind: "profile", day: day, value: value, id: profileId)
        let weight = WeightEntry(measuredAt: TimeFormat.iso(now), weightKg: input.unit.kilograms(from: input.weight!))
        let measurement = try AppRecord(kind: "weight", day: day, value: weight, id: weightId)
        try await requireStore().save([body, measurement], deviceId: deviceId)
        setWeightUnit(input.unit)
        UserDefaults.standard.set(true, forKey: "body_setup_completed:" + namespace)
        profileSetupCompleted = true
        try await completeSetup(offline: true)
        await reload()
        scheduleSync()
    }

    // MARK: - AI 配置、密钥复用与模型列表

    func aiAPIKey() -> String {
        guard let data = KeychainStore.read("ai_key:" + namespace) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func hasSavedAIKey(for configuration: AIConfiguration) -> Bool {
        guard let address = try? AIAddress.normalize(configuration.baseUrl),
              let savedAddress = try? AIAddress.normalize(aiConfiguration.baseUrl), address == savedAddress else { return false }
        return !aiAPIKey().isEmpty || (configuration.execution == "gateway" && aiHasServerKey)
    }

    func aiRequestKey(configuration: AIConfiguration, enteredKey: String) throws -> String {
        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        // 仅向原接口复用密钥，修改模型、输出设置不会使已保存凭据失效。
        guard try AIAddress.normalize(configuration.baseUrl) == AIAddress.normalize(aiConfiguration.baseUrl) else {
            if !aiAPIKey().isEmpty || aiHasServerKey {
                throw APIError(code: "AI_KEY_REQUIRED", message: "接口地址已更换，请填写新接口对应的密钥")
            }
            return ""
        }
        let saved = aiAPIKey()
        if saved.isEmpty && aiHasServerKey {
            throw APIError(code: "AI_LOCAL_KEY_REQUIRED", message: "密钥仅保存在后台，请使用后台调用；手机直连需先在本机保存密钥")
        }
        return saved
    }

    private func loadAIConfiguration() {
        if isCloudMode {
            aiConfiguration = AIConfiguration()
            aiConfiguration.execution = "gateway"
            aiConfiguration.useServerDefaults = true
            aiConfigurationPending = false
            aiHasServerKey = false
            availableAIModels = []
            return
        }
        externalAIConsent = UserDefaults.standard.bool(forKey: "external_ai_consent:" + namespace)
        if let data = UserDefaults.standard.data(forKey: "ai_configuration:" + namespace),
           let value = try? Codec.decoder().decode(AIConfiguration.self, from: data) {
            aiConfiguration = value
        } else { aiConfiguration = AIConfiguration() }
        aiConfigurationPending = UserDefaults.standard.bool(forKey: "ai_configuration_pending:" + namespace)
        aiHasServerKey = UserDefaults.standard.bool(forKey: "ai_server_key:" + namespace)
        if let data = UserDefaults.standard.data(forKey: "ai_models:" + namespace) {
            availableAIModels = (try? Codec.decoder().decode([AIModelOption].self, from: data)) ?? []
        } else { availableAIModels = [] }
    }

    func saveAIConfiguration(_ value: AIConfiguration, apiKey: String, requireModel: Bool = true, clearKey: Bool = false) async throws {
        guard !isCloudMode else { throw cloudConfigurationError() }
        var configuration = value
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuration.useServerDefaults {
            configuration.baseUrl = try AIAddress.normalize(value.baseUrl).absoluteString
            if requireModel && configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw APIError(code: "AI_MODEL_REQUIRED", message: "请选择或手动填写模型标识")
            }
        }
        let addressChanged = (try? AIAddress.normalize(configuration.baseUrl)) != (try? AIAddress.normalize(aiConfiguration.baseUrl))
        if configuration.execution == "direct" && !clearKey {
            _ = try aiRequestKey(configuration: configuration, enteredKey: apiKey)
        }
        if addressChanged || configuration.model != aiConfiguration.model {
            externalAIConsent = false
        }
        if clearKey || (addressChanged && apiKey.isEmpty) {
            KeychainStore.delete("ai_key:" + namespace)
            UserDefaults.standard.set(true, forKey: "ai_clear_key:" + namespace)
        } else if !apiKey.isEmpty {
            try KeychainStore.save(Data(apiKey.utf8), key: "ai_key:" + namespace)
            UserDefaults.standard.set(false, forKey: "ai_clear_key:" + namespace)
        }
        UserDefaults.standard.set(try Codec.encoder().encode(configuration), forKey: "ai_configuration:" + namespace)
        aiConfiguration = configuration
        aiConfigurationPending = configuration.execution == "gateway" && !configuration.useServerDefaults
        UserDefaults.standard.set(aiConfigurationPending, forKey: "ai_configuration_pending:" + namespace)
        if session != nil && aiConfigurationPending {
            do { try await synchronizeAIConfiguration() }
            catch is URLError { notice = "AI 设置已保存到本机，后台连接恢复后自动同步" }
        }
    }

    func synchronizeAIConfiguration() async throws {
        guard session != nil else { return }
        if !deploymentChecked, !serverURL.isEmpty { await refreshCloudAccount() }
        guard !isCloudMode else { return }
        guard session != nil, aiConfigurationPending, !aiConfiguration.useServerDefaults else { return }
        let context = localDataContext
        let key = aiAPIKey()
        let shouldClear = UserDefaults.standard.bool(forKey: "ai_clear_key:" + namespace)
        let suppliedKey: JSONValue = !key.isEmpty ? .string(key) : shouldClear ? .string("") : .null
        let response = try await api.send("ai/settings", method: "PUT", body: [
            "base_url": .string(aiConfiguration.baseUrl), "model": .string(aiConfiguration.model),
            "api_key": suppliedKey, "external": .bool(aiConfiguration.external),
            "structured_output": .bool(aiConfiguration.structuredOutput),
            "max_output_tokens": .number(Double(aiConfiguration.maxOutputTokens))
        ]).object ?? [:]
        try checkLocalContext(context)
        aiHasServerKey = response.flag("has_api_key")
        UserDefaults.standard.set(aiHasServerKey, forKey: "ai_server_key:" + namespace)
        UserDefaults.standard.set(false, forKey: "ai_clear_key:" + namespace)
        let signature = response.text("host") + "|" + response.text("model") + "|" + String(response.flag("external"))
        try await requireStore().setMetadata("ai_provider_signature", value: signature)
        aiConfigurationPending = false
        UserDefaults.standard.set(false, forKey: "ai_configuration_pending:" + namespace)
    }

    func loadAIModels(configuration: AIConfiguration, apiKey: String) async throws -> [AIModelOption] {
        guard !isCloudMode else { throw cloudConfigurationError() }
        let context = localDataContext
        let result: [AIModelOption]
        if configuration.execution == "gateway", session != nil {
            try await saveAIConfiguration(configuration, apiKey: apiKey, requireModel: false)
            let response = try await api.send("ai/models", query: ["refresh": "true"]).object ?? [:]
            result = response.objects("models").map { AIModelOption(id: $0.text("id"), name: $0.text("name", fallback: $0.text("id"))) }
        } else {
            let key = try aiRequestKey(configuration: configuration, enteredKey: apiKey)
            result = try await responses.models(configuration: configuration, apiKey: key, refresh: true)
        }
        try checkLocalContext(context)
        availableAIModels = result
        UserDefaults.standard.set(try Codec.encoder().encode(result), forKey: "ai_models:" + namespace)
        return result
    }

    func testAI(configuration: AIConfiguration, apiKey: String) async throws -> String {
        let values = try await loadAIModels(configuration: configuration, apiKey: apiKey)
        let listed = values.contains { $0.id == configuration.model }
        return listed ? "连接成功，所选模型在列表中。图像能力在实际识别时校验。" : "接口连接成功。列表中未显示当前模型，可核对标识或使用兼容接口允许的模型。"
    }

    func hydrateAIConfiguration() async {
        if isCloudMode { await refreshCloudAccount(); return }
        let context = localDataContext
        guard session != nil, aiConfiguration.model.isEmpty, !aiConfigurationPending else { return }
        do {
            let response = try await api.send("ai/settings").object ?? [:]
            guard context == localDataContext, !isCloudMode, response.flag("configured") else { return }
            var configuration = AIConfiguration()
            configuration.baseUrl = response.text("base_url")
            configuration.model = response.text("model")
            configuration.external = response.flag("external")
            configuration.structuredOutput = response.flag("structured_output")
            configuration.maxOutputTokens = Int(response.number("max_output_tokens") ?? 4096)
            aiConfiguration = configuration
            aiHasServerKey = response.flag("has_api_key")
            UserDefaults.standard.set(try Codec.encoder().encode(configuration), forKey: "ai_configuration:" + namespace)
            UserDefaults.standard.set(aiHasServerKey, forKey: "ai_server_key:" + namespace)
        } catch {}
    }

    // MARK: - 数据与账号删除流程

    func requestDeletion(account: Bool, password: String) async throws {
        guard let session else { throw APIError(code: "AUTH_REQUIRED", message: "请先登录需要删除数据的账号") }
        let requestId = UUID().uuidString.lowercased()
        let receipt = UUID().uuidString + UUID().uuidString
        let request: JSONObject = [
            "user_id": .string(session.userId), "instance_id": .string(session.instanceId),
            "server_url": .string(serverURL), "path": .string(account ? "account" : "account/data"),
            "body": .object(["password": .string(password), "request_key": .string(requestId), "receipt_secret": .string(receipt)])
        ]
        try KeychainStore.save(JSONEncoder().encode(request), key: "pending_delete:" + namespace)
        try KeychainStore.save(JSONEncoder().encode(["id": JSONValue.string(requestId), "receipt": .string(receipt),
                                                     "server_url": .string(serverURL)]), key: "deletion_receipt")
        deletionPending = true
        syncEnabled = false
        healthEnabled = false
        let store = try requireStore()
        try await store.setMetadata("health_disabled_after_delete", value: "true")
        for key in try await store.metadataPrefix("ai_waiting:").keys { try await store.setMetadata(key, value: nil) }
        do { try await processPendingDeletion() }
        catch is URLError { notice = "删除请求已安全保存，连接恢复后优先提交。服务器尚未确认删除。" }
    }

    func processPendingDeletion() async throws {
        guard let session, let saved = KeychainStore.read("pending_delete:" + namespace),
              let request = try? JSONDecoder().decode(JSONObject.self, from: saved) else { return }
        guard request.text("user_id") == session.userId, request.text("instance_id") == session.instanceId,
              request.text("server_url") == serverURL else { return }
        let body = request["body"]?.object ?? [:]
        let response: JSONObject
        do {
            response = try await api.send(request.text("path"), method: "DELETE", body: body).object ?? [:]
        } catch {
            let statusData = try? await api.request("data/deletions/\(body.text("request_key"))",
                authenticated: false, extraHeaders: ["X-Deletion-Receipt": body.text("receipt_secret")])
            guard let statusData, var recovered = try? JSONDecoder().decode(JSONObject.self, from: statusData) else { throw error }
            recovered["receipt"] = .string(body.text("receipt_secret"))
            response = recovered
        }
        guard !response.text("receipt").isEmpty else { throw APIError(code: "INVALID_RESPONSE", message: "服务器未返回删除回执") }
        var receipt = response
        receipt["server_url"] = .string(serverURL)
        try KeychainStore.save(JSONEncoder().encode(receipt), key: "deletion_receipt")
        KeychainStore.delete("pending_delete:" + namespace)
        deletionPending = false
        await api.clearSession()
        self.session = nil
        clearCloudAccess()
        localDataContext = UUID()
        syncEnabled = false
        healthEnabled = false
        syncStatus = "服务器已接受删除，可在数据管理中查询结果"
        notice = syncStatus
    }

    func cancelPendingDeletion() {
        KeychainStore.delete("pending_delete:" + namespace)
        deletionPending = false
        notice = "已取消尚未提交的删除请求，可自行重新开启同步"
    }

    // MARK: - 健康授权与增量刷新

    func authorizeHealth() async throws {
        try await health.authorize()
        healthEnabled = true
        try await requireStore().setMetadata("health_disabled_after_delete", value: nil)
        scheduleHealthRefresh()
    }

    func refreshHealth(from start: Date? = nil) async throws {
        let originalNamespace = namespace
        try await health.refresh(store: requireStore(), profile: profile, deviceId: deviceId, historyStart: start)
        guard originalNamespace == namespace, !changingAccount, !deletionPending else { return }
        await reload()
        scheduleSync()
    }

    private func scheduleHealthRefresh() {
        guard healthEnabled, !health.refreshing, !changingAccount, !deletionPending else { return }
        refreshTask = Task {
            do { try await refreshHealth() }
            catch { health.status = error.localizedDescription }
        }
    }

    // MARK: - 伙伴、待执行命令与冲突处理

    func refreshChallenges() async throws {
        challenges = try await api.send("challenges").array?.compactMap(\.object) ?? []
    }

    func queueCommand(path: String, method: String = "POST", body: JSONObject = [:], priority: Int = 0) async throws {
        try await requireStore().enqueueCommand(path: path, method: method, body: body, priority: priority)
        notice = priority > 0 ? "本机已停止共享，服务器确认前仍可能按旧授权提供数据" : "已加入待发送队列"
        if priority > 0 {
            let store = try requireStore()
            for key in try await store.metadataPrefix("shared_summary:").keys { try await store.setMetadata(key, value: nil) }
        }
        scheduleSync()
    }

    func resolveConflict(_ conflict: SyncConflict, keepLocal: Bool) async throws {
        try await requireStore().resolve(conflict, keepLocal: keepLocal, deviceId: deviceId)
        await reload()
        scheduleSync()
    }

    // MARK: - 手机与 Watch 的状态及记录交换

    private func publishWatchContext() {
        let today = TimeFormat.day(timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
        let summary = EnergyCalculator.summary(records: recordIndex.forSummary(day: today), day: today)
        var context: [String: Any] = ["owner_id": namespace, "day": summary.day, "status": summary.complete ? "已完成记录" : "继续记录"]
        context["weight_unit"] = weightUnit.rawValue
        if let weight = summary.weight { context["weight"] = weight }
        if let intake = summary.intake { context["intake"] = intake }
        if let steps = summary.steps { context["steps"] = steps }
        watch.update(context)
    }

    private func receiveWatchRecord(_ payload: [String: Any]) async throws {
        guard payload["owner_id"] as? String == namespace else {
            throw APIError(code: "WATCH_ACCOUNT", message: "手表记录属于另一个本机身份，请切回原账号")
        }
        guard let id = payload["id"] as? String, let kind = payload["kind"] as? String,
              let timestamp = payload["timestamp"] as? String else { return }
        let store = try requireStore()
        if try await store.record(id) != nil { return }
        let date = TimeFormat.parse(timestamp) ?? Date()
        let day = TimeFormat.day(date, timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
        if kind == "weight", let weight = payload["value"] as? Double, weight > 0 {
            try await saveRecord(AppRecord(kind: "weight", day: day, value: WeightEntry(measuredAt: timestamp, weightKg: weight, source: "manual", sourceName: "Apple Watch"), id: id))
        } else if kind == "meal", let kcal = payload["value"] as? Double, kcal >= 0 {
            let food = FoodItem(name: payload["name"] as? String ?? "手表快捷记录", amount: 1, unit: "serving",
                                basisAmount: 1, nutritionBasis: "total", basisKcal: kcal)
            let meal = MealEntry(eatenAt: timestamp, timezone: profile.timezone, mealType: "snack", status: "confirmed", items: [food])
            try await saveRecord(AppRecord(kind: "meal", day: day, value: meal, id: id))
        }
    }
}

enum VNRevision {
    static let current = Int(VNClassifyImageRequest.currentRevision)
}

// MARK: - 官方云账号、权益与外部照片处理授权

extension AppModel {
    var isCloudMode: Bool { officialCloudURL != nil || CloudDeployment.requested || serverDeploymentMode == "cloud" }
    var cloudServerSelected: Bool {
        if let officialCloudURL { return (try? ServerAddress.normalize(serverURL)) == officialCloudURL }
        return serverDeploymentMode == "cloud" && CloudDeployment.validatedURL(serverURL) != nil
    }
    var cloudServerConfigured: Bool {
        officialCloudURL != nil || (serverDeploymentMode == "cloud" && CloudDeployment.validatedURL(serverURL) != nil)
    }
    var canUseAI: Bool {
        guard !changingAccount, !deletionPending else { return false }
        if !isCloudMode { return serverURL.isEmpty || deploymentChecked || serverDeploymentMode == "private" }
        return cloudServerSelected && cloudReady && session != nil && entitlements.flag("ai_food_recognition")
            && ProcessInfo.processInfo.systemUptime < entitlementLeaseUntil
    }
    var aiAccessMessage: String {
        if !isCloudMode { return "按已保存的私有 AI 配置使用" }
        if session == nil { return "登录云账号后，有效 SVIP 可使用 AI 识图" }
        if let cloudAccessError { return cloudAccessError }
        if canUseAI { return "SVIP 已生效，识别仍需单独同意外部照片处理" }
        return "AI 识图仅向有效 SVIP 开放，基础记录与同步仍可使用"
    }

    private func clearCloudAccess() {
        cloudRefreshID = UUID()
        entitlementLeaseUntil = 0
        entitlements = [:]
        cloudAccount = [:]
        cloudAI = [:]
        cloudConsent = [:]
        cloudAccessError = nil
    }

    func checkLocalContext(_ context: UUID) throws {
        try Task.checkCancellation()
        guard context == localDataContext else {
            throw APIError(code: "SESSION_CHANGED", message: "账号或本地数据空间已切换，请重新打开页面")
        }
    }

    private func cloudConfigurationError() -> APIError {
        APIError(code: "CLOUD_AI_MANAGED", message: "云端 AI 由平台配置，请在允许的模型列表中选择")
    }

    func enterCloudAccount() async throws {
        guard let destination = officialCloudURL ?? (serverDeploymentMode == "cloud" ? CloudDeployment.validatedURL(serverURL) : nil) else {
            throw APIError(code: "CLOUD_NOT_CONFIGURED", message: "官方云地址尚未配置，可继续使用本地记录或已有私有服务器")
        }
        try await saveServerAddress(destination.absoluteString)
        guard isCloudMode, cloudReady else {
            throw APIError(code: "CLOUD_UNAVAILABLE", message: cloudAccessError ?? "官方云暂不可用，请稍后重试")
        }
    }

    func refreshCloudAccount() async {
        let context = localDataContext
        let address = serverURL
        let requestID = UUID()
        cloudRefreshID = requestID
        guard !address.isEmpty, address == UserDefaults.standard.string(forKey: "server_url") else { return }
        if let officialCloudURL, (try? ServerAddress.normalize(address)) != officialCloudURL {
            clearCloudAccess()
            cloudReady = false
            cloudAccessError = "请先切换到已配置的官方云服务"
            return
        }
        // 刷新期间保留尚未到期的展示租约；请求失败即收紧，避免抖动取消正常识别。
        do {
            if !deploymentChecked {
                let configuration: JSONObject
                do {
                    configuration = try await api.send("app/config", authenticated: false).object ?? [:]
                } catch let error as APIError where !isCloudMode && ["HTTP_404", "NOT_FOUND"].contains(error.code) {
                    // 老 NAS 没有该端点，只有明确 404 才按原有私有协议兼容。
                    configuration = ["deployment_mode": .string("private")]
                }
                try checkLocalContext(context)
                guard cloudRefreshID == requestID, serverURL == address else { return }
                let mode = configuration.text("deployment_mode")
                guard ["private", "cloud"].contains(mode), !isCloudMode || mode == "cloud" else {
                    throw APIError(code: "CLOUD_CONFIGURATION", message: "服务部署模式与当前客户端不一致")
                }
                if mode == "cloud", URL(string: address)?.scheme != "https" {
                    throw APIError(code: "CLOUD_HTTPS_REQUIRED", message: "官方云账号必须使用 HTTPS 地址")
                }
                serverDeploymentMode = mode
                UserDefaults.standard.set(mode, forKey: "server_deployment:" + address)
                deploymentChecked = true
                cloudReady = true
                if isCloudMode { loadAIConfiguration() }
            }
            guard isCloudMode else { return }
            guard let activeSession = session else { clearCloudAccess(); return }
            let account = try await api.send("me").object ?? [:]
            try checkLocalContext(context)
            guard cloudRefreshID == requestID else { return }
            let rights = try await api.send("me/entitlements").object ?? [:]
            try checkLocalContext(context)
            guard cloudRefreshID == requestID else { return }
            let consent = try await api.send("me/ai-consent").object ?? [:]
            try checkLocalContext(context)
            guard cloudRefreshID == requestID else { return }
            var preferences: JSONObject = [:]
            if rights.flag("ai_food_recognition") {
                preferences = try await api.send("me/ai-preferences").object ?? [:]
            }
            try checkLocalContext(context)
            guard cloudRefreshID == requestID, serverURL == address,
                  session?.userId == activeSession.userId, session?.instanceId == activeSession.instanceId else { return }
            cloudAccount = account
            entitlements = rights
            cloudConsent = consent
            cloudAI = preferences
            entitlementLeaseUntil = ProcessInfo.processInfo.systemUptime + CloudEntitlementLease.duration(rights)
            cloudAccessError = nil
        } catch {
            guard context == localDataContext, cloudRefreshID == requestID, serverURL == address else { return }
            entitlementLeaseUntil = 0
            entitlements = [:]
            cloudAI = [:]
            cloudConsent = [:]
            cloudAccessError = error.localizedDescription
        }
    }

    private func requireCloudAI() async throws {
        guard isCloudMode else { return }
        let context = localDataContext
        await refreshCloudAccount()
        try checkLocalContext(context)
        guard canUseAI else { throw APIError(code: "SVIP_REQUIRED", message: aiAccessMessage) }
    }

    func setCloudAIConsent(_ allowed: Bool) async throws {
        let context = localDataContext
        guard isCloudMode, session != nil else { throw APIError(code: "AUTH_REQUIRED", message: "请先登录云账号") }
        if allowed { try await requireCloudAI() }
        try checkLocalContext(context)
        let revision = cloudConsent.number("provider_revision") ?? cloudAI.number("provider_revision") ?? 0
        // 本机先停止新提交；服务器未确认时不声称已经停止外部处理。
        if !allowed { cloudConsent["allowed"] = .bool(false) }
        do {
            let result = try await api.send("me/ai-consent", method: "PUT", body: [
                "allowed": .bool(allowed), "provider_revision": .number(revision)
            ]).object ?? [:]
            try checkLocalContext(context)
            cloudConsent = result
        } catch {
            if !allowed, context == localDataContext {
                notice = "本机已停止新识别，撤回尚未获服务器确认，请联网后重试"
            }
            throw error
        }
    }

    func selectCloudAIModel(_ modelID: String) async throws {
        let context = localDataContext
        try await requireCloudAI()
        try checkLocalContext(context)
        let result = try await api.send("me/ai-preferences", method: "PUT", body: ["model_id": .string(modelID)]).object ?? [:]
        try checkLocalContext(context)
        cloudAI = result
    }

    func sendCloudEmailCode(email: String, purpose: String) async throws {
        try await prepareCloudAuthentication()
        _ = try await api.send("auth/email-code", method: "POST", body: [
            "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), "purpose": .string(purpose)
        ], authenticated: false)
    }

    private func prepareCloudAuthentication() async throws {
        if !isCloudMode || !cloudReady || !cloudServerSelected { try await enterCloudAccount() }
        guard isCloudMode, cloudReady, cloudServerSelected else { throw APIError(code: "CLOUD_UNAVAILABLE", message: "请先连接官方云") }
    }

    func authenticateCloud(email: String, password: String, displayName: String, emailCode: String,
                           register: Bool, mergeLocal: Bool) async throws {
        try await prepareCloudAuthentication()
        await stopBackgroundWork()
        defer { changingAccount = false }
        session = nil
        let context = localDataContext
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let deviceKey = "device:" + serverURL + ":" + address
        let accountDevice = UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString.lowercased()
        do {
            let credentials: SessionCredentials
            if register {
                credentials = try await api.registerCloud(email: address, password: password, name: displayName,
                                                          code: emailCode, deviceId: accountDevice)
            } else {
                credentials = try await api.login(username: address, password: password, deviceId: accountDevice, name: UIDevice.current.name)
            }
            try checkLocalContext(context)
            try await finishAuthentication(credentials, loginName: address, mergeLocal: mergeLocal)
        } catch {
            if context == localDataContext, session == nil { await api.clearSession() }
            throw error
        }
    }

    func resetCloudPassword(email: String, code: String, newPassword: String) async throws {
        try await prepareCloudAuthentication()
        _ = try await api.send("auth/reset-password", method: "POST", body: [
            "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            "email_code": .string(code), "new_password": .string(newPassword)
        ], authenticated: false)
    }

    func changeCloudPassword(currentPassword: String, newPassword: String) async throws {
        let context = localDataContext
        _ = try await api.send("me/password", method: "POST", body: [
            "current_password": .string(currentPassword), "new_password": .string(newPassword)
        ])
        try checkLocalContext(context)
        await logout()
    }

    func sendCloudEmailChangeCode(email: String, currentPassword: String) async throws {
        _ = try await api.send("me/email-code", method: "POST", body: [
            "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            "current_password": .string(currentPassword)
        ])
    }

    func changeCloudEmail(email: String, code: String, currentPassword: String) async throws {
        let context = localDataContext
        let account = try await api.send("me/email", method: "PUT", body: [
            "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
            "email_code": .string(code), "current_password": .string(currentPassword)
        ]).object ?? [:]
        try checkLocalContext(context)
        cloudAccount = account
    }

    func logoutAll() async throws {
        let context = localDataContext
        _ = try await api.send("auth/logout-all", method: "POST", body: [:])
        try checkLocalContext(context)
        await logout()
    }
}
