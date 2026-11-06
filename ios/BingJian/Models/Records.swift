import Foundation

struct AppRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var businessDate: String
    var payload: JSONObject
    var sourceId: String?
    var version: Int
    var deletedAt: String?
    var updatedAt: String
    var deviceId: String

    init<T: Encodable>(kind: String, day: String, value: T, id: String = UUID().uuidString.lowercased(), sourceId: String? = nil) throws {
        self.id = id
        self.kind = kind
        businessDate = day
        payload = try Codec.object(value)
        self.sourceId = sourceId
        version = 0
        updatedAt = TimeFormat.iso()
        deviceId = ""
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? Codec.decode(type, from: payload)
    }
}

struct BodyProfile: Codable, Equatable, Sendable {
    var displayName = ""
    var birthDate: String?
    var age: Int?
    var sexForFormula = "unspecified"
    var heightCm: Double?
    var activityFactor = 1.2
    var stepLengthM: Double?
    var timezone = TimeZone.current.identifier
    var dayStartMinutes = 0
    // 保留旧版同步字段以兼容已有后台；新版本显示单位由 AppModel 的本机偏好决定。
    var weightUnit = "kg"
    var energyUnit = "kcal"
    var heightUnit = "cm"
    var routineMeals = ["breakfast", "lunch", "dinner"]
    var recordingOnly = false
    var effectiveAt: String?
}

struct WeightEntry: Codable, Equatable, Sendable {
    var measuredAt = TimeFormat.iso()
    var weightKg: Double
    var source = "manual"
    var sourceId: String?
    var sourceName: String?
    var note = ""
    var hidden = false
    var sourceDeleted = false
    var correctedWeightKg: Double?
    var representative = false
}

struct FoodItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var amount: Double = 100
    var unit = "g"
    var basisAmount: Double = 100
    var nutritionBasis = "per_100g"
    var basisKcal: Double?
    var basisProteinG: Double?
    var basisCarbsG: Double?
    var basisFatG: Double?
    var consumedFraction: Double = 1
    var source = "manual"
    var confidence: Double?
    var uncertaintyNote = ""
    var foodState = "unknown"
    var servingWeightG: Double?
    var densityGMl: Double?
    var lockedValues: [String: Double] = [:]
    var evidencePhotoIds: [String] = []
    var requiresPortion: Bool?

    var kcal: Double? { total(basisKcal, field: "kcal") }
    var protein: Double? { total(basisProteinG, field: "protein_g") }
    var carbs: Double? { total(basisCarbsG, field: "carbs_g") }
    var fat: Double? { total(basisFatG, field: "fat_g") }

    func total(_ value: Double?, field: String) -> Double? {
        if let locked = lockedValues[field] { return locked }
        guard let value, basisAmount > 0 else { return nil }
        let result = Decimal(value) * Decimal(amount) / Decimal(basisAmount) * Decimal(consumedFraction)
        return NSDecimalNumber(decimal: result).doubleValue
    }
}

struct MealEntry: Codable, Equatable, Sendable {
    var eatenAt = TimeFormat.iso()
    var timezone = TimeZone.current.identifier
    var mealType = "lunch"
    var status = "draft"
    var items: [FoodItem] = []
    var photoIds: [String] = []
    var note = ""
    var aiResult: JSONObject?
    var aiTaskId: String?
    var syncPhotos = true

    var kcal: Double? {
        if status == "skipped" { return 0 }
        let known = items.compactMap(\.kcal)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

struct DailyStatus: Codable, Sendable {
    var timezone = TimeZone.current.identifier
    var routineMeals = ["breakfast", "lunch", "dinner"]
    var intakeComplete = false
    var checkedIn = false
    var confirmedAt: String?
}

struct GoalEntry: Codable, Sendable {
    var targetWeightKg: Double?
    var stepGoal = 8000
    var startDate = TimeFormat.day()
    var endDate = TimeFormat.day(Calendar.current.date(byAdding: .day, value: 28, to: Date()) ?? Date())
    var selectedItems = ["diet", "weight", "steps"]
}

struct HealthDay: Codable, Sendable {
    var timezone = TimeZone.current.identifier
    var windowStart: String
    var windowEnd: String
    var steps: Double?
    var activeKcal: Double?
    var restingKcal: Double?
    var restingCoverage: Double?
    var heartRate: Double?
    var restingHeartRate: Double?
    var sleepHours: Double?
    var bodyFatPercent: Double?
    var workoutMinutes: Double?
    var distanceKm: Double?
    var source = "healthkit"
    var updatedAt = TimeFormat.iso()
}

struct MeasurementEntry: Codable, Sendable {
    var measuredAt = TimeFormat.iso()
    var waistCm: Double?
    var hipCm: Double?
    var bodyFatPercent: Double?
    var muscleKg: Double?
    var note = ""
}

struct WorkoutEntry: Codable, Sendable {
    var startAt: String
    var endAt: String
    var activityType: String
    var durationMinutes: Double
    var energyKcal: Double?
    var distanceKm: Double?
    var sourceId: String
    var sourceName = "健康"
    var sourceDeleted = false
}

struct FoodPreference: Codable, Sendable {
    var foodName: String
    var weightMultiplier: Double = 1
    var calorieMultiplier: Double = 1
    var sampleCount = 1
}

struct FavoriteFood: Codable, Sendable {
    var name: String
    var food: FoodItem
}

struct SyncMutation: Codable, Sendable {
    var changeId: String
    var entityId: String
    var kind: String
    var businessDate: String
    var payload: JSONObject
    var sourceId: String?
    var baseVersion: Int
    var deletedAt: String?
}

struct SyncConflict: Identifiable, Sendable {
    var id: String
    var local: AppRecord
    var remote: AppRecord?
    var message: String
}

struct SessionCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var userId: String
    var displayName: String
    var deviceId: String
    var generation: Int
    var epoch: String
    var instanceId: String
    var recoveryCode: String?
}

struct APIError: Error, LocalizedError, Sendable {
    var code: String
    var message: String
    var retryable: Bool = false
    var errorDescription: String? { message }
}

enum MealTypes {
    static let all = ["breakfast", "lunch", "dinner", "snack", "drink", "other"]
    static func name(_ value: String) -> String {
        ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐", "drink": "饮料", "other": "其他"][value] ?? value
    }
}
