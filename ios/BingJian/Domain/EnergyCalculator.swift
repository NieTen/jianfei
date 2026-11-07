import Foundation

struct DailySummary: Sendable {
    var day: String
    var intake: Double?
    var expenditure: Double?
    var forecast: Double?
    var deficit: Double?
    var resting: Double?
    var active: Double?
    var weight: Double?
    var steps: Double?
    var method = "数据不足"
    var complete = false
    var completenessScore = 0
    var missingMeals: [String] = []
    var missingNutrients: [String] = []
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var isFinished = false
}

struct TrendPoint: Identifiable, Sendable {
    var id: String { day }
    var day: String
    var date: Date
    var value: Double
}

enum EnergyCalculator {
    static func latestProfile(_ records: [AppRecord], day: String) -> BodyProfile {
        records.filter { $0.kind == "profile" && $0.deletedAt == nil && $0.businessDate <= day }
            .sorted { ($0.businessDate, $0.updatedAt) > ($1.businessDate, $1.updatedAt) }
            .first?.decode(BodyProfile.self) ?? BodyProfile()
    }

    static func weight(_ records: [AppRecord], day: String, exactDay: Bool = false) -> Double? {
        let candidates = records.filter {
            $0.kind == "weight" && $0.deletedAt == nil && (exactDay ? $0.businessDate == day : $0.businessDate <= day)
        }.compactMap { record -> (String, String, WeightEntry)? in
            guard let weight = record.decode(WeightEntry.self), !weight.hidden, !weight.sourceDeleted else { return nil }
            return (record.businessDate, record.id, weight)
        }
        guard let newestDay = candidates.map(\.0).max() else { return nil }
        let value = candidates.filter { $0.0 == newestDay }.sorted {
            let lhs = $0.2
            let rhs = $1.2
            // 兼容旧记录中的代表标记，但始终以当天最后一次测量为准。
            let leftDate = TimeFormat.parse(lhs.measuredAt) ?? .distantPast
            let rightDate = TimeFormat.parse(rhs.measuredAt) ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if lhs.source != rhs.source { return lhs.source == "manual" }
            return $0.1 < $1.1
        }.first?.2
        return value?.correctedWeightKg ?? value?.weightKg
    }

