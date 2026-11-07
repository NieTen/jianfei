import XCTest
@testable import BingJian

final class RecordingFlowTests: XCTestCase {
    func testMealSuggestionUsesLocalClock() throws {
        for (timestamp, expected) in [("2026-11-03T00:00:00Z", "breakfast"), ("2026-11-03T06:00:00Z", "lunch"), ("2026-11-03T12:00:00Z", "dinner")] {
            XCTAssertEqual(MealInput.suggestedType(at: try XCTUnwrap(TimeFormat.parse(timestamp)), timezone: "Asia/Shanghai"), expected)
        }
    }

    func testManualCaloriesCanSaveWithoutInventingMacros() throws {
        let food = try MealInput.calorieItem(650)
        let meal = MealEntry(status: "confirmed", items: [food])
        try RecordValidator.validate(AppRecord(kind: "meal", day: TimeFormat.day(), value: meal))
        XCTAssertEqual(meal.kcal, 650)
        XCTAssertEqual(MealInput.manualCalories(in: meal), 650)
        XCTAssertNil(MealInput.nutrient(meal.items, value: { $0.protein }))
        XCTAssertThrowsError(try MealInput.calorieItem(-1))
        XCTAssertThrowsError(try MealInput.calorieItem(.nan))
    }

    func testRepeatedRecognitionReplacesEstimatesAndKeepsManualCorrections() throws {
        let manual = FoodItem(name: "已修正米饭", source: "manual")
        let old = FoodItem(name: "旧识别", source: "ai_estimate")
        let new = FoodItem(name: "新识别", source: "ai_estimate")
        let existing = [manual, old, try MealInput.calorieItem(600)]
        let first = MealInput.applyingRecognition([new], to: existing)
        XCTAssertEqual(first.map(\.id), [manual.id, new.id])
        XCTAssertEqual(MealInput.applyingRecognition([new], to: first), first)
    }

    func testLatestMeasurementIgnoresLegacyRepresentativeFlag() throws {
        let early = try AppRecord(kind: "weight", day: "2026-11-03",
            value: WeightEntry(measuredAt: "2026-11-03T08:00:00Z", weightKg: 70, representative: true))
        let late = try AppRecord(kind: "weight", day: "2026-11-03",
            value: WeightEntry(measuredAt: "2026-11-03T19:00:00Z", weightKg: 71))
        XCTAssertEqual(EnergyCalculator.weight([late, early], day: "2026-11-03"), 71)
    }

