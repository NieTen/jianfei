import Foundation

enum MealInput {
    static let primaryTypes = ["breakfast", "lunch", "dinner"]

    static func suggestedType(at date: Date, timezone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        switch calendar.component(.hour, from: date) {
        case 5..<11: return "breakfast"
        case 11..<17: return "lunch"
        default: return "dinner"
        }
    }

    static func calorieItem(_ value: Double, id: String = UUID().uuidString.lowercased()) throws -> FoodItem {
        guard value.isFinite, value >= 0, value <= 100000 else {
            throw APIError(code: "INVALID_CALORIES", message: "请输入有效的摄入热量，单位为 kcal")
        }
        // 直接记录整餐热量，未提供的营养素保留空值，不伪造宏量营养。
        return FoodItem(id: id, name: "手动热量", amount: 1, unit: "serving", basisAmount: 1,
                        nutritionBasis: "total", basisKcal: value, source: "manual_calories")
    }

    static func manualCalories(in meal: MealEntry) -> Double? {
        guard meal.items.count == 1, meal.items[0].source == "manual_calories" else { return nil }
        return meal.items[0].kcal
    }

    static func nutrient(_ items: [FoodItem], value: (FoodItem) -> Double?) -> Double? {
        guard !items.isEmpty else { return nil }
        let values = items.compactMap(value)
        return values.count == items.count ? values.reduce(0, +) : nil
    }

    static func applyingRecognition(_ candidates: [FoodItem], to items: [FoodItem]) -> [FoodItem] {
        // 新一轮照片结果替换旧的 AI 候选；保留用户手动添加和已修改的食物。
        items.filter { !["ai_estimate", "manual_calories"].contains($0.source) } + candidates
    }
}
