import Charts
import SwiftUI

struct TrendsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var days = 30
    @State private var metric = "weight"
    @State private var average = true
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showMeasurement = false
    @State private var editingMeasurement: AppRecord?
    @State private var trend = TrendResult(points: [], averages: [])
    @State private var loading = false

    private let metrics = [
        ("weight", "体重"), ("intake", "摄入"), ("expenditure", "消耗"), ("deficit", "能量差额"),
        ("steps", "步数"), ("waist", "腰围"), ("body_fat", "体脂率"), ("sleep", "睡眠"),
        ("heart", "心率"), ("workout", "运动分钟"), ("completeness", "记录完整度")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                PageHeading(title: "看见一点点变化", subtitle: "拉长时间，观察属于自己的节奏。")
                Picker("趋势指标", selection: $metric) {
                    ForEach(metrics, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.menu).font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 10).background(Palette.soft, in: RoundedRectangle(cornerRadius: 15))
                Picker("时间范围", selection: $days) {
                    Text("7天").tag(7); Text("30天").tag(30); Text("90天").tag(90); Text("1年").tag(365); Text("自定义").tag(0)
                }.pickerStyle(.segmented)
                if days == 0 {
                    DatePicker("开始", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                    DatePicker("结束", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                }
                Surface {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(metrics.first { $0.0 == metric }?.1 ?? "趋势").font(.headline).foregroundStyle(Palette.ink)
                            if let last = points.last, !loading {
                                Text("\(last.value.concise) \(unit)")
                                    .font(.system(.title, design: .rounded, weight: .semibold)).foregroundStyle(Palette.teal)
                            }
                        }
                        Spacer()
                        SymbolBadge(symbol: "chart.xyaxis.line")
                    }
                    if loading {
                        ProgressView("正在计算趋势").frame(maxWidth: .infinity, minHeight: 260)
                    } else if points.isEmpty {
                        EmptyRecordsView(title: "还没有可绘制的数据", message: "选择其他时间范围，或完成相应记录后再看趋势。", symbol: "chart.xyaxis.line")
                    } else {
                        Chart {
                            ForEach(points) { point in
                                PointMark(x: .value("日期", point.date), y: .value("记录值", point.value))
                                    .foregroundStyle(Palette.teal).symbolSize(30)
                            }
                            if metric == "weight" && average {
                                ForEach(trend.averages) { point in
                                    LineMark(x: .value("日期", point.date), y: .value("7日移动平均", point.value))
                                        .foregroundStyle(Palette.sage).lineStyle(StrokeStyle(lineWidth: 2.5))
                                }
                            }
                        }
                        .chartYScale(domain: .automatic(includesZero: metric != "weight"))
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) {
                                AxisValueLabel(format: .dateTime.month().day())
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                                AxisValueLabel()
                            }
                        }
                        .frame(height: 260)
                        .accessibilityLabel("\(points.count) 个有效日期的\(metrics.first { $0.0 == metric }?.1 ?? "")记录")
                        HStack {
                            Text("有效记录 \(points.count) 天")
                            Spacer()
                            if let last = points.last { Text("最近 \(last.value.concise) \(unit)") }
                        }.font(.caption).foregroundStyle(Palette.secondary)
                    }
                    if metric == "weight" {
                        Divider()
                        Toggle("7 日移动平均", isOn: $average).font(.subheadline)
                        HintLabel(text: "窗口至少包含 3 个有效测量日才显示均线，缺测日保持空缺。")
                    }
                }
                Surface {
                    NavigationLink { WeightHistoryView() } label: { SettingsRow(title: "体重记录", symbol: "scalemass") }
                    Divider()
                    Button { showMeasurement = true } label: { SettingsRow(title: "记录围度与体脂", symbol: "figure.stand") }
                }.buttonStyle(.plain)
                if !measurements.isEmpty {
                    Surface {
                        Text("身体组成记录").font(.headline)
                        ForEach(measurements.prefix(15)) { record in
                            if let value = record.decode(MeasurementEntry.self) {
                                Button { editingMeasurement = record } label: {
                                    HStack {
                                        Text(record.businessDate).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(value.waistCm.map { "腰围 \($0.concise) cm" } ?? value.bodyFatPercent.map { "体脂 \($0.concise)%" } ?? "身体组成")
                                    }
                                }
                            }
                        }
                    }
                }
                PrivacyNote()
            }.padding(20)
        }
        .background(Palette.canvas).navigationTitle("趋势").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMeasurement) { NavigationStack { MeasurementEditorView() } }
        .sheet(item: $editingMeasurement) { value in NavigationStack { MeasurementEditorView(existing: value) } }
        .task(id: calculationKey) { await refreshTrend() }
    }

    private var measurements: [AppRecord] { model.recordIndex.byKind["measurement"] ?? [] }
    private var points: [TrendPoint] { trend.points }
    private var calculationKey: String {
        "\(model.dataRevision)|\(metric)|\(days)|\(customStart.timeIntervalSince1970)|\(customEnd.timeIntervalSince1970)|\(model.day)"
    }
    private var visibleDays: Int { days == 0 ? min(3650, max(1, Calendar.current.dateComponents([.day], from: customStart, to: customEnd).day ?? 0) + 1) : days }
    private var unit: String {
        switch metric {
        case "weight": return model.profile.weightUnit
        case "intake", "expenditure", "deficit": return model.profile.energyUnit
        case "steps": return "步"
        case "waist": return "cm"
        case "body_fat", "completeness": return "%"
        case "sleep": return "小时"
        case "heart": return "次/分钟"
        default: return "分钟"
        }
    }

    @MainActor
    private func refreshTrend() async {
        loading = true
        let index = model.recordIndex
        let profile = model.profile
        let selectedMetric = metric
        let count = visibleDays
        let end = days == 0 ? customEnd : model.displayDate
        let computation = Task.detached(priority: .userInitiated) {
            TrendCalculator.calculate(index: index, profile: profile, metric: selectedMetric, days: count, end: end)
        }
        let value = await withTaskCancellationHandler {
            await computation.value
        } onCancel: {
            computation.cancel()
        }
        guard !Task.isCancelled else { return }
        trend = value
        loading = false
    }
}

struct WeightHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: AppRecord?
    @State private var showHidden = false
    var body: some View {
        List {
            Toggle("显示本地隐藏记录", isOn: $showHidden)
            ForEach(model.recordIndex.byKind["weight"] ?? []) { record in
                if let weight = record.decode(WeightEntry.self), showHidden || (!weight.hidden && !weight.sourceDeleted) {
                    Button { editing = record } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\((weight.correctedWeightKg ?? weight.weightKg).concise) kg").font(.headline)
                                Spacer()
                                Text(record.businessDate).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(weight.sourceName ?? (weight.source == "manual" ? "手动记录" : "健康数据"))
                                .font(.caption).foregroundStyle(.secondary)
                            if weight.hidden || weight.sourceDeleted { Text(weight.sourceDeleted ? "来源已删除" : "本地已隐藏").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .swipeActions {
                        if weight.hidden {
                            Button("恢复") {
                                model.perform {
                                    var value = record
                                    value.payload["hidden"] = .bool(false)
                                    try await model.saveRecord(value)
                                }
                            }
                        } else {
                            Button("删除", role: .destructive) { model.perform { try await model.deleteRecord(record) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("体重记录")
        .sheet(item: $editing) { record in NavigationStack { WeightEditorView(existing: record) } }
    }
}
