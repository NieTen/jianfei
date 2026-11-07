import SwiftUI

struct FoodEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var food: FoodItem
    @State private var lockedKcal: Double?
    @State private var lockKcal: Bool
    @State private var showLockChoice = false
    @State private var error: String?
    private let original: FoodItem
    let onSave: (FoodItem) -> Void

    init(food: FoodItem, onSave: @escaping (FoodItem) -> Void) {
        original = food
        self.onSave = onSave
        _food = State(initialValue: food)
        _lockedKcal = State(initialValue: food.lockedValues["kcal"])
        _lockKcal = State(initialValue: food.lockedValues["kcal"] != nil)
    }

    var body: some View {
        AppForm {
            Section("食物") {
                FormField(title: "名称") {
                    TextField("名称", text: $food.name)
                }
                Picker("生熟状态", selection: $food.foodState) {
                    Text("未说明").tag("unknown")
                    Text("生重").tag("raw")
                    Text("熟重").tag("cooked")
                    Text("可食部分").tag("edible")
                }
                Picker("数据来源", selection: $food.source) {
                    Text("手动填写").tag("manual")
                    Text("包装标签").tag("package_label")
                    Text("营养数据库").tag("nutrition_database")
                    Text("AI 估算").tag("ai_estimate")
                }
            }
            Section("份量") {
                if food.requiresPortion == true {
                    Text("候选份量尚未确认，请核对实际数量后保存。").font(.caption).foregroundStyle(Palette.peach)
                }
                FormField(title: "实际数量") {
                    TextField("实际数量", value: $food.amount, format: .number).keyboardType(.decimalPad)
                }
                Picker("当前单位", selection: $food.unit) {
                    Text("克").tag("g")
                    Text("毫升").tag("ml")
                    Text("份").tag("serving")
                }.disabled(original.name != "")
                FormField(title: "每份重量 g，可选") {
                    TextField("每份重量 g，可选", value: $food.servingWeightG, format: .number).keyboardType(.decimalPad)
                }
                FormField(title: "密度 g/ml，可选") {
                    TextField("密度 g/ml，可选", value: $food.densityGMl, format: .number).keyboardType(.decimalPad)
                }
                Menu("按换算依据转换单位") {
                    Button("转换为克") { convert(to: "g") }
                    Button("转换为毫升") { convert(to: "ml") }
                    Button("转换为份") { convert(to: "serving") }
                }
                VStack(alignment: .leading) {
                    Text("实际食用 \(Int(food.consumedFraction * 100))%")
                    Slider(value: $food.consumedFraction, in: 0...1, step: 0.05)
                }
            }
            Section("营养基准") {
                FormField(title: "以下营养对应的数量") {
                    TextField("以下营养对应的数量", value: $food.basisAmount, format: .number).keyboardType(.decimalPad)
                }
                Text("单位与实际数量一致。包装每份数据可填写基准数量 1，单位选择份。").font(.caption).foregroundStyle(.secondary)
                FormField(title: "热量 kcal") {
                    TextField("热量 kcal", value: $food.basisKcal, format: .number).keyboardType(.decimalPad)
                }
                FormField(title: "蛋白质 g") {
                    TextField("蛋白质 g", value: $food.basisProteinG, format: .number).keyboardType(.decimalPad)
                }
                FormField(title: "碳水 g") {
                    TextField("碳水 g", value: $food.basisCarbsG, format: .number).keyboardType(.decimalPad)
                }
                FormField(title: "脂肪 g") {
                    TextField("脂肪 g", value: $food.basisFatG, format: .number).keyboardType(.decimalPad)
                }
                Text("未知数据可留空，记录完整度会提示补充。").font(.caption).foregroundStyle(.secondary)
            }
            Section("本次摄入") {
                Toggle("单独锁定本次热量", isOn: $lockKcal)
                if lockKcal { TextField("锁定热量 kcal", value: $lockedKcal, format: .number).keyboardType(.decimalPad) }
                LabeledContent("按份量计算的热量", value: food.kcal.map { "\($0.concise) kcal" } ?? "待补充")
                if !food.uncertaintyNote.isEmpty { Text(food.uncertaintyNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("食物详情")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    if food.amount != original.amount && !original.lockedValues.isEmpty { showLockChoice = true }
                    else { finish(scaleLocks: false) }
                }
            }
        }
        .confirmationDialog("份量已变化，请选择锁定数值的处理方式", isPresented: $showLockChoice) {
            Button("保留锁定值") { finish(scaleLocks: false) }
            Button("锁定值按份量同比调整") { finish(scaleLocks: true) }
            Button("取消", role: .cancel) {}
        }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func finish(scaleLocks: Bool) {
        guard !food.name.trimmingCharacters(in: .whitespaces).isEmpty, food.amount > 0, food.basisAmount > 0,
              [food.basisKcal, food.basisProteinG, food.basisCarbsG, food.basisFatG, lockedKcal].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            error = "请填写名称和正数份量，营养数值不能为负数"
            return
        }
        food.nutritionBasis = food.unit == "g" && food.basisAmount == 100 ? "per_100g" :
            food.unit == "ml" && food.basisAmount == 100 ? "per_100ml" :
            food.unit == "serving" && food.basisAmount == 1 ? "per_serving" : "total"
        if lockKcal, let lockedKcal {
            food.lockedValues["kcal"] = scaleLocks ? lockedKcal * food.amount / original.amount : lockedKcal
        } else { food.lockedValues.removeValue(forKey: "kcal") }
        food.requiresPortion = false
        onSave(food)
        dismiss()
    }

    private func convert(to unit: String) {
        guard food.unit != unit else { return }
        let gramsPerCurrent: Double?
        switch food.unit {
        case "g": gramsPerCurrent = 1
        case "ml": gramsPerCurrent = food.densityGMl
        default: gramsPerCurrent = food.servingWeightG
        }
        let gramsPerTarget: Double?
        switch unit {
        case "g": gramsPerTarget = 1
        case "ml": gramsPerTarget = food.densityGMl
        default: gramsPerTarget = food.servingWeightG
        }
        guard let current = gramsPerCurrent, let target = gramsPerTarget, current > 0, target > 0 else {
            error = "请先填写密度或每份重量，再转换单位"
            return
        }
        food.amount *= current / target
        food.basisAmount *= current / target
        food.unit = unit
        food.nutritionBasis = "total"
    }
}

