import Charts
import SwiftUI

struct HealthDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var healthManager: HealthManager
    private var health: HealthDay? {
        (model.recordIndex.byDay[model.day] ?? []).filter { $0.kind == "health_day" }
            .max { $0.updatedAt < $1.updatedAt }?.decode(HealthDay.self)
    }
    private var workouts: [WorkoutEntry] {
        (model.recordIndex.byDay[model.day] ?? []).filter { $0.kind == "workout" }
            .compactMap { $0.decode(WorkoutEntry.self) }.filter { !$0.sourceDeleted }
    }
    private var recentSleep: [Double] {
        let end = model.displayDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: model.profile.timezone) ?? .current
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let day = TimeFormat.day(date, timezone: model.profile.timezone)
            return (model.recordIndex.byDay[day] ?? []).filter { $0.kind == "health_day" }
                .max { $0.updatedAt < $1.updatedAt }?.decode(HealthDay.self)?.sleepHours
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                DateStrip()
                Surface {
                    Text("活动与消耗").font(.headline)
                    HStack {
                        MetricView(title: "步数", value: health?.steps, unit: "步")
                        MetricView(title: "活动能量", value: health?.activeKcal, unit: "kcal")
                    }
                    HStack {
                        MetricView(title: "静息能量", value: health?.restingKcal, unit: "kcal")
                        MetricView(title: "距离", value: health?.distanceKm, unit: "km")
                    }
                    HintLabel(text: "运动记录用于查看类型和时长，能量已包含在活动能量中时不重复叠加。")
                }
                Surface {
                    Text("心率与睡眠").font(.headline)
                    HStack {
                        MetricView(title: "平均心率", value: health?.heartRate, unit: "次/分")
                        MetricView(title: "静息心率", value: health?.restingHeartRate, unit: "次/分")
                    }
                    HStack {
                        MetricView(title: "睡眠记录", value: health?.sleepHours, unit: "小时")
                        MetricView(title: "近 7 日有效记录均值", value: recentSleep.isEmpty ? nil : recentSleep.reduce(0, +) / Double(recentSleep.count), unit: "小时")
                    }
                    Text("近 7 日有 \(recentSleep.count) 个有效睡眠记录日。重叠睡眠区间按并集合计，缺失日期不补零。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Surface {
                    Text("运动记录").font(.headline)
                    if workouts.isEmpty { Text("暂无可读取运动记录").foregroundStyle(.secondary) }
                    ForEach(workouts, id: \.sourceId) { workout in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.activityType)
                                Text(workout.sourceName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(workout.durationMinutes.concise) 分钟")
                                if let energy = workout.energyKcal { Text("\(energy.concise) kcal").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Surface {
                    Text(healthManager.status).font(.subheadline)
                    if healthManager.refreshing { ProgressView(value: healthManager.progress) }
                    if let updated = health?.updatedAt, let date = TimeFormat.parse(updated) {
                        Text("最近读取 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("刷新健康数据") { model.perform { try await model.refreshHealth() } }.disabled(healthManager.refreshing || healthManager.accessIssue != nil)
                    NavigationLink("权限与历史回填") { HealthSettingsView() }
                }
                PrivacyNote()
            }.padding(20)
        }.background(Palette.canvas).navigationTitle("健康数据")
    }
}

struct HealthSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var health: HealthManager
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -12, to: Date()) ?? Date()
    var body: some View {
        Form {
            if let issue = health.accessIssue {
                Section("健康数据暂不可用") {
                    Label("需要重新签名安装", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(issue).font(.subheadline)
                }
            }
            Section("健康数据读取") {
                Toggle("前台自动刷新", isOn: $model.healthEnabled)
                    .disabled(health.accessIssue != nil)
                    .onChange(of: model.healthEnabled) { _, value in UserDefaults.standard.set(value, forKey: "health_enabled") }
                Button(health.accessIssue == nil ? "请求或补充健康读取权限" : "重新检查健康读取权限") { model.perform { try await model.authorizeHealth() } }
                Text("系统可能无法区分未授权和没有数据。拒绝读取时仍可手动记录。权限请在 iPhone 的健康或系统设置中调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("历史补取") {
                DatePicker("开始日期", selection: $startDate, in: ...Date(), displayedComponents: .date)
                Button("补齐所选范围的健康数据") {
                    model.perform {
                        try await model.requireStore().setMetadata("health_disabled_after_delete", value: nil)
                        try await model.refreshHealth(from: startDate)
                    }
                }.disabled(health.refreshing || health.accessIssue != nil)
                if health.refreshing { ProgressView(value: health.progress) }
                Text(health.status).font(.caption).foregroundStyle(.secondary)
                Text("仅能读取健康 App 中实际存在且当前可访问的数据。大范围补取会分批保存，重启后可继续。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("健康权限与历史")
    }
}
