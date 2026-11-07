import SwiftUI

struct WeightEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var existing: AppRecord?
    @State private var amount: Double?
    @State private var unit = WeightUnit.kg
    @State private var measuredAt = Date()
    @State private var selectedDay = Date()
    @State private var note = ""
    @State private var saving = false
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("体重") {
                DatePicker("日期", selection: Binding(get: { selectedDay }, set: { value in
                    selectedDay = value
                    let day = TimeFormat.day(value, timezone: model.profile.timezone)
                    measuredAt = RecordDate.timestamp(for: day, profile: model.profile)
                    amount = nil
                }), in: ...Date(), displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: model.profile.timezone) ?? .current)
                    .disabled(existing?.decode(WeightEntry.self)?.source == "healthkit")
                WeightInputRow(amount: $amount, unit: $unit)
                Text("自动带入上次体重；切换日期后请重新填写。当天显示最后一次测量。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("记录时间与备注（可选）") {
                    DatePicker("测量时刻", selection: Binding(get: { measuredAt }, set: { value in
                        measuredAt = value
                        let day = TimeFormat.day(value, timezone: model.profile.timezone, startMinutes: model.profile.dayStartMinutes)
                        selectedDay = TimeFormat.window(day, timezone: model.profile.timezone)?.start ?? value
                        amount = nil
                    }), in: ...Date(), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(identifier: model.profile.timezone) ?? .current)
                        .disabled(existing?.decode(WeightEntry.self)?.source == "healthkit")
                    Text("默认使用当前时刻，调整后请重新填写重量。").font(.caption).foregroundStyle(.secondary)
                    TextField("测量备注", text: $note, axis: .vertical)
                }
            }
            if existing?.decode(WeightEntry.self)?.source == "healthkit" {
                Section { Text("本次保存为关联修正，健康 App 中的原始测量仍可追溯。").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("记录体重")
        .modifier(KeyboardDismissToolbar())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中" : "保存") { Task { await save() } }.disabled(saving) }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let previous = existing?.decode(WeightEntry.self)
            let kg = previous?.correctedWeightKg ?? previous?.weightKg
                ?? EnergyCalculator.weight(model.recordIndex.forSummary(day: model.day), day: model.day)
            unit = model.weightUnit
            amount = kg.map { unit.fromKilograms($0) }
            measuredAt = previous.flatMap { TimeFormat.parse($0.measuredAt) } ?? model.entryDate
            selectedDay = TimeFormat.window(existing?.businessDate ?? model.day, timezone: model.profile.timezone)?.start ?? measuredAt
            note = previous?.note ?? ""
        }
        .alert("请检查体重", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func save() async {
        guard !saving else { return }
        guard let amount, amount > 0 else { message = "请输入有效体重"; return }
        saving = true
        defer { saving = false }
        do {
            try await model.recordWeight(amount, unit: unit, measuredAt: measuredAt, note: note,
                                         representative: false, existing: existing)
            dismiss()
        }
        catch { message = error.localizedDescription }
    }
}

struct MeasurementEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = MeasurementEntry()
    @State private var muscleAmount: Double?
    @State private var unit = WeightUnit.kg
    @State private var loaded = false
    @State private var date = Date()
    @State private var message: String?
    var existing: AppRecord?
    var body: some View {
        Form {
            DatePicker("测量时间", selection: $date, in: ...Date())
            TextField("腰围 cm", value: $value.waistCm, format: .number).keyboardType(.decimalPad)
            TextField("臀围 cm", value: $value.hipCm, format: .number).keyboardType(.decimalPad)
            TextField("体脂率 %", value: $value.bodyFatPercent, format: .number).keyboardType(.decimalPad)
            TextField("肌肉量 \(unit.name)", value: $muscleAmount, format: .number).keyboardType(.decimalPad)
            TextField("来源或测量条件", text: $value.note, axis: .vertical)
        }
        .navigationTitle("身体组成与围度")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task {
                        value.muscleKg = muscleAmount.map { unit.kilograms(from: $0) }
                        let values = [value.waistCm, value.hipCm, value.bodyFatPercent, value.muscleKg].compactMap { $0 }
                        guard !values.isEmpty, values.allSatisfy({ $0 > 0 }), (value.bodyFatPercent ?? 0) <= 100 else {
                            message = "至少填写一个有效指标，体脂率范围为 0～100%"
                            return
                        }
                        value.measuredAt = TimeFormat.iso(date)
                        do {
                            let record = try AppRecord(kind: "measurement", day: TimeFormat.day(date, timezone: model.profile.timezone, startMinutes: model.profile.dayStartMinutes),
                                                       value: value, id: existing?.id ?? UUID().uuidString.lowercased())
                            try await model.saveRecord(record)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            unit = model.weightUnit
            if let original = existing?.decode(MeasurementEntry.self) {
                value = original
                date = TimeFormat.parse(original.measuredAt) ?? Date()
            }
            muscleAmount = value.muscleKg.map { unit.fromKilograms($0) }
        }
        .alert("请检查数据", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile = BodyProfile()
    @State private var goal = GoalEntry()
    @State private var birthday = Date()
    @State private var useBirthday = false
    @State private var endDate = Date()
    @State private var feet: Double?
    @State private var inches: Double?
    @State private var targetWeight: Double?
    @State private var weightUnit = WeightUnit.kg
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("个人档案") {
                TextField("称呼", text: $profile.displayName)
                Toggle("填写出生日期", isOn: $useBirthday)
                if useBirthday { DatePicker("生日", selection: $birthday, in: ...Date(), displayedComponents: .date) }
                else { TextField("年龄，可留空", value: $profile.age, format: .number).keyboardType(.numberPad) }
                Picker("代谢公式参数", selection: $profile.sexForFormula) {
                    Text("不提供").tag("unspecified")
                    Text("男性公式").tag("male")
                    Text("女性公式").tag("female")
                }
                if profile.heightUnit == "ft-in" {
                    HStack {
                        TextField("英尺", value: $feet, format: .number)
                        TextField("英寸", value: $inches, format: .number)
                    }.keyboardType(.decimalPad)
                } else {
                    TextField("身高 cm", value: $profile.heightCm, format: .number).keyboardType(.decimalPad)
                }
                Button("从健康读取可用档案") {
                    Task {
                        do {
                            let imported = try await model.health.importedProfile()
                            if let value = imported.heightCm { profile.heightCm = value }
                            if let date = imported.birthDate { profile.birthDate = date; birthday = TimeFormat.window(date, timezone: profile.timezone)?.start ?? Date(); useBirthday = true }
                            profile.sexForFormula = imported.sexForFormula
                        } catch { message = error.localizedDescription }
                    }
                }
            }
            Section("个人目标") {
                TextField("目标体重 \(weightUnit.name)", value: $targetWeight, format: .number).keyboardType(.decimalPad)
                DatePicker("目标结束日期", selection: $endDate, in: Date()..., displayedComponents: .date)
                TextField("每日步数目标", value: $goal.stepGoal, format: .number).keyboardType(.numberPad)
                Picker("日常活动水平", selection: $profile.activityFactor) {
                    Text("久坐").tag(1.2)
                    Text("轻度活动").tag(1.375)
                    Text("中度活动").tag(1.55)
                    Text("高度活动").tag(1.725)
                    Text("极高活动").tag(1.9)
                }
                TextField("实测单步长度 m，可留空", value: $profile.stepLengthM, format: .number).keyboardType(.decimalPad)
                Text("单步长度可用实测距离除以步数得到，用于缺少活动能量时的步行回退估算。").font(.caption).foregroundStyle(.secondary)
            }
            Section("常规餐次") {
                Text("餐次调整从下一个统计日生效，历史日期沿用当天模板。").font(.caption).foregroundStyle(.secondary)
                ForEach(MealTypes.all, id: \.self) { type in
                    Toggle(MealTypes.name(type), isOn: Binding(
                        get: { profile.routineMeals.contains(type) },
                        set: { enabled in
                            if enabled { profile.routineMeals.append(type) }
                            else { profile.routineMeals.removeAll { $0 == type } }
                        }
                    ))
                }
            }
            Section("单位与统计时间") {
                Picker("本机体重单位", selection: Binding(get: { weightUnit }, set: { unit in
                    targetWeight = targetWeight.map { weightUnit.converted($0, to: unit) }
                    weightUnit = unit
                })) { ForEach(WeightUnit.allCases) { Text($0.title).tag($0) } }
                Text("伙伴数据也会转换为你的单位；伙伴看到的数据按他们自己的单位显示。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("身高单位", selection: Binding(get: { profile.heightUnit }, set: { unit in
                    if unit == "ft-in", let cm = profile.heightCm {
                        feet = floor(cm / 30.48)
                        inches = (cm - (feet ?? 0) * 30.48) / 2.54
                    } else if profile.heightUnit == "ft-in", let feet {
                        profile.heightCm = feet * 30.48 + (inches ?? 0) * 2.54
                    }
                    profile.heightUnit = unit
                })) { Text("厘米").tag("cm"); Text("英尺 / 英寸").tag("ft-in") }
                Picker("能量单位", selection: $profile.energyUnit) { Text("kcal").tag("kcal"); Text("kJ").tag("kJ") }
                Picker("统计时区", selection: $profile.timezone) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Picker("一天开始时间", selection: $profile.dayStartMinutes) {
                    ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour * 60) }
                }
                Text("挑战开始后双方或小组使用已确认的统计时区与日界线。").font(.caption).foregroundStyle(.secondary)
            }
            Section("适用模式") {
                Toggle("使用记录模式", isOn: $profile.recordingOnly)
                Text("未成年人、孕哺期、饮食障碍或需要专业管理时，请使用记录模式。该模式保留记录，关闭减脂消耗估算。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("档案与目标")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } } }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            profile = model.editableProfile
            goal = model.goal
            if let date = profile.birthDate { birthday = TimeFormat.window(date, timezone: profile.timezone)?.start ?? Date(); useBirthday = true }
            endDate = TimeFormat.window(goal.endDate, timezone: profile.timezone)?.start ?? Date()
            weightUnit = model.weightUnit
            targetWeight = goal.targetWeightKg.map { weightUnit.fromKilograms($0) }
            if let cm = profile.heightCm {
                feet = floor(cm / 30.48)
                inches = (cm - (feet ?? 0) * 30.48) / 2.54
            }
        }
        .alert("请检查档案", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func save() async {
        guard !profile.routineMeals.isEmpty, goal.stepGoal > 0 else { message = "至少保留一个常规餐次，并填写有效步数目标"; return }
        if profile.heightUnit == "ft-in", let feet { profile.heightCm = feet * 30.48 + (inches ?? 0) * 2.54 }
        if let height = profile.heightCm, height <= 0 || height > 300 { message = "请核对身高和单位"; return }
        if let length = profile.stepLengthM, length <= 0 || length > 2 { message = "请填写有效单步长度"; return }
        profile.birthDate = useBirthday ? TimeFormat.day(birthday, timezone: profile.timezone) : nil
        goal.targetWeightKg = targetWeight.map { weightUnit.kilograms(from: $0) }
        goal.endDate = TimeFormat.day(endDate, timezone: profile.timezone)
        do {
            try await model.saveProfile(profile)
            try await model.saveGoal(goal)
            model.setWeightUnit(weightUnit)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
