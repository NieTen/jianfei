import PhotosUI
import SwiftUI

struct MealEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: AppRecord?
    let initialMealType: String?
    @State private var meal: MealEntry
    @State private var mealId: String
    @State private var date: Date
    @State private var inputMode: String
    @State private var calories: Double?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var cameraData: Data?
    @State private var loadingPhotos = false
    @State private var editingFood: FoodItem?
    @State private var showSearch = false
    @State private var recognizing = false
    @State private var recognitionTask: Task<Void, Never>?
    @State private var recognition: JSONObject = [:]
    @State private var showReview = false
    @State private var localError: String?
    @State private var saving = false
    @State private var initializedDate = false
    @State private var manualFoodId = UUID().uuidString.lowercased()

    init(existing: AppRecord? = nil, initialMealType: String? = nil) {
        self.existing = existing
        self.initialMealType = initialMealType
        let value = existing?.decode(MealEntry.self) ?? MealEntry()
        _meal = State(initialValue: value)
        _mealId = State(initialValue: existing?.id ?? UUID().uuidString.lowercased())
        _date = State(initialValue: TimeFormat.parse(value.eatenAt) ?? Date())
        _inputMode = State(initialValue: MealInput.manualCalories(in: value) == nil ? "photo" : "manual")
        _calories = State(initialValue: MealInput.manualCalories(in: value))
    }

    private var busy: Bool { saving || recognizing || loadingPhotos }
    private var externalConsentNeeded: Bool {
        model.aiMode == "server" && (model.aiConfiguration.external || (model.capabilities["ai"]?.object ?? [:]).flag("external"))
    }

    var body: some View {
        Form {
            Section {
                MealTypeButtons(selection: $meal.mealType).disabled(busy)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("记录方式", selection: $inputMode) {
                    Text("拍照识别").tag("photo")
                    Text("手动热量").tag("manual")
                }.pickerStyle(.segmented).disabled(busy)
            }
            if inputMode == "manual" {
                Section {
                    HStack {
                        Text("摄入热量")
                        TextField("请输入", value: $calories, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("摄入热量").accessibilityIdentifier("meal.calories")
                        Text("kcal").foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                } footer: {
                    Text("只填本餐总热量即可。没有填写的蛋白质、碳水和脂肪保留为空。")
                }
                if !meal.items.isEmpty && MealInput.manualCalories(in: meal) == nil {
                    Text("保存手动热量后，将用本餐总热量替换原食物明细；切回拍照识别可继续编辑明细。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                photoSection
                if !meal.items.isEmpty {
                    Section("识别结果 · 可点选修改") {
                        ForEach(meal.items) { item in
                            Button { editingFood = item } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name).foregroundStyle(.primary)
                                        Text(item.requiresPortion == true ? "重量待确认" : "预计 \(item.amount.concise) \(item.unit == "g" ? "克" : item.unit == "ml" ? "毫升" : "份")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.kcal.map { "\($0.concise) kcal" } ?? "热量待补充").foregroundStyle(Palette.teal)
                                }
                            }.disabled(busy)
                            .contextMenu {
                                Button("收藏食物", systemImage: "star") { model.perform { try await model.favorite(item) } }
                                Button("移除食物", systemImage: "trash", role: .destructive) { meal.items.removeAll { $0.id == item.id } }
                            }
                        }
                        MealNutritionSummary(items: meal.items)
                        Text("照片结果为估算，核对后点击保存即可计入当天记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if recognizing {
                    HStack { ProgressView(); Text("正在识别食物、重量和营养…") }
                    Button("停止等待") { recognitionTask?.cancel() }
                } else if !meal.photoIds.isEmpty {
                    Button(meal.items.isEmpty ? "重试识别" : "重新识别照片", systemImage: "arrow.clockwise") { startRecognition() }
                        .disabled(busy)
                }
            }
            Section {
                DisclosureGroup("更多选项") {
                    TextField("备注，例如两人分食、少油", text: $meal.note, axis: .vertical)
                    Toggle("照片随个人数据同步", isOn: $meal.syncPhotos)
                    Text("关闭后照片留在本机，远程识别会另行发送选中的照片。")
                        .font(.caption).foregroundStyle(.secondary)
                    if inputMode == "photo" {
                        Button("手动添加食物明细", systemImage: "plus.circle") { editingFood = FoodItem(name: "") }
                        Button("营养库与常用食物", systemImage: "magnifyingglass") { showSearch = true }
                        HStack {
                            ForEach(MealTypes.all.filter { !MealInput.primaryTypes.contains($0) }, id: \.self) { type in
                                Button(MealTypes.name(type)) { meal.mealType = type }.buttonStyle(.borderless)
                            }
                        }
                        if !recognition.isEmpty { Button("查看候选明细") { showReview = true } }
                        Picker("识别方式", selection: $model.aiMode) {
                            Text("本机识别").tag("device")
                            Text("已配置的 AI").tag("server")
                        }
                        if let taskId = meal.aiTaskId {
                            Button("查看上次识别结果") {
                                Task { do { try await presentTask(taskId) } catch { localError = error.localizedDescription } }
                            }
                            Button("取消远程任务", role: .destructive) {
                                model.perform { _ = try await model.api.send("ai/tasks/\(taskId)/cancel", method: "POST", body: [:]) }
                            }
                        }
                    }
                    Button("保存草稿") { Task { await commit(confirmed: false) } }
                }.disabled(busy)
            }
        }
        .navigationTitle(existing == nil ? "记一餐" : "编辑餐次")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task {
            guard !initializedDate else { return }
            initializedDate = true
            if existing == nil {
                date = model.entryDate
                meal.mealType = initialMealType ?? MealInput.suggestedType(at: Date(), timezone: model.profile.timezone)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中" : "保存") { Task { await commit(confirmed: true) } }.disabled(busy)
            }
        }
        .sheet(isPresented: $showCamera, onDismiss: {
            guard let data = cameraData else { return }
            cameraData = nil
            Task { await importPhotos([data]) }
        }) { CameraPicker { cameraData = $0 } }
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhotos,
                      maxSelectionCount: max(1, 6 - meal.photoIds.count), matching: .images)
        .sheet(item: $editingFood) { food in
            NavigationStack {
                FoodEditorView(food: food) { changed in
                    var edited = changed
                    if changed != food && edited.source == "ai_estimate" { edited.source = "manual" }
                    if let index = meal.items.firstIndex(where: { $0.id == edited.id }) { meal.items[index] = edited }
                    else { meal.items.append(edited) }
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                FoodSearchView { item in
                    var copied = item
                    copied.id = UUID().uuidString.lowercased()
                    meal.items.append(copied)
                }
            }
        }
        .sheet(isPresented: $showReview) {
            NavigationStack {
                RecognitionReviewView(result: recognition) { items, replace in
                    if replace { meal.items = items } else { meal.items.append(contentsOf: items) }
                    meal.aiResult = recognition
                }
            }
        }
        .onChange(of: pickedPhotos) { _, values in
            guard !values.isEmpty else { return }
            pickedPhotos = []
            Task {
                loadingPhotos = true
                var data: [Data] = []
                for item in values {
                    do {
                        guard let value = try await item.loadTransferable(type: Data.self) else {
                            throw APIError(code: "PHOTO_LOAD", message: "这张照片暂时无法读取，请确认照片已从 iCloud 下载后重试")
                        }
                        data.append(value)
                    } catch { localError = "照片读取失败：\(error.localizedDescription)" }
                }
                await importPhotos(data)
            }
        }
        .onDisappear { recognitionTask?.cancel() }
        .alert("请检查记录", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(localError ?? "") }
    }

    private var photoSection: some View {
        Section {
            HStack(spacing: 12) {
                Button { showCamera = true } label: {
                    Label("拍照", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.bordered).accessibilityIdentifier("meal.camera")
                Button { showPhotos = true } label: {
                    Label("从相册选择", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.bordered).accessibilityIdentifier("meal.photos")
            }.disabled(busy || meal.photoIds.count >= 6)
            if loadingPhotos { ProgressView("正在读取照片…") }
            if !meal.photoIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(meal.photoIds, id: \.self) { id in
                            VStack {
                                PhotoThumbnail(id: id)
                                Button("移除", role: .destructive) { meal.photoIds.removeAll { $0 == id } }
                                    .buttonStyle(.borderless).font(.caption).disabled(busy)
                            }
                        }
                    }
                }
            }
            if externalConsentNeeded && !model.externalAIConsent {
                Toggle("允许将所选餐食照片发送到配置的 AI", isOn: $model.externalAIConsent)
            }
            if model.aiMode == "device" {
                NavigationLink("配置 AI，自动估算重量与热量") { AIConnectionEditorView() }
                Text("本机识别只提供食物类别，配置 AI 后可估算重量、热量和营养。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("选择照片后自动识别食物、预计重量、热量与营养。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func record(confirmed: Bool) throws -> AppRecord {
        var value = meal
        if inputMode == "manual" {
            if let calories {
                value.items = [try MealInput.calorieItem(calories, id: MealInput.manualCalories(in: meal) == nil ? manualFoodId : meal.items[0].id)]
            } else if confirmed {
                throw APIError(code: "CALORIES_REQUIRED", message: "请填写这餐摄入的热量")
            } else { value.items = [] }
        }
        value.eatenAt = TimeFormat.iso(date)
        value.timezone = existing == nil ? model.profile.timezone : meal.timezone
        value.status = confirmed ? "confirmed" : "draft"
        return try AppRecord(kind: "meal", day: existing?.businessDate ?? TimeFormat.day(date, timezone: model.profile.timezone,
            startMinutes: model.profile.dayStartMinutes), value: value, id: mealId)
    }

    private func importPhotos(_ data: [Data]) async {
        loadingPhotos = true
        var added = false
        for image in data where meal.photoIds.count < 6 {
            do {
                let id = try await model.savePhoto(image, mealId: mealId)
                meal.photoIds.append(id)
                added = true
            } catch { localError = error.localizedDescription }
        }
        loadingPhotos = false
        if added { startRecognition() }
    }

    private func commit(confirmed: Bool) async {
        guard !busy else { return }
        saving = true
        defer { saving = false }
        do {
            let value = try record(confirmed: confirmed)
            try await model.saveRecord(value)
            dismiss()
        } catch { localError = error.localizedDescription }
    }

    private func startRecognition() {
        guard !busy, !meal.photoIds.isEmpty else { return }
        recognizing = true
        recognitionTask = Task { await recognize() }
    }

    private func recognize() async {
        defer { recognizing = false }
        do {
            try await model.saveRecord(record(confirmed: false))
            let current = try await model.requireStore().record(mealId) ?? record(confirmed: false)
            let result = try await model.recognize(record: current)
            try Task.checkCancellation()
            if result["items"] != nil {
                try applyRecognition(result)
                try await model.saveRecord(record(confirmed: false))
            }
            else if result.text("status") == "waiting" {
                localError = "照片已保存，连接恢复后会继续提交识别，也可改为手动填写热量。"
            } else {
                let taskId = result.text("id")
                guard !taskId.isEmpty else { throw APIError(code: "AI_TASK", message: "识别任务未创建，请重试") }
                meal.aiTaskId = taskId
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(3))
                    let task = try await model.pollRecognition(taskId)
                    try Task.checkCancellation()
                    if task.text("status") == "completed" {
                        try applyRecognition(task["result"]?.object ?? [:])
                        try await model.saveRecord(record(confirmed: false))
                        return
                    }
                    if ["failed", "cancelled", "unknown", "expired"].contains(task.text("status")) {
                        throw APIError(code: "AI_TASK", message: task.text("error", fallback: "识别已停止，可手动填写热量或重试"))
                    }
                }
                localError = "识别仍在处理，可稍后在更多选项中查看上次结果"
            }
        } catch is CancellationError { }
        catch { localError = error.localizedDescription }
    }

    private func applyRecognition(_ result: JSONObject) throws {
        if model.records.first(where: { $0.id == mealId })?.deletedAt != nil {
            throw APIError(code: "ENTITY_DELETED", message: "餐次已经删除，请重新记录")
        }
        let items = try result.objects("items").map { try Codec.decode(FoodItem.self, from: $0) }
        guard !items.isEmpty else { throw APIError(code: "NO_FOOD", message: "没有识别到可靠的食物，请换一张照片或手动填写热量") }
        for item in items { try RecordValidator.food(item) }
        recognition = result
        meal.items = MealInput.applyingRecognition(items, to: meal.items)
        meal.aiResult = result
    }

    private func presentTask(_ taskId: String) async throws {
        let task = try await model.pollRecognition(taskId)
        guard task.text("status") == "completed", let result = task["result"]?.object else {
            throw APIError(code: "AI_TASK", message: task.text("error", fallback: "任务尚未完成，请稍后再看"))
        }
        try applyRecognition(result)
    }
}

struct MealTypeButtons: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 10) {
            ForEach(MealInput.primaryTypes, id: \.self) { type in
                Button { selection = type } label: {
                    Text(MealTypes.name(type)).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(selection == type ? .white : Palette.teal)
                        .background(selection == type ? Palette.teal : Palette.soft, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == type ? .isSelected : [])
                    .accessibilityIdentifier("meal.type.\(type)")
            }
        }
        // 保留旧加餐、饮料等类型的编辑能力，常用三餐始终直接可见。
        if !MealInput.primaryTypes.contains(selection) {
            Text("当前餐次：\(MealTypes.name(selection))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MealNutritionSummary: View {
    let items: [FoodItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本餐合计").font(.headline)
                Spacer()
                Text(MealInput.nutrient(items, value: { $0.kcal }).map { "\($0.concise) kcal" } ?? "热量待补充")
                    .font(.headline).foregroundStyle(Palette.teal)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { nutrients }
                VStack(alignment: .leading, spacing: 10) { nutrients }
            }
        }.padding(.vertical, 8)
    }
    @ViewBuilder private var nutrients: some View {
        MetricView(title: "蛋白质", value: MealInput.nutrient(items, value: { $0.protein }), unit: "g")
        MetricView(title: "碳水", value: MealInput.nutrient(items, value: { $0.carbs }), unit: "g")
        MetricView(title: "脂肪", value: MealInput.nutrient(items, value: { $0.fat }), unit: "g")
    }
}

struct RecognitionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let result: JSONObject
    let onApply: ([FoodItem], Bool) -> Void
    @State private var items: [FoodItem]
    @State private var editing: FoodItem?

    init(result: JSONObject, onApply: @escaping ([FoodItem], Bool) -> Void) {
        self.result = result
        self.onApply = onApply
        _items = State(initialValue: result.objects("items").compactMap { try? Codec.decode(FoodItem.self, from: $0) })
    }

    var body: some View {
        List {
            Section {
                Text(result.text("uncertainty_note", fallback: "请核对食物、份量和营养")).font(.subheadline)
                Text("模型 \(result.text("model_name"))").font(.caption).foregroundStyle(.secondary)
            }
            Section("候选食物") {
                ForEach(items) { food in
                    Button { editing = food } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(food.name)
                                Text("\(food.amount.concise) \(food.unit) · 估算").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(food.kcal.map { "\($0.concise) kcal" } ?? "营养待填写")
                        }
                    }
                }.onDelete { indices in items.remove(atOffsets: indices) }
                if items.isEmpty { Text("没有可靠候选，可返回手动添加食物").foregroundStyle(.secondary) }
            }
            Section {
                Button("将候选合并到餐次") { onApply(items, false); dismiss() }.disabled(items.isEmpty)
                Button("用候选替换餐次食物") { onApply(items, true); dismiss() }.disabled(items.isEmpty)
                Text("应用候选后仍需在餐次页面确认，才会计入摄入。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("确认识别候选")
        .toolbar { Button("关闭") { dismiss() } }
        .sheet(item: $editing) { food in
            NavigationStack {
                FoodEditorView(food: food) { changed in
                    if let index = items.firstIndex(where: { $0.id == changed.id }) { items[index] = changed }
                }
            }
        }
    }
}
