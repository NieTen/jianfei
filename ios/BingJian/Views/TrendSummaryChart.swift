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
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let last = result.points.last {
                    Text("\(last.value.concise) \(unit)").font(.headline).foregroundStyle(Palette.teal)
                }
            }
            if loading {
                ProgressView("正在绘制…").frame(maxWidth: .infinity, minHeight: 200)
            } else if result.points.isEmpty {
                EmptyRecordsView(title: intake ? "还没有摄入记录" : "还没有体重记录",
                                 message: intake ? "保存一餐后，这里显示每天已记录的热量。" : "记录体重后，这里显示每天最后一次测量。", symbol: intake ? "fork.knife" : "scalemass")
            } else {
                Chart {
                    ForEach(result.points) { point in
                        if intake {
                            BarMark(x: .value("日期", point.date, unit: .day), y: .value("已记录摄入", point.value))
                                .foregroundStyle(Palette.teal).cornerRadius(4)
                        } else {
                            LineMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                .foregroundStyle(by: .value("系列", "每日体重"))
                            PointMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                .foregroundStyle(Palette.teal).symbolSize(24)
                        }
                    }
                    if !intake && showAverage {
                        ForEach(result.averages) { point in
                            LineMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                .foregroundStyle(by: .value("系列", "7 日均线"))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        }
                    }
                }
                .chartForegroundStyleScale(["每日体重": Palette.teal, "7 日均线": Palette.sage])
                .chartLegend(intake ? .hidden : .automatic)
                .chartYScale(domain: .automatic(includesZero: intake))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.month().day()) }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .frame(height: 210)
                .accessibilityLabel("\(title)，\(result.points.count) 个有效日期，单位\(unit)")
                if !intake { Toggle("显示 7 日均线", isOn: $showAverage).font(.subheadline) }
                Text(intake ? "仅展示有餐食记录的日期；未记录的餐次不代表未进食。" : "每天采用最后一次测量。7 天内至少有 3 个测量日才显示均线。")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }
}