    func testEnergyBalanceBeforeFirstMealUsesElapsedEstimate() throws {
        let profile = BodyProfile(age: 31, sexForFormula: "male", heightCm: 168, timezone: "UTC")
        let records = [try AppRecord(kind: "profile", day: "2026-11-03", value: profile),
                       try AppRecord(kind: "weight", day: "2026-11-03", value: WeightEntry(weightKg: 70))]
        let now = try XCTUnwrap(TimeFormat.parse("2026-11-03T12:00:00Z"))
        let result = EnergyCalculator.summary(records: records, day: "2026-11-03", now: now)
        XCTAssertEqual(result.intake, 0)
        XCTAssertEqual(result.expenditure, 960)
        XCTAssertEqual(result.deficit, 960)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.missingMeals.count, 3)
        XCTAssertNil(result.protein)
    }

    func testIntakeChartLeavesUnrecordedDatesEmpty() throws {
        let profile = BodyProfile(timezone: "UTC")
        let meal = MealEntry(eatenAt: "2026-11-02T08:00:00Z", status: "confirmed", items: [try MealInput.calorieItem(650)])
        let index = RecordIndex(records: [try AppRecord(kind: "meal", day: "2026-11-02", value: meal)])
        let result = TrendCalculator.calculate(index: index, profile: profile, weightUnit: .kg,
            metric: "intake", days: 3, end: try XCTUnwrap(TimeFormat.parse("2026-11-03T12:00:00Z")))
        XCTAssertEqual(result.points.map(\.day), ["2026-11-02"])
        XCTAssertEqual(result.points.map(\.value), [650])
    }

    func testHistoricalDateUsesSelectedBusinessDayWithCustomBoundary() throws {
        let profile = BodyProfile(timezone: "Asia/Shanghai", dayStartMinutes: 240)
        let now = try XCTUnwrap(TimeFormat.parse("2026-11-07T18:00:00Z"))
        let value = RecordDate.timestamp(for: "2026-11-03", profile: profile, now: now)
        XCTAssertEqual(TimeFormat.day(value, timezone: profile.timezone, startMinutes: profile.dayStartMinutes), "2026-11-03")
        XCTAssertLessThan(value, now)
    }

    func testOnboardingValidatesEveryRequiredFieldAndMinorRecordingMode() throws {
        XCTAssertEqual(Set(OnboardingInput().errors.keys), ["age", "height", "weight", "sex"])
        let input = OnboardingInput(age: 16, heightCm: 170, weight: 120, unit: .jin, sex: "male")
        let profile = try input.profile(basedOn: BodyProfile())
        XCTAssertTrue(profile.recordingOnly)
        XCTAssertNil(EnergyCalculator.bmr(profile: profile, weight: 60, day: "2026-11-03"))
    }

    @MainActor
    func testOnboardingSavesProfileAndWeightAndSurvivesRelaunch() async throws {
        try await isolated { model in
            let input = OnboardingInput(age: 30, heightCm: 175, weight: 140, unit: .jin, sex: "male")
            let profileId = UUID().uuidString.lowercased(), weightId = UUID().uuidString.lowercased()
            try await model.finishOnboarding(input, profileId: profileId, weightId: weightId, offline: true)
            try await model.finishOnboarding(input, profileId: profileId, weightId: weightId, offline: true)
            let reopened = AppModel()
            await reopened.reload()
            XCTAssertTrue(reopened.profileSetupCompleted)
            XCTAssertTrue(reopened.setupCompleted)
            XCTAssertEqual(reopened.profile.age, 30)
            XCTAssertEqual(reopened.summary.weight, 70)
            XCTAssertEqual(reopened.weightUnit, .jin)
            XCTAssertEqual(reopened.records.filter { $0.kind == "weight" }.count, 1)
        }
    }

    @MainActor
    func testInvalidOnboardingDoesNotPartiallyWriteRecords() async throws {
        try await isolated { model in
            do {
                try await model.finishOnboarding(OnboardingInput(), profileId: UUID().uuidString.lowercased(),
                    weightId: UUID().uuidString.lowercased(), offline: true)
                XCTFail("不应接受缺失身体参数")
            } catch { XCTAssertEqual((error as? APIError)?.code, "PROFILE_REQUIRED") }
            await model.reload()
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertFalse(model.profileSetupCompleted)
        }
    }

    @MainActor
    func testHomeSelectedDateAndEditedWeightKeepCorrectDate() async throws {
        try await isolated { model in
            var profile = BodyProfile()
            profile.timezone = "UTC"
            try await model.saveProfile(profile)
            model.selectedDate = try XCTUnwrap(TimeFormat.parse("2026-11-02T12:00:00Z"))
            await model.reload()
            try await model.recordWeight(70, unit: .kg, measuredAt: model.entryDate, note: "", representative: false)
            let saved = try XCTUnwrap(model.records.first { $0.kind == "weight" })
            XCTAssertEqual(saved.businessDate, "2026-11-02")
            let next = try XCTUnwrap(TimeFormat.parse("2026-11-03T12:00:00Z"))
            try await model.recordWeight(71, unit: .kg, measuredAt: next, note: "", representative: false, existing: saved)
            XCTAssertEqual(model.records.first { $0.id == saved.id }?.businessDate, "2026-11-03")
        }
    }

    @MainActor
    private func isolated(_ action: (AppModel) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["local_namespace", "setup_completed", "sync_enabled", AppModel.weightUnitPreferenceKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        let namespace = "entry-test-" + UUID().uuidString.lowercased()
        defaults.set(namespace, forKey: "local_namespace")
        defaults.set(false, forKey: "sync_enabled")
        defaults.set(false, forKey: "setup_completed")
        defer {
            defaults.removeObject(forKey: "body_setup_completed:" + namespace)
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        try await action(AppModel())
    }
}
