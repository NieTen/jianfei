import Charts
import SwiftUI

struct TrendSummaryChart: View {
    let title: String
    let unit: String
    let result: TrendResult
    let intake: Bool
    let loading: Bool
    @State private var showAverage = true

    init(title: String, unit: String, result: TrendResult, intake: Bool, loading: Bool, showAverage: Bool = true) {
        self.title = title
        self.unit = unit
        self.result = result
        self.intake = intake
        self.loading = loading
        _showAverage = State(initialValue: showAverage)
    }

    var body: some View {
        Surface {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline).foregroundStyle(Palette.ink)
                    if let last = result.points.last, !loading {
                        Text("\(last.value.concise) \(unit)").font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(Palette.teal)
                    }
                }
                Spacer()
                SymbolBadge(symbol: intake ? "flame" : "chart.xyaxis.line")
            }
            if loading {
                ProgressView("正在绘制…").frame(maxWidth: .infinity, minHeight: 200)
            } else if result.points.isEmpty {
                EmptyRecordsView(title: intake ? "还没有摄入记录" : "还没有体重记录",
                                 message: intake ? "保存一餐后，这里显示每天已记录的热量。" : "记录体重后，这里显示每天最后一次测量。", symbol: intake ? "fork.knife" : "scalemass")
            } else {
                Chart {
                    if intake {
                        ForEach(result.points) { point in
                            BarMark(x: .value("日期", point.date, unit: .day), y: .value("已记录摄入", point.value))
                                .foregroundStyle(Palette.teal.gradient).cornerRadius(5)
                        }
                    } else {
                        WeightTrendMarks(result: result, showAverage: showAverage, baseline: weightBounds.lowerBound)
                    }
                }
                .chartLegend(.hidden)
                .chartYScale(domain: intake ? 0...max(1, (result.points.map(\.value).max() ?? 1) * 1.12) : weightBounds)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.month().day()) }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
                        AxisValueLabel()
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("\(title)，\(result.points.count) 个有效日期，单位\(unit)")
                HStack {
                    Text("有效记录 \(result.points.count) 天")
                    Spacer()
                    if let last = result.points.last { Text("最近 \(last.value.concise) \(unit)") }
                }.font(.caption).foregroundStyle(Palette.ink)
                if !intake {
                    Divider().overlay(Palette.border)
                    Toggle("7 日移动平均", isOn: $showAverage).font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("trend.weight.average")
                }
                Text(intake ? "仅展示有餐食记录的日期；未记录的餐次不代表未进食。" : weightExplanation)
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }

    private var weightExplanation: String {
        let measured = "圆点与虚线表示每天最后一次测量，缺测日不补值。"
        guard showAverage else { return measured }
        return measured + (result.averages.isEmpty ? "7 天内至少有 3 个测量日才显示均线。" : "实线表示 7 日移动平均，只有一个均值时显示菱形点。")
    }

    private var weightBounds: ClosedRange<Double> {
        let values = (result.points + result.averages).map(\.value)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let padding = max(0.2, (maximum - minimum) * 0.15)
        // 面积从可见坐标轴下沿开始，不把体重曲线强制拉到零。
        return max(0, minimum - padding)...(maximum + padding)
    }
}

// 概览与详细体重图共用标记，避免打开均线后丢失前几个测量日的连线。
struct WeightTrendMarks: ChartContent {
    let result: TrendResult
    let showAverage: Bool
    var baseline: Double? = nil

    var body: some ChartContent {
        if let baseline {
            ForEach(result.points) { point in
                AreaMark(x: .value("日期", point.date), yStart: .value("基线", baseline), yEnd: .value("体重", point.value))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [Palette.teal.opacity(0.12), Palette.teal.opacity(0.01)], startPoint: .top, endPoint: .bottom))
            }
        }
        ForEach(result.points) { point in
            // 虚线只连接已有测量点，不生成缺测日数据；均线使用独立序列。
            LineMark(x: .value("日期", point.date), y: .value("体重", point.value), series: .value("序列", "实际测量"))
                .interpolationMethod(.linear)
                .foregroundStyle(Palette.teal.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
        }
        if showAverage {
            ForEach(result.averages) { point in
                LineMark(x: .value("日期", point.date), y: .value("体重", point.value), series: .value("序列", "7 日移动平均"))
                    .interpolationMethod(.linear)
                    .foregroundStyle(Palette.teal).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if result.averages.count == 1 {
                    PointMark(x: .value("日期", point.date), y: .value("7 日移动平均", point.value))
                        .foregroundStyle(Palette.teal).symbol(.diamond).symbolSize(36)
                }
            }
        }
        ForEach(result.points) { point in
            PointMark(x: .value("日期", point.date), y: .value("体重", point.value))
                .foregroundStyle(Palette.teal).symbolSize(24)
        }
    }
}
