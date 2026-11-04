import PhotosUI
import SwiftUI

struct MealEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: AppRecord?
    @State private var meal: MealEntry
    @State private var mealId: String
    @State private var date: Date
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var editingFood: FoodItem?
    @State private var showSearch = false
    @State private var recognizing = false
    @State private var recognition: JSONObject = [:]
    @State private var showReview = false
    @State private var localError: String?
    @State private var saving = false
    @State private var initializedDate = false

    init(existing: AppRecord? = nil) {
        self.existing = existing
        let value = existing?.decode(MealEntry.self) ?? MealEntry()
        _meal = State(initialValue: value)
        _mealId = State(initialValue: existing?.id ?? UUID().uuidString.lowercased())
        _date = State(initialValue: TimeFormat.parse(value.eatenAt) ?? Date())
    }

    var body: some View {
        Form {
            Section("这一次进食") {
                Picker("餐次", selection: $meal.mealType) {
                    ForEach(MealTypes.all, id: \.self) { Text(MealTypes.name($0)).tag($0) }
                }
                DatePicker("进食时间", selection: $date, in: ...Date())
                TextField("备注，例如两人分食、少油", text: $meal.note, axis: .vertical)
            }
            Section("照片") {
                if !meal.photoIds.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(meal.photoIds, id: \.self) { id in
                                VStack {
                                    PhotoThumbnail(id: id)
                                    Button("移除", role: .destructive) { meal.photoIds.removeAll { $0 == id } }.font(.caption)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("拍照", systemImage: "camera") { showCamera = true }.disabled(meal.photoIds.count >= 6)
                    Spacer()
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: max(1, 6 - meal.photoIds.count), matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }.disabled(meal.photoIds.count >= 6)
                }
                Toggle("照片随个人数据同步", isOn: $meal.syncPhotos)
                Text("关闭后照片保存在本机。远程识别会单独上传照片供处理。").font(.caption).foregroundStyle(.secondary)
            }
            Section("食物与营养") {
                ForEach(meal.items) { item in
                    Button { editingFood = item } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).foregroundStyle(.primary)
                                Text("\(item.amount.concise) \(item.unit == "serving" ? "份" : item.unit) · 食用 \(Int(item.consumedFraction * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.kcal.map { "\($0.concise) kcal" } ?? "待补充").foregroundStyle(Palette.teal)
                        }
                    }
                    .contextMenu {
                        Button("收藏食物", systemImage: "star") { model.perform { try await model.favorite(item) } }
                        Button("移除食物", systemImage: "trash", role: .destructive) { meal.items.removeAll { $0.id == item.id } }
                    }
                }
                Button("手动添加食物", systemImage: "plus.circle") { editingFood = FoodItem(name: "") }
                Button("搜索营养库与常用食物", systemImage: "magnifyingglass") { showSearch = true }
            }
            Section("识别照片") {
                Picker("识别方式", selection: $model.aiMode) {
                    Text("本机端侧").tag("device")
                    Text("Responses API").tag("server")
                }.pickerStyle(.segmented)
                if model.aiMode == "server" {
                    let info = model.capabilities["ai"]?.object ?? [:]
                    Text(model.aiConfiguration.configured ? model.aiConfiguration.baseUrl : info.text("host", fallback: "在设置中配置 AI 服务"))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.aiConfiguration.external || info.flag("external") {
                        Toggle("同意发送本餐照片到外部 AI", isOn: $model.externalAIConsent)
                    }
                }
                Button {
                    Task { await recognize() }
                } label: {
                    HStack {
                        Label(recognizing ? "正在识别" : "识别这餐", systemImage: "viewfinder")
                        if recognizing { Spacer(); ProgressView() }
                    }
                }.disabled(meal.photoIds.isEmpty || recognizing)
                if let taskId = meal.aiTaskId {
                    Button("查看上次识别结果") {
                        Task {
                            do { try await presentTask(taskId) }
                            catch { localError = error.localizedDescription }
                        }
                    }
                    Button("取消远程识别", role: .destructive) {
                        model.perform { _ = try await model.api.send("ai/tasks/\(taskId)/cancel", method: "POST", body: [:]) }
                    }
                }
                PrivacyNote()
            }
            Section {
                Button("保存草稿") { Task { await commit(confirmed: false, close: true) } }
                Button("确认餐次") { Task { await commit(confirmed: true, close: true) } }
                    .disabled(meal.items.isEmpty || saving)
                    .fontWeight(.semibold)
            }
        }
        .navigationTitle(existing == nil ? "记一餐" : "编辑餐次")
        .task {
            if !initializedDate && existing == nil { date = model.entryDate }
            initializedDate = true
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in Task { await addPhoto(data) } }
        }
        .sheet(item: $editingFood) { food in
            NavigationStack {
                FoodEditorView(food: food) { changed in
                    if let index = meal.items.firstIndex(where: { $0.id == changed.id }) { meal.items[index] = changed }
                    else { meal.items.append(changed) }
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
                    if let current = model.records.first(where: { $0.id == mealId }), current.deletedAt != nil {
                        localError = "餐次已经删除，请新建餐次后再使用候选"
                        return
                    }
                    if replace { meal.items = items } else { meal.items.append(contentsOf: items) }
                    meal.aiResult = recognition
                }
            }
        }
        .onChange(of: pickedPhotos) { _, values in
            Task {
                for item in values {
                    if let data = try? await item.loadTransferable(type: Data.self) { await addPhoto(data) }
                }
                pickedPhotos = []
            }
        }
        .alert("请检查记录", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(localError ?? "") }
    }

    private func record(confirmed: Bool) throws -> AppRecord {
        var value = meal
        value.eatenAt = TimeFormat.iso(date)
        let unchangedTime = existing?.decode(MealEntry.self).flatMap { TimeFormat.parse($0.eatenAt) } == date
        value.timezone = unchangedTime ? meal.timezone : model.profile.timezone
        value.status = confirmed ? "confirmed" : "draft"
        let businessDate = unchangedTime ? existing?.businessDate : nil
        return try AppRecord(kind: "meal",
            day: businessDate ?? TimeFormat.day(date, timezone: model.profile.timezone, startMinutes: model.profile.dayStartMinutes),
            value: value, id: mealId)
    }

    private func addPhoto(_ data: Data) async {
        guard meal.photoIds.count < 6 else { return }
        do {
            let id = try await model.savePhoto(data, mealId: mealId)
            meal.photoIds.append(id)
            try await model.saveRecord(record(confirmed: false))
        } catch { localError = error.localizedDescription }
    }

    private func commit(confirmed: Bool, close: Bool) async {
        saving = true
        defer { saving = false }
        do {
            if confirmed && meal.items.isEmpty { throw APIError(code: "EMPTY_MEAL", message: "请先添加食物") }
            if confirmed && meal.items.contains(where: { $0.requiresPortion == true }) {
                throw APIError(code: "PORTION_REQUIRED", message: "请先打开候选食物，确认实际份量后再保存餐次")
            }
            try await model.saveRecord(record(confirmed: confirmed))
            if close { dismiss() }
        } catch { localError = error.localizedDescription }
    }

    private func recognize() async {
        recognizing = true
        defer { recognizing = false }
        do {
            try await model.saveRecord(record(confirmed: false))
            let current = try await model.requireStore().record(mealId) ?? record(confirmed: false)
            let result = try await model.recognize(record: current)
            if result["items"] != nil {
                recognition = result
                showReview = true
            } else if result.text("status") == "waiting" {
                localError = "照片已保存，连接恢复后会继续提交识别。你也可以先手动记录。"
            } else {
                let taskId = result.text("id")
                meal.aiTaskId = taskId
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(3))
                    let task = try await model.pollRecognition(taskId)
                    if task.text("status") == "completed" {
                        recognition = task["result"]?.object ?? [:]
                        showReview = true
                        return
                    }
                    if ["failed", "cancelled", "unknown", "expired"].contains(task.text("status")) {
                        throw APIError(code: "AI_TASK", message: task.text("error", fallback: "识别已停止，可手动记录或重新识别"))
                    }
                }
                localError = "任务仍在处理，可稍后点击查看上次识别结果"
            }
        } catch { localError = error.localizedDescription }
    }

    private func presentTask(_ taskId: String) async throws {
        let task = try await model.pollRecognition(taskId)
        guard task.text("status") == "completed", let result = task["result"]?.object else {
            throw APIError(code: "AI_TASK", message: task.text("error", fallback: "任务尚未完成，请稍后再看"))
        }
        recognition = result
        showReview = true
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
