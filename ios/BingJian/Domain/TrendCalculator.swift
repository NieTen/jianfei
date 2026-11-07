import Foundation

struct TrendResult: Sendable {
    var points: [TrendPoint]
    var averages: [TrendPoint]
}

enum TrendCalculator {
    static func calculate(index: RecordIndex, profile: BodyProfile, weightUnit: WeightUnit, metric: String, days: Int, end: Date) -> TrendResult {
        var result = TrendResult(points: [], averages: [])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: profile.timezone) ?? .current
        for offset in (0..<days).reversed() {
            if Task.isCancelled { break }
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            let day = TimeFormat.day(date, timezone: profile.timezone)
            let records = index.byDay[day] ?? []
            let health = records.filter { $0.kind == "health_day" }.sorted { $0.updatedAt > $1.updatedAt }.first?.decode(HealthDay.self)
            let measurement = records.filter { $0.kind == "measurement" }.sorted { $0.updatedAt > $1.updatedAt }.first?.decode(MeasurementEntry.self)
            var value: Double?
            switch metric {
            case "weight":
                value = index.representativeWeight(day: day).map { weightUnit.fromKilograms($0) }
                let window = (0..<7).compactMap { prior -> Double? in
                    guard let previous = calendar.date(byAdding: .day, value: -prior, to: date) else { return nil }
                    return index.representativeWeight(day: TimeFormat.day(previous, timezone: profile.timezone))
                }
                if window.count >= 3 {
                    let average = weightUnit.fromKilograms(window.reduce(0, +) / Double(window.count))
                    result.averages.append(TrendPoint(day: day, date: date, value: average))
                }
            case "waist": value = measurement?.waistCm
            case "body_fat": value = measurement?.bodyFatPercent ?? health?.bodyFatPercent
            case "steps": value = health?.steps
            case "sleep": value = health?.sleepHours
            case "heart": value = health?.heartRate
            case "workout": value = health?.workoutMinutes
            default:
                let summary = EnergyCalculator.summary(records: index.forSummary(day: day), day: day)
                switch metric {
                case "intake":
                    // 图表不把没有餐食记录的日期画成零摄入。
                    value = records.contains { $0.kind == "meal" && $0.payload.text("status") != "draft" } ? summary.intake : nil
                case "expenditure": value = summary.expenditure
                case "deficit": value = summary.deficit
                default: value = records.contains { $0.kind == "meal" || $0.kind == "daily_status" } ? Double(summary.completenessScore) : nil
                }
                if ["intake", "expenditure", "deficit"].contains(metric), profile.energyUnit == "kJ" { value = value.map { $0 * 4.184 } }
            }
            if let value { result.points.append(TrendPoint(day: day, date: date, value: value)) }
        }
        return result
    }
}
