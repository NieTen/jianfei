import XCTest
@testable import BingJian

final class EnergyCalculatorTests: XCTestCase {
    func testMaleFormula() {
        var profile = BodyProfile()
        profile.heightCm = 175
        profile.age = 30
        profile.sexForFormula = "male"
        XCTAssertEqual(EnergyCalculator.bmr(profile: profile, weight: 70, day: "2026-11-03"), 1648.75)
    }

    func testFoodPortion() {
        let food = FoodItem(name: "测试食物", amount: 150, basisAmount: 100, basisKcal: 116, consumedFraction: 0.8)
        XCTAssertEqual(food.kcal ?? 0, 139.2, accuracy: 0.0001)
    }

    func testDaylightSavingWindow() {
        let value = TimeFormat.window("2026-03-08", timezone: "America/New_York")
        XCTAssertEqual(value?.duration, 23 * 3600)
    }

    func testMissingWeightDoesNotBecomeZero() {
        XCTAssertNil(EnergyCalculator.weight([], day: "2026-11-03"))
    }

    func testUnknownNutritionRemainsMissing() throws {
        let meal = MealEntry(eatenAt: "2026-11-03T08:00:00Z", status: "confirmed", items: [FoodItem(name: "食物")])
        let record = try AppRecord(kind: "meal", day: "2026-11-03", value: meal)
        let summary = EnergyCalculator.summary(records: [record], day: "2026-11-03",
                                                now: TimeFormat.parse("2026-11-04T12:00:00Z")!)
        XCTAssertNil(summary.intake)
        XCTAssertNil(summary.protein)
        XCTAssertFalse(summary.complete)
    }
}
