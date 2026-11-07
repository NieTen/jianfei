import Charts
import SwiftUI

struct TrendSummaryChart: View {
    let title: String
    let unit: String
    let result: TrendResult
    let intake: Bool
    let loading: Bool
    @State private var showAverage = true

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
                        ForEach(linePoints) { point in
                            AreaMark(x: .value("日期", point.date), yStart: .value("基线", weightBounds.lowerBound), yEnd: .value("体重", point.value))
                                .foregroundStyle(LinearGradient(colors: [Palette.teal.opacity(0.18), Palette.teal.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                .foregroundStyle(Palette.teal).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        }
                        ForEach(result.points) { point in
                            PointMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                .foregroundStyle(Palette.teal).symbolSize(24)
                        }
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
                }
                Text(intake ? "仅展示有餐食记录的日期；未记录的餐次不代表未进食。" : (showAverage && !result.averages.isEmpty ? "圆点为每天最后一次测量，曲线为 7 日移动平均。" : "每天采用最后一次测量。7 天内至少有 3 个测量日才显示均线。"))
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }

    private var linePoints: [TrendPoint] {
        showAverage && !result.averages.isEmpty ? result.averages : result.points
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