struct FoodSearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var external = false
    @State private var results: [FoodItem] = []
    @State private var loading = false
    @State private var message = ""
    let onSelect: (FoodItem) -> Void

    var body: some View {
        AppList {
            FormIntro(title: "找到这一餐的食物", subtitle: "搜索营养库，或从常用食物中快速添加。", symbol: "magnifyingglass", color: Palette.peach)
            Section {
                FormField(title: "搜索食物名称") {
                    TextField("搜索食物名称", text: $query).onSubmit { Task { await search() } }
                }
                Toggle("同时查询已配置的 USDA 营养库", isOn: $external)
                Button("搜索") { Task { await search() } }.disabled(loading)
                if loading { ProgressView() }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("食物结果") {
                ForEach(results) { food in
                    Button {
                        onSelect(food)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(food.name)
                            Text(food.basisKcal.map { "\($0.concise) kcal / \(food.basisAmount.concise)\(food.unit)" } ?? "热量待补充")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if results.isEmpty { Text("收藏常用食物后，可在这里重复使用").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("营养库与常用食物")
        .toolbar { Button("关闭") { dismiss() } }
        .task { await search() }
    }

    private func search() async {
        loading = true
        defer { loading = false }
        results = model.favorites.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map(\.food)
        guard external else { return }
        do {
            let response = try await model.api.send("foods/search", query: ["q": query, "external": "true"]).object ?? [:]
            results = response.objects("items").compactMap { $0["food"]?.object }.compactMap { try? Codec.decode(FoodItem.self, from: $0) }
            message = response.flag("external_available") ? "数据库值为参考值，请核对实际食物及标签" : "服务器尚未配置营养数据库密钥，当前仅检索个人食物库"
        } catch { message = error.localizedDescription }
    }
}
