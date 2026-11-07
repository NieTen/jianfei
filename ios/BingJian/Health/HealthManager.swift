import Foundation
import HealthKit
import CryptoKit

@MainActor
final class HealthManager: ObservableObject {
    private let healthStore = HKHealthStore()
    @Published var refreshing = false
    @Published var progress: Double = 0
    @Published var status = "尚未读取健康数据"
    @Published private(set) var accessIssue: String?
    private var observers: [HKObserverQuery] = []
    var onUpdate: (() -> Void)?
    var onAccessIssue: (() -> Void)?

    let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .stepCount, .activeEnergyBurned, .basalEnergyBurned, .heartRate, .restingHeartRate,
        .bodyFatPercentage, .distanceWalkingRunning, .appleExerciseTime
    ]

    func authorize() async throws {
        do { try await authorizeAvailable() }
        catch { throw reportFailure(error) }
    }

    private func authorizeAvailable() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw APIError(code: "HEALTH_UNAVAILABLE", message: "当前设备无法读取健康数据")
        }
        var types: Set<HKObjectType> = Set(quantityIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) })
        for identifier in [HKQuantityTypeIdentifier.bodyMass, .height] {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let birthday = HKCharacteristicType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(birthday) }
        if let sex = HKCharacteristicType.characteristicType(forIdentifier: .biologicalSex) { types.insert(sex) }
        types.insert(HKObjectType.workoutType())
        try await healthStore.requestAuthorization(toShare: [], read: types)
        accessIssue = nil
        UserDefaults.standard.set(true, forKey: "health_enabled")
        installObservers()
        status = "已请求读取权限，无数据时仍可手动记录"
    }

    func installObservers() {
        guard observers.isEmpty, accessIssue == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let sampleTypes: [HKSampleType] = quantityIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) } +
            [HKObjectType.workoutType(), HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
             HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!]
        for type in sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor in
                    if let error { _ = self?.reportFailure(error) }
                    else { self?.onUpdate?() }
                    completion()
                }
            }
            healthStore.execute(query)
            observers.append(query)
            healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { [weak self] _, error in
                if let error { Task { @MainActor in _ = self?.reportFailure(error) } }
            }
        }
    }

    func refresh(store: LocalDatabase, profile: BodyProfile, deviceId: String, historyStart: Date? = nil) async throws {
        if let accessIssue { throw APIError(code: HealthAccessError.missingCapabilityCode, message: accessIssue) }
        do { try await refreshAvailable(store: store, profile: profile, deviceId: deviceId, historyStart: historyStart) }
        catch { throw reportFailure(error) }
    }

    private func refreshAvailable(store: LocalDatabase, profile: BodyProfile, deviceId: String, historyStart: Date?) async throws {
        guard !refreshing else { return }
        if try await store.metadata("health_disabled_after_delete") == "true" { return }
        refreshing = true
        progress = 0
        defer { refreshing = false }
        let initial = try await store.metadata("health_initial_complete") == nil
        let defaultStart = Calendar.current.date(byAdding: .month, value: -12, to: Date()) ?? Date()
        let start = historyStart ?? defaultStart
        var days = Set<String>()
        if initial || historyStart != nil {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: profile.timezone) ?? .current
            var current = start
            while current <= Date() {
                days.insert(TimeFormat.day(current, timezone: profile.timezone, startMinutes: profile.dayStartMinutes))
                current = calendar.date(byAdding: .day, value: 1, to: current) ?? Date().addingTimeInterval(1)
            }
        }
        days.insert(TimeFormat.day(timezone: profile.timezone, startMinutes: profile.dayStartMinutes))
        let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
        let workoutType = HKObjectType.workoutType()
        let types: [HKSampleType] = quantityIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) } +
            [weightType, workoutType, HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!]
        for type in types {
            try Task.checkCancellation()
            let changed = try await importChanges(type: type, start: start, reset: historyStart != nil,
                                                  store: store, profile: profile, deviceId: deviceId)
            days.formUnion(changed)
        }
        let queued = try await store.metadataPrefix("health_dirty:")
        days.formUnion(queued.keys.map { String($0.dropFirst("health_dirty:".count)) })
        let savedRecords = try await store.allRecords()
        let index = await Task.detached(priority: .utility) { RecordIndex(records: savedRecords) }.value
        let sorted = days.sorted()
        for (position, day) in sorted.enumerated() {
            try Task.checkCancellation()
            let existing = (index.byDay[day] ?? []).filter { $0.kind == "health_day" }.max { $0.updatedAt < $1.updatedAt }
            let original = existing?.decode(HealthDay.self)
            let historical = index.profiles.first { $0.businessDate <= day }?.decode(BodyProfile.self) ?? profile
            let timezone = original?.timezone ?? historical.timezone
            var startMinutes = historical.dayStartMinutes
            if let original, let start = TimeFormat.parse(original.windowStart) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: timezone) ?? .current
                let parts = calendar.dateComponents([.hour, .minute], from: start)
                startMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
            guard let window = TimeFormat.window(day, timezone: timezone, startMinutes: startMinutes) else { continue }
            let end = min(window.end, Date())
            if end <= window.start { continue }
            status = "正在读取 \(day)"
            let health = try await daily(start: window.start, end: end, timezone: timezone)
            let record = try AppRecord(kind: "health_day", day: day, value: health,
                id: existing?.id ?? stableId("health_day:\(day):\(timezone):\(startMinutes)"))
            try await store.save(record, deviceId: deviceId)
            try await store.setMetadata("health_dirty:" + day, value: nil)
            progress = Double(position + 1) / Double(max(1, sorted.count))
        }
        try await store.setMetadata("health_initial_complete", value: "true")
        try await store.setMetadata("last_health_read", value: TimeFormat.iso())
        status = "已刷新可读取数据，缺失项可能尚无记录或未授权"
    }

    private func importChanges(type: HKSampleType, start: Date, reset: Bool, store: LocalDatabase,
                               profile: BodyProfile, deviceId: String) async throws -> Set<String> {
        let key = "health_anchor:" + type.identifier
        var anchor: HKQueryAnchor?
        if !reset, let encoded = try await store.metadata(key), let data = Data(base64Encoded: encoded) {
            anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
        var changedDays = Set<String>()
        while true {
            try Task.checkCancellation()
            let (samples, deleted, next) = try await anchored(type: type, start: start, anchor: anchor)
            var metadata: [String: String] = [:]
            for sample in samples {
                let day = TimeFormat.day(sample.startDate, timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
                let endDay = TimeFormat.day(sample.endDate, timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
                changedDays.insert(day)
                changedDays.insert(endDay)
                let id = sample.uuid.uuidString.lowercased()
                metadata["health_sample:" + id] = day + "," + endDay
                metadata["health_dirty:" + day] = "true"
                metadata["health_dirty:" + endDay] = "true"
                if type.identifier == HKQuantityTypeIdentifier.bodyMass.rawValue, let weight = sample as? HKQuantitySample {
                    let value = WeightEntry(measuredAt: TimeFormat.iso(sample.startDate),
                        weightKg: weight.quantity.doubleValue(for: .gramUnit(with: .kilo)), source: "healthkit",
                        sourceId: id, sourceName: sample.sourceRevision.source.name)
                    var record = try AppRecord(kind: "weight", day: day, value: value, id: id, sourceId: id)
                    if let existing = try await store.record(id), let original = existing.decode(WeightEntry.self) {
                        record.businessDate = existing.businessDate
                        changedDays.insert(existing.businessDate)
                        metadata["health_dirty:" + existing.businessDate] = "true"
                        var preserved = value
                        preserved.hidden = original.hidden
                        preserved.correctedWeightKg = original.correctedWeightKg
                        preserved.note = original.note
                        preserved.representative = original.representative
                        record.payload = try Codec.object(preserved)
                    }
                    try await store.save(record, deviceId: deviceId)
                } else if let workout = sample as? HKWorkout {
                    let value = WorkoutEntry(startAt: TimeFormat.iso(workout.startDate), endAt: TimeFormat.iso(workout.endDate),
                        activityType: workoutName(workout.workoutActivityType), durationMinutes: workout.duration / 60,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
                        sourceId: id, sourceName: workout.sourceRevision.source.name)
                    let originalDay = try await store.record(id)?.businessDate ?? day
                    changedDays.insert(originalDay)
                    metadata["health_dirty:" + originalDay] = "true"
                    try await store.save(AppRecord(kind: "workout", day: originalDay, value: value, id: id, sourceId: id), deviceId: deviceId)
                }
            }
            for deletedSample in deleted {
                let id = deletedSample.uuid.uuidString.lowercased()
                if let dates = try await store.metadata("health_sample:" + id) {
                    for day in dates.split(separator: ",").map(String.init) {
                        changedDays.insert(day)
                        metadata["health_dirty:" + day] = "true"
                    }
                }
                if var record = try await store.record(id) {
                    record.payload["source_deleted"] = .bool(true)
                    try await store.save(record, deviceId: deviceId)
                }
            }
            if let next {
                metadata[key] = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true).base64EncodedString()
            }
            try await store.setMetadataBatch(metadata)
            anchor = next
            if samples.count + deleted.count < 500 { break }
        }
        return changedDays
    }

    private func anchored(type: HKSampleType, start: Date, anchor: HKQueryAnchor?) async throws -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
                                             anchor: anchor, limit: 500) { _, samples, deleted, next, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples ?? [], deleted ?? [], next)) }
            }
            healthStore.execute(query)
        }
    }

    private func statistic(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                           average: Bool = false) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let options: HKStatisticsOptions = average ? .discreteAverage : .cumulativeSum
            let query = HKStatisticsQuery(quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end), options: options) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let quantity = average ? result?.averageQuantity() : result?.sumQuantity()
                    continuation.resume(returning: quantity?.doubleValue(for: unit))
                }
            }
            healthStore.execute(query)
        }
    }

    private func samples(type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }

    private func daily(start: Date, end: Date, timezone: String) async throws -> HealthDay {
        var result = HealthDay(timezone: timezone, windowStart: TimeFormat.iso(start), windowEnd: TimeFormat.iso(end))
        result.steps = try await statistic(.stepCount, unit: .count(), start: start, end: end)
        result.activeKcal = try await statistic(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end)
        result.restingKcal = try await statistic(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end)
        result.heartRate = try await statistic(.heartRate, unit: .count().unitDivided(by: .minute()), start: start, end: end, average: true)
        result.restingHeartRate = try await statistic(.restingHeartRate, unit: .count().unitDivided(by: .minute()), start: start, end: end, average: true)
        result.bodyFatPercent = try await statistic(.bodyFatPercentage, unit: .percent(), start: start, end: end, average: true).map { $0 * 100 }
        result.distanceKm = try await statistic(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), start: start, end: end)
        result.workoutMinutes = try await statistic(.appleExerciseTime, unit: .minute(), start: start, end: end)
        let resting = try await samples(type: HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!, start: start, end: end)
        if !resting.isEmpty { result.restingCoverage = coveredSeconds(resting.map { DateInterval(start: max(start, $0.startDate), end: min(end, $0.endDate)) }) / end.timeIntervalSince(start) }
        let sleep = try await samples(type: HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!, start: start, end: end)
        let sleeping = sleep.compactMap { $0 as? HKCategorySample }.filter { ![HKCategoryValueSleepAnalysis.inBed.rawValue, HKCategoryValueSleepAnalysis.awake.rawValue].contains($0.value) }
        if !sleeping.isEmpty {
            result.sleepHours = coveredSeconds(sleeping.map { DateInterval(start: max(start, $0.startDate), end: min(end, $0.endDate)) }) / 3600
        }
        return result
    }

    private func coveredSeconds(_ intervals: [DateInterval]) -> Double {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var total: Double = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end { current = DateInterval(start: current.start, end: max(current.end, interval.end)) }
            else { total += current.duration; current = interval }
        }
        return total + current.duration
    }

    func importedProfile() async throws -> BodyProfile {
        if let accessIssue { throw APIError(code: HealthAccessError.missingCapabilityCode, message: accessIssue) }
        do { return try await importAvailableProfile() }
        catch { throw reportFailure(error) }
    }

    func reportFailure(_ error: Error) -> Error {
        let translated = HealthAccessError.translated(error)
        status = translated.localizedDescription
        if let failure = translated as? APIError, failure.code == HealthAccessError.missingCapabilityCode {
            accessIssue = failure.message
            UserDefaults.standard.set(false, forKey: "health_enabled")
            for observer in observers { healthStore.stop(observer) }
            observers.removeAll()
            onAccessIssue?()
        }
        return translated
    }

    private func importAvailableProfile() async throws -> BodyProfile {
        var result = BodyProfile()
        if let birthday = try? healthStore.dateOfBirthComponents(),
           let date = Calendar.current.date(from: birthday) { result.birthDate = TimeFormat.day(date) }
        if let sex = try? healthStore.biologicalSex().biologicalSex {
            result.sexForFormula = sex == .male ? "male" : sex == .female ? "female" : "unspecified"
        }
        if let heightType = HKQuantityType.quantityType(forIdentifier: .height) {
            let values = try await samples(type: heightType, start: Date.distantPast, end: Date())
            result.heightCm = (values.sorted { $0.endDate > $1.endDate }.first as? HKQuantitySample)?.quantity.doubleValue(for: .meterUnit(with: .centi))
        }
        return result
    }

    private func stableId(_ value: String) -> String {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }

    private func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "步行"
        case .running: return "跑步"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .yoga: return "瑜伽"
        case .hiking: return "徒步"
        default: return "其他运动"
        }
    }
}
