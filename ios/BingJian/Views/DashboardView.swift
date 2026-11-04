import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showWeight = false
    @State private var showMeal = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                DateStrip()
                Surface {
                    HStack {
                        Label("今天的记录", systemImage: "pencil.and.list.clipboard").font(.headline)
                        Spacer()
                        Text("\(model.summary.completenessScore)%").font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.teal)
                    }
                    ProgressView(value: Double(model.summary.completenessScore), total: 100).tint(Palette.sage)
                    HStack(alignment: .top) {
                        MetricView(title: "已记录摄入", value: displayedEnergy(model.summary.intake), unit: model.profile.energyUnit)
                        MetricView(title: "当前消耗估算", value: displayedEnergy(model.summary.expenditure), unit: model.profile.energyUnit)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(balanceLabel).font(.subheadline.weight(.medium))
                            Text(model.summary.deficit.map { "\(abs(displayedEnergy($0) ?? 0).concise) \(model.profile.energyUnit)" } ?? "数据不足")
                                .font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        Spacer()
                        Image(systemName: model.summary.complete ? "checkmark.seal" : "circle.dotted")
                            .font(.largeTitle).foregroundStyle(Palette.sage)
                    }
                    HintLabel(text: model.summary.complete ? "饮食记录已确认。\(model.summary.method)" : "暂估结果。\(model.summary.missingMeals.map(MealTypes.name).joined(separator: "、"))尚待完善")
                    if let forecast = model.summary.forecast {
                        Text("全天参考预测 \(displayedEnergy(forecast)?.concise ?? "") \(model.profile.energyUnit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { showMeal = true } label: {
                        Label("记一餐", systemImage: "camera").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent)
                    Button { showWeight = true } label: {
                        Label("记体重", systemImage: "scalemass").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.bordered)
                }
                Surface {
                    HStack {
                        MetricView(title: "最近体重", value: displayedWeight(model.summary.weight), unit: model.profile.weightUnit)
                        MetricView(title: "今日步数", value: model.summary.steps, unit: "步")
                    }
                    if let target = model.goal.targetWeightKg {
                        Text("个人目标 \(displayedWeight(target)?.concise ?? "") \(model.profile.weightUnit)").font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink { HealthDetailView() } label: { Label("运动与健康数据", systemImage: "heart.text.square") }
                }
                Surface {
                    HStack {
                        Image(systemName: "person.2.fill").foregroundStyle(Palette.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("并肩记录").font(.headline)
                            Text(model.challenges.isEmpty ? "邀请伙伴，按各自的目标一起记录" : "\(model.challenges.count) 个挑战记录").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        NavigationLink { CommunityView() } label: { Image(systemName: "arrow.up.right") }
                    }
                }
                HStack {
                    Image(systemName: model.syncing ? "arrow.triangle.2.circlepath" : "externaldrive")
                    Text(model.syncStatus).lineLimit(2)
                    Spacer()
                    if model.pendingCount > 0 { Text("\(model.pendingCount) 待同步") }
                }.font(.caption).foregroundStyle(.secondary)
                PrivacyNote()
            }.padding(20)
        }
        .background(Palette.canvas)
        .navigationTitle(model.profile.displayName.isEmpty ? "并肩" : "\(model.profile.displayName)的记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if model.healthEnabled { try? await model.refreshHealth() }
            await model.sync()
        }
        .sheet(isPresented: $showWeight) { NavigationStack { WeightEditorView() } }
        .sheet(isPresented: $showMeal) { NavigationStack { MealEditorView() } }
    }

    private var balanceLabel: String {
        guard let value = model.summary.deficit else { return "能量差额" }
        if abs(value) <= 50 { return "摄入与消耗接近" }
        return value > 0 ? "暂估能量缺口" : "暂估能量盈余"
    }

    private func displayedEnergy(_ value: Double?) -> Double? { value.map { model.profile.energyUnit == "kJ" ? $0 * 4.184 : $0 } }
    private func displayedWeight(_ value: Double?) -> Double? { value.map { model.profile.weightUnit == "lb" ? $0 / 0.45359237 : $0 } }
}
