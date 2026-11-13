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
    func testMissingSessionKeepsBoundLocalRecordsAndAllowsOfflineRecording() async throws {
        try await isolated { model in
            let originalNamespace = try XCTUnwrap(UserDefaults.standard.string(forKey: "local_namespace"))
            let input = OnboardingInput(age: 30, heightCm: 175, weight: 70, unit: .kg, sex: "male")
            let profileId = UUID().uuidString.lowercased(), weightId = UUID().uuidString.lowercased()
            try await model.finishOnboarding(input, profileId: profileId, weightId: weightId, offline: true)
            let originalStore = try model.requireStore()
            try await originalStore.setMetadata("bound_user", value: "test-instance:test-user")

            // 模拟重签后后台会话不可读；本机资料和记录仍属于原数据空间。
            let reopened = AppModel()
            await reopened.start()
            XCTAssertNil(reopened.session)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "local_namespace"), originalNamespace)
            XCTAssertEqual(Set(reopened.records.map(\.id)), Set([profileId, weightId]))
            XCTAssertTrue(reopened.profileSetupCompleted)
            XCTAssertTrue(reopened.setupCompleted)
            XCTAssertEqual(reopened.profile.age, 30)
            XCTAssertEqual(reopened.summary.weight, 70)

            try await reopened.recordWeight(71, unit: .kg, measuredAt: reopened.entryDate, note: "", representative: false)
            let savedRecords = try await originalStore.allRecords()
            let binding = try await originalStore.metadata("bound_user")
            XCTAssertEqual(savedRecords.filter { $0.kind == "weight" }.count, 2)
            XCTAssertTrue(savedRecords.contains { $0.id == weightId })
            XCTAssertEqual(binding, "test-instance:test-user")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "local_namespace"), originalNamespace)
            XCTAssertNil(reopened.session)
        }
    }

    @MainActor
    func testExplicitLogoutKeepsOldRecordsIsolatedAfterRelaunch() async throws {
        try await isolated { model in
            let defaults = UserDefaults.standard
            let originalNamespace = try XCTUnwrap(defaults.string(forKey: "local_namespace"))
            let input = OnboardingInput(age: 30, heightCm: 175, weight: 70, unit: .kg, sex: "male")
            let profileId = UUID().uuidString.lowercased(), weightId = UUID().uuidString.lowercased()
            try await model.finishOnboarding(input, profileId: profileId, weightId: weightId, offline: true)
            let originalStore = try model.requireStore()
            try await originalStore.setMetadata("bound_user", value: "test-instance:test-user")
            await model.start()

            await model.logout()
            let anonymousNamespace = try XCTUnwrap(defaults.string(forKey: "local_namespace"))
            XCTAssertNotEqual(anonymousNamespace, originalNamespace)
            XCTAssertEqual(anonymousNamespace, defaults.string(forKey: "anonymous_namespace"))
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertNil(model.session)

            // 主动退出已经选择匿名空间，后续无会话启动也不能重开退出前的账号库。
            let reopened = AppModel()
            await reopened.start()
            XCTAssertEqual(defaults.string(forKey: "local_namespace"), anonymousNamespace)
            XCTAssertTrue(reopened.records.isEmpty)
            XCTAssertNil(reopened.session)
            let anonymousStore = try reopened.requireStore()
            let anonymousBinding = try await anonymousStore.metadata("bound_user")
            XCTAssertNil(anonymousBinding)

            let retainedStore = try LocalDatabase(namespace: originalNamespace)
            let retainedRecords = try await retainedStore.allRecords()
            let retainedBinding = try await retainedStore.metadata("bound_user")
            XCTAssertEqual(Set(retainedRecords.map(\.id)), Set([profileId, weightId]))
            XCTAssertEqual(retainedBinding, "test-instance:test-user")
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
        let keys = ["local_namespace", "anonymous_namespace", "setup_completed", "sync_enabled", "health_enabled",
                    "server_url", "device_id", AppModel.weightUnitPreferenceKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        let previousSession = KeychainStore.read("active_session")
        let namespace = "entry-test-" + UUID().uuidString.lowercased()
        let anonymousNamespace = namespace + "-anonymous"
        defaults.set(namespace, forKey: "local_namespace")
        defaults.set(anonymousNamespace, forKey: "anonymous_namespace")
        defaults.set(false, forKey: "sync_enabled")
        defaults.set(false, forKey: "health_enabled")
        defaults.set(false, forKey: "setup_completed")
        defaults.set("https://recording-tests.invalid", forKey: "server_url")
        KeychainStore.delete("active_session")
        defer {
            for value in [namespace, anonymousNamespace] {
                defaults.removeObject(forKey: "body_setup_completed:" + value)
                defaults.removeObject(forKey: "external_ai_consent:" + value)
            }
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            if let previousSession {
                XCTAssertNoThrow(try KeychainStore.save(previousSession, key: "active_session"))
            } else {
                KeychainStore.delete("active_session")
            }
        }
        try await action(AppModel())
    }
}
