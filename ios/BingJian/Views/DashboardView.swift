import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showWeight = false
    @State private var showMeal = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeading(title: model.profile.displayName.isEmpty ? "今天，也照顾好自己" : "\(model.profile.displayName)，今天好",
                            subtitle: "饮食、身体与日常，一点点记录。", artwork: .sunrise)
                DateStrip()
                dailyOverview
                adaptiveRow {
                    Button { showMeal = true } label: {
                        ActionTile(title: "记一餐", subtitle: "拍照或手动添加", symbol: "camera", prominent: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("dashboard.meal")
                    Button { showWeight = true } label: {
                        ActionTile(title: "记体重", subtitle: "留下身体的变化", symbol: "scalemass")
                    }.buttonStyle(.plain).accessibilityIdentifier("dashboard.weight")
                }
                Surface {
                    Label("身体与活动", systemImage: "heart").font(.headline).foregroundStyle(Palette.ink)
                    adaptiveRow {
                        MetricView(title: "最近体重", value: displayedWeight(model.summary.weight), unit: model.weightUnit.name)
                        MetricView(title: "所选日期步数", value: model.summary.steps, unit: "步")
                    }
                    if let target = model.goal.targetWeightKg {
                        Text("个人目标 \(displayedWeight(target)?.concise ?? "") \(model.weightUnit.name)").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Divider().overlay(Palette.border)
                    NavigationLink { HealthDetailView() } label: {
                        HStack {
                            Text("查看运动与健康数据").font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "arrow.up.right").accessibilityHidden(true)
                        }.frame(minHeight: 44)
                    }
                }
                NavigationLink { CommunityView() } label: {
                    Surface {
                        HStack(spacing: 14) {
                            SymbolBadge(symbol: "person.2")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("和伙伴一起").font(.headline).foregroundStyle(Palette.ink)
                                Text(model.challenges.isEmpty ? "各自的目标，彼此的鼓励" : "\(model.challenges.count) 个挑战记录")
                                    .font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                        }
                    }
                }.buttonStyle(.plain)
                HStack {
                    Image(systemName: model.syncing ? "arrow.triangle.2.circlepath" : "externaldrive")
                    Text(model.syncStatus).lineLimit(2)
                    Spacer()
                    if model.pendingCount > 0 { Text("\(model.pendingCount) 待同步") }
                }.font(.caption).foregroundStyle(Palette.secondary)
                PrivacyNote()
            }.padding(.horizontal, 16).padding(.vertical, 18)
        }
        .background(Palette.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(Palette.teal)
                Text("并肩").foregroundStyle(Palette.ink)
            }.font(.title3.weight(.bold)).accessibilityElement(children: .combine)
        } }
        .refreshable {
            if model.healthEnabled { try? await model.refreshHealth() }
            await model.sync()
        }
        .sheet(isPresented: $showWeight) { NavigationStack { WeightEditorView() } }
        .sheet(isPresented: $showMeal) { NavigationStack { MealEditorView() } }
    }

    private var adaptiveRow: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
    }

    private var dailyOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("每日记录", systemImage: "leaf").font(.subheadline.weight(.medium)).foregroundStyle(Palette.mint)
                    Text(model.summary.complete ? "今天已记录完整" : "记录正在积累")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("每次记录，都让趋势更清晰。").font(.caption).foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { completionRing }
            }
            if typeSize.isAccessibilitySize {
                Text("记录完整度 \(model.summary.completenessScore)%").font(.headline)
            }
            adaptiveRow {
                heroMetric("已记录摄入", value: model.summary.intake)
                heroMetric("当前消耗估算", value: model.summary.expenditure)
            }
            Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                adaptiveRow {
                    Text(balanceLabel).font(.subheadline.weight(.semibold))
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Text(model.summary.deficit.map { "\(abs(displayedEnergy($0) ?? 0).concise) \(model.profile.energyUnit)" } ?? "等待记录")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                Text(model.summary.complete ? "饮食记录已确认。\(model.summary.method)" : "按已记录摄入暂估，未记录的餐次不代表未进食。\(model.summary.method)")
                    .font(.caption).foregroundStyle(Palette.mint).fixedSize(horizontal: false, vertical: true)
                if let forecast = model.summary.forecast {
                    Text("全天参考预测 \(displayedEnergy(forecast)?.concise ?? "") \(model.profile.energyUnit)")
                        .font(.caption).foregroundStyle(Palette.mint)
                }
            }
        }.padding(22).foregroundStyle(.white)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    Palette.heroGradient
                    HeroWave().fill(Color.green.opacity(0.22)).frame(width: 170, height: 42)
                    HeroWave().fill(Color.yellow.opacity(0.22)).frame(width: 105, height: 32)
                }.clipShape(RoundedRectangle(cornerRadius: 26))
            }
            .shadow(color: Palette.teal.opacity(0.15), radius: 12, y: 6)
    }

    private func heroMetric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(Palette.mint)
            Text(displayedEnergy(value)?.concise ?? "—")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value == nil ? "等待记录" : model.profile.energyUnit).font(.caption).foregroundStyle(Palette.mint)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var completionRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 6)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, model.summary.completenessScore))) / 100)
                .stroke(AngularGradient(colors: [.mint, .green, .yellow], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text("\(model.summary.completenessScore)%").font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("完成度").font(.caption2).foregroundStyle(Palette.mint)
            }
        }.frame(width: 80, height: 80)
            .accessibilityElement(children: .ignore).accessibilityLabel("记录完整度 \(model.summary.completenessScore)%")
    }

    private var balanceLabel: String {
        guard let value = model.summary.deficit else { return "能量差额" }
        if abs(value) <= 50 { return "摄入与消耗接近" }
        return value > 0 ? "暂估能量缺口" : "暂估能量盈余"
    }

    private func displayedEnergy(_ value: Double?) -> Double? { value.map { model.profile.energyUnit == "kJ" ? $0 * 4.184 : $0 } }
    private func displayedWeight(_ value: Double?) -> Double? { value.map { model.weightUnit.fromKilograms($0) } }
}