    static func bmr(profile: BodyProfile, weight: Double?, day: String) -> Double? {
        guard !profile.recordingOnly, let weight, let height = profile.heightCm else { return nil }
        var age = profile.age
        if let birthday = profile.birthDate,
           let birth = TimeFormat.window(birthday, timezone: profile.timezone)?.start,
           let today = TimeFormat.window(day, timezone: profile.timezone)?.start {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: profile.timezone) ?? .current
            age = calendar.dateComponents([.year], from: birth, to: today).year
        }
        guard let age, age >= 18, ["male", "female"].contains(profile.sexForFormula) else { return nil }
        return 10 * weight + 6.25 * height - 5 * Double(age) + (profile.sexForFormula == "male" ? 5 : -161)
    }

    static func summary(records: [AppRecord], day: String, now: Date = Date()) -> DailySummary {
        let profile = latestProfile(records, day: day)
        let valid = records.filter { $0.deletedAt == nil && $0.businessDate == day }
        let weight = weight(records, day: day)
        let health = valid.filter { $0.kind == "health_day" }.sorted { $0.updatedAt > $1.updatedAt }.first?.decode(HealthDay.self)
        let status = valid.filter { $0.kind == "daily_status" }.sorted { $0.updatedAt > $1.updatedAt }.first?.decode(DailyStatus.self)
        var result = DailySummary(day: day)
        result.weight = weight
        result.steps = health?.steps
        guard let window = TimeFormat.window(day, timezone: profile.timezone, startMinutes: profile.dayStartMinutes) else { return result }
        let elapsed = max(0, min(now, window.end).timeIntervalSince(window.start))
        let basal = bmr(profile: profile, weight: weight, day: day)
        result.isFinished = now >= window.end
        if let resting = health?.restingKcal, let coverage = health?.restingCoverage, coverage >= 0.95 {
            result.resting = resting
            result.method = "健康数据"
        } else if let basal {
            result.resting = basal * elapsed / 86400
            result.method = "基础代谢估算 + 已记录活动"
        }
        result.active = health?.activeKcal
        if result.active == nil, let steps = health?.steps, let weight, let length = profile.stepLengthM {
            result.active = 0.5 * weight * steps * length / 1000
            result.method = "步行回退估算，可能遗漏其他活动"
        }
        if let resting = result.resting, let active = result.active { result.expenditure = resting + active }
        else if let basal {
            result.expenditure = basal * elapsed / 86400 * profile.activityFactor
            result.method = "按身体参数和活动水平估算至当前时间"
        }
        if let basal { result.forecast = basal * window.duration / 86400 * profile.activityFactor }
        let meals = valid.filter { $0.kind == "meal" }.compactMap { $0.decode(MealEntry.self) }
        var confirmed = Set<String>()
        var pending = false
        var knownEnergy = false
        var proteinTotal = 0.0
        var carbsTotal = 0.0
        var fatTotal = 0.0
        var missing = Set<String>()
        var intake: Decimal = 0
        for meal in meals {
            if meal.status == "draft" || (TimeFormat.parse(meal.eatenAt) ?? now) > now {
                pending = true
                continue
            }
            confirmed.insert(meal.mealType)
            knownEnergy = knownEnergy || meal.status == "skipped"
            for food in meal.items {
                if let value = food.kcal { intake += Decimal(value); knownEnergy = true } else { missing.insert("热量") }
                if let value = food.protein { proteinTotal += value } else { missing.insert("蛋白质") }
                if let value = food.carbs { carbsTotal += value } else { missing.insert("碳水") }
                if let value = food.fat { fatTotal += value } else { missing.insert("脂肪") }
            }
        }
        let routine = status?.routineMeals ?? profile.routineMeals
        result.missingMeals = routine.filter { !confirmed.contains($0) }
        result.missingNutrients = missing.sorted()
        // 未记录时显示已记录摄入为零；已确认但热量未知的食物仍保留未知状态。
        result.intake = knownEnergy || !missing.contains("热量") ? NSDecimalNumber(decimal: intake).doubleValue : nil
        result.protein = confirmed.isEmpty || missing.contains("蛋白质") ? nil : proteinTotal
        result.carbs = confirmed.isEmpty || missing.contains("碳水") ? nil : carbsTotal
        result.fat = confirmed.isEmpty || missing.contains("脂肪") ? nil : fatTotal
        result.complete = status?.intakeComplete == true && result.missingMeals.isEmpty && !pending && !missing.contains("热量")
        result.completenessScore = Int((Double(Set(routine).intersection(confirmed).count) / Double(max(1, routine.count)) * 100).rounded())
        if let expenditure = result.expenditure, let intake = result.intake, !missing.contains("热量") {
            result.deficit = expenditure - intake
        }
        return result
    }

    static func weightTrend(_ records: [AppRecord], days: Int, movingAverage: Bool = false) -> [TrendPoint] {
        let today = Date()
        let profile = latestProfile(records, day: TimeFormat.day())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: profile.timezone) ?? .current
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let day = TimeFormat.day(date, timezone: profile.timezone, startMinutes: profile.dayStartMinutes)
            if !movingAverage {
                guard let value = weight(records, day: day, exactDay: true) else { return nil }
                return TrendPoint(day: day, date: date, value: value)
            }
            let values = (0..<7).compactMap { prior -> Double? in
                guard let previous = calendar.date(byAdding: .day, value: -prior, to: date) else { return nil }
                return weight(records, day: TimeFormat.day(previous, timezone: profile.timezone, startMinutes: profile.dayStartMinutes), exactDay: true)
            }
            guard values.count >= 3 else { return nil }
            return TrendPoint(day: day, date: date, value: values.reduce(0, +) / Double(values.count))
        }
    }
}
