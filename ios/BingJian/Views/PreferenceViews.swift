import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var weightMultiplier: Double = 1
    @State private var calorieMultiplier: Double = 1
    var body: some View {
        AppForm {
            FormIntro(title: "更了解你的每一餐", subtitle: "选择识别方式，也可以保存自己的份量与热量偏好。", symbol: "sparkles", color: Palette.purple)
            Section("识别方式") {
                NavigationLink("设置 AI 接口、密钥与模型") { AIConnectionEditorView() }
                Picker("默认模式", selection: $model.aiMode) {
                    Text("本机 Vision 分类").tag("device")
                    Text("Responses API 服务").tag("server")
                }
                let ai = model.capabilities["ai"]?.object ?? [:]
                LabeledContent("服务地址", value: model.aiConfiguration.configured ? model.aiConfiguration.baseUrl : ai.text("host", fallback: "尚未配置"))
                LabeledContent("模型", value: model.aiConfiguration.model.isEmpty ? ai.text("model", fallback: "未指定") : model.aiConfiguration.model)
                Text(model.aiConfiguration.external ? "该服务会将照片发送到外部处理方" : "使用配置的内网 AI 服务")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("允许已披露的外部 AI 处理照片", isOn: $model.externalAIConsent)
                Text("提供方变更后应重新核对授权。照片上传默认去除 EXIF 定位及无关元数据。").font(.caption).foregroundStyle(.secondary)
            }
            Section("个人估算偏好") {
                FormField(title: "食物名称") { TextField("匹配同名候选", text: $name) }
                VStack(alignment: .leading) {
                    Text("份量倍率 \(weightMultiplier.concise)")
                    Slider(value: $weightMultiplier, in: 0.25...3, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("热量倍率 \(calorieMultiplier.concise)")
                    Slider(value: $calorieMultiplier, in: 0.25...3, step: 0.05)
                }
                Button("保存个人偏好") {
                    model.perform {
                        try await model.saveFoodPreference(FoodPreference(foodName: name.trimmingCharacters(in: .whitespaces),
                            weightMultiplier: weightMultiplier, calorieMultiplier: calorieMultiplier))
                        name = ""
                    }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("偏好用于以后同名食物的候选估算，最终仍由你确认。").font(.caption).foregroundStyle(.secondary)
            }
            Section("已保存偏好") {
                ForEach(model.records.filter { $0.kind == "food_preference" && $0.deletedAt == nil }) { record in
                    HStack {
                        Text(record.payload.text("food_name"))
                        Spacer()
                        Text("份量 ×\(record.payload.number("weight_multiplier")?.concise ?? "1")")
                            .font(.caption).foregroundStyle(.secondary)
                    }.swipeActions { Button("删除", role: .destructive) { model.perform { try await model.deleteRecord(record) } } }
                }
            }
        }.navigationTitle("AI 与估算偏好")
    }
}

struct ReminderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reminders: ReminderManager
    @State private var remote = false
    var body: some View {
        AppForm {
            FormIntro(title: "给日常一点小提醒", subtitle: "按自己的作息设置，慢慢养成记录习惯。", symbol: "bell.badge", color: Palette.peach)
            Section("本机提醒") {
                Toggle("启用每日提醒", isOn: $reminders.enabled)
                hourPicker("称重提醒", selection: $reminders.weightHour)
                hourPicker("饮食记录提醒", selection: $reminders.mealHour)
                hourPicker("挑战打卡提醒", selection: $reminders.challengeHour)
                Button("保存提醒") { model.perform { try await reminders.save(); model.notice = "提醒设置已保存" } }
            }
            Section("伙伴远程提醒") {
                Toggle("接收新鼓励提醒", isOn: $remote)
                Button("应用远程提醒设置") {
                    model.perform {
                        if remote { try await reminders.enableRemote() }
                        else { _ = try await model.api.send("devices/push", method: "POST", body: ["token": .string(""), "enabled": .bool(false)]) }
                        UserDefaults.standard.set(remote, forKey: "remote_push_enabled")
                    }
                }.disabled(model.session == nil)
                Text(model.capabilities.flag("push_available") ? "后台已配置 Apple 推送服务" : "后台尚未配置 APNs，伙伴消息仍可在同步后查看")
                    .font(.caption).foregroundStyle(.secondary)
                Text("通知默认只提示新动态，不包含体重、食物或健康明细。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("提醒与通知")
            .task { remote = UserDefaults.standard.bool(forKey: "remote_push_enabled") }
    }

    private func hourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
    }
}

struct FavoritesManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: FoodItem?
    @State private var recordId: String?
    var body: some View {
        AppList {
            FormIntro(title: "常吃的，下次更好记", subtitle: "收藏常用食物，记录时可以直接选用。", symbol: "bookmark", color: Palette.peach)
            ForEach(model.records.filter { $0.kind == "favorite" && $0.deletedAt == nil }) { record in
                if let favorite = record.decode(FavoriteFood.self) {
                    Button {
                        recordId = record.id
                        editing = favorite.food
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(favorite.name)
                            Text(favorite.food.kcal.map { "\($0.concise) kcal" } ?? "营养待补充").font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("删除", role: .destructive) { model.perform { try await model.deleteRecord(record) } } }
                }
            }
        }.navigationTitle("常用食物")
            .toolbar { Button("添加", systemImage: "plus") { recordId = nil; editing = FoodItem(name: "") } }
            .sheet(item: $editing) { food in
                NavigationStack {
                    FoodEditorView(food: food) { value in
                        model.perform {
                            let record = try AppRecord(kind: "favorite", day: model.day,
                                value: FavoriteFood(name: value.name, food: value), id: recordId ?? UUID().uuidString.lowercased())
                            try await model.saveRecord(record)
                        }
                    }
                }
            }
    }
}
