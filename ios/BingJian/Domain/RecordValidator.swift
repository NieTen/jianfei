import Foundation

enum RecordValidator {
    static func validate(_ record: AppRecord) throws {
        guard UUID(uuidString: record.id) != nil, record.version >= 0,
              record.businessDate.count == 10, TimeFormat.window(record.businessDate, timezone: "UTC") != nil else {
            throw invalid("记录标识或日期无效")
        }
        try finiteValues(.object(record.payload))
        switch record.kind {
        case "profile":
            let value = try Codec.decode(BodyProfile.self, from: record.payload)
            guard TimeZone(identifier: value.timezone) != nil, (0..<1440).contains(value.dayStartMinutes),
                  !value.routineMeals.isEmpty, value.routineMeals.count <= 8 else { throw invalid("档案时区或常规餐次无效") }
            try range(value.heightCm, lower: 0, upper: 300, exclusive: true)
            try range(value.age.map(Double.init), lower: 1, upper: 120)
            try range(value.activityFactor, lower: 1, upper: 2.5)
            try range(value.stepLengthM, lower: 0, upper: 2, exclusive: true)
        case "weight":
            let value = try Codec.decode(WeightEntry.self, from: record.payload)
            try timestamp(value.measuredAt)
            try range(value.weightKg, lower: 0, upper: 600, exclusive: true)
            try range(value.correctedWeightKg, lower: 0, upper: 600, exclusive: true)
        case "meal":
            let value = try Codec.decode(MealEntry.self, from: record.payload)
            try timestamp(value.eatenAt)
            guard TimeZone(identifier: value.timezone) != nil, value.photoIds.count <= 6,
                  value.photoIds.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(value.photoIds).count == value.photoIds.count,
                  ["draft", "confirmed", "skipped"].contains(value.status), value.items.count <= 100 else {
                throw invalid("餐次状态、照片或食物数量无效")
            }
            if value.status == "confirmed" && (value.items.isEmpty || value.items.contains { $0.requiresPortion == true }) {
                throw invalid("请添加食物并确认候选食物的实际份量")
            }
            if value.status == "skipped" && !value.items.isEmpty { throw invalid("未进食餐次不能同时包含食物") }
            for item in value.items { try food(item) }
        case "goal":
            let value = try Codec.decode(GoalEntry.self, from: record.payload)
            guard TimeFormat.window(value.startDate, timezone: "UTC") != nil,
                  TimeFormat.window(value.endDate, timezone: "UTC") != nil, value.endDate >= value.startDate else {
                throw invalid("目标日期范围无效")
            }
            try range(value.targetWeightKg, lower: 0, upper: 600, exclusive: true)
            try range(Double(value.stepGoal), lower: 1, upper: 200000)
        case "measurement":
            let value = try Codec.decode(MeasurementEntry.self, from: record.payload)
            try timestamp(value.measuredAt)
            try range(value.waistCm, lower: 0, upper: 400, exclusive: true)
            try range(value.hipCm, lower: 0, upper: 400, exclusive: true)
            try range(value.bodyFatPercent, lower: 0, upper: 100)
            try range(value.muscleKg, lower: 0, upper: 300, exclusive: true)
        case "food_preference":
            let value = try Codec.decode(FoodPreference.self, from: record.payload)
            try range(value.weightMultiplier, lower: 0, upper: 5, exclusive: true)
            try range(value.calorieMultiplier, lower: 0, upper: 5, exclusive: true)
        case "favorite":
            let value = try Codec.decode(FavoriteFood.self, from: record.payload)
            try food(value.food)
        case "daily_status":
            _ = try Codec.decode(DailyStatus.self, from: record.payload)
        case "health_day":
            let value = try Codec.decode(HealthDay.self, from: record.payload)
            try timestamp(value.windowStart)
            try timestamp(value.windowEnd)
            for number in [value.steps, value.activeKcal, value.restingKcal, value.workoutMinutes, value.distanceKm] {
                try range(number, lower: 0, upper: Double.greatestFiniteMagnitude)
            }
            try range(value.restingCoverage, lower: 0, upper: 1)
            try range(value.bodyFatPercent, lower: 0, upper: 100)
            try range(value.sleepHours, lower: 0, upper: 30)
        case "workout":
            let value = try Codec.decode(WorkoutEntry.self, from: record.payload)
            try timestamp(value.startAt)
            try timestamp(value.endAt)
            try range(value.durationMinutes, lower: 0, upper: Double.greatestFiniteMagnitude)
        default:
            throw invalid("不支持的记录类型")
        }
    }

    static func food(_ item: FoodItem) throws {
        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.count <= 200,
              ["g", "ml", "serving"].contains(item.unit),
              ["per_100g", "per_100ml", "per_serving", "total"].contains(item.nutritionBasis) else {
            throw invalid("食物名称或营养单位无效")
        }
        try range(item.amount, lower: 0, upper: 100000, exclusive: true)
        try range(item.basisAmount, lower: 0, upper: Double.greatestFiniteMagnitude, exclusive: true)
        try range(item.consumedFraction, lower: 0, upper: 1)
        try range(item.confidence, lower: 0, upper: 1)
        for value in [item.basisKcal, item.basisProteinG, item.basisCarbsG, item.basisFatG] {
            try range(value, lower: 0, upper: 100000)
        }
        for (key, value) in item.lockedValues {
            guard ["kcal", "protein_g", "carbs_g", "fat_g"].contains(key) else { throw invalid("锁定营养字段无效") }
            try range(value, lower: 0, upper: 100000)
        }
        try range(item.servingWeightG, lower: 0, upper: Double.greatestFiniteMagnitude, exclusive: true)
        try range(item.densityGMl, lower: 0, upper: Double.greatestFiniteMagnitude, exclusive: true)
    }

    private static func range(_ value: Double?, lower: Double, upper: Double, exclusive: Bool = false) throws {
        guard let value else { return }
        guard value.isFinite, value <= upper, exclusive ? value > lower : value >= lower else {
            throw invalid("数值超出有效范围，请核对单位和小数")
        }
    }

    private static func timestamp(_ value: String) throws {
        guard TimeFormat.parse(value) != nil else { throw invalid("记录时间无效") }
    }

    private static func finiteValues(_ value: JSONValue) throws {
        switch value {
        case .number(let number): guard number.isFinite else { throw invalid("记录包含无效数值") }
        case .array(let values): for item in values { try finiteValues(item) }
        case .object(let values): for item in values.values { try finiteValues(item) }
        default: break
        }
    }

    private static func invalid(_ message: String) -> APIError { APIError(code: "VALIDATION_FAILED", message: message) }
}
