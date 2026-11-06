import XCTest
@testable import BingJian

final class WeightUnitTests: XCTestCase {
    func testConversionsPreserveActualWeightIncludingLegacyPounds() {
        XCTAssertEqual(WeightUnit.jin.fromKilograms(70), 140)
        XCTAssertEqual(WeightUnit.jin.kilograms(from: 140.4), 70.2, accuracy: 0.000001)
        XCTAssertEqual(WeightUnit.lb.kilograms(from: 100), 45.359237, accuracy: 0.000001)
        for source in WeightUnit.allCases {
            for destination in WeightUnit.allCases {
                let converted = source.converted(137.65, to: destination)
                XCTAssertEqual(destination.converted(converted, to: source), 137.65, accuracy: 0.000001)
            }
        }
        XCTAssertEqual(WeightUnit.kg.converted(70, to: .jin), 140)
        XCTAssertEqual(WeightUnit.jin.converted(140, to: .kg), 70)
    }

    @MainActor
    func testFirstJinEntryAndNextEntrySurviveReload() async throws {
        try await withIsolatedModel { model in
            try await model.recordWeight(140.4, unit: .jin, measuredAt: Date(), note: "首次录入", representative: false)
            let first = try XCTUnwrap(model.records.first { $0.kind == "weight" })
            XCTAssertEqual(first.payload.number("weight_kg") ?? 0, 70.2, accuracy: 0.000001)
            let reloaded = AppModel()
            await reloaded.reload()
            XCTAssertEqual(reloaded.weightUnit, .jin)
            XCTAssertEqual(reloaded.weightUnit.fromKilograms(try XCTUnwrap(reloaded.summary.weight)), 140.4, accuracy: 0.000001)
            try await reloaded.recordWeight(139.8, unit: reloaded.weightUnit, measuredAt: Date(), note: "再次录入", representative: false)
            let next = try XCTUnwrap(reloaded.records.first { $0.kind == "weight" && $0.id != first.id })
            XCTAssertEqual(next.payload.number("weight_kg") ?? 0, 69.9, accuracy: 0.000001)
        }
    }

    @MainActor
    func testKilogramSelectionAndSwitchLeaveStoredRecordsUnchanged() async throws {
        try await withIsolatedModel { model in
            try await model.recordWeight(70, unit: .kg, measuredAt: Date(), note: "公斤录入", representative: true)
            try await model.saveGoal(GoalEntry(targetWeightKg: 65))
            try await model.saveRecord(AppRecord(kind: "measurement", day: model.day, value: MeasurementEntry(muscleKg: 30)))
            let stored = model.records
            XCTAssertEqual(AppModel().weightUnit, .kg)
            model.setWeightUnit(.jin)
            await model.reload()
            XCTAssertEqual(model.weightUnit, .jin)
            XCTAssertEqual(model.records, stored)
            XCTAssertEqual(model.weightUnit.fromKilograms(try XCTUnwrap(model.goal.targetWeightKg)), 130)
            model.setWeightUnit(.kg)
            XCTAssertEqual(AppModel().weightUnit, .kg)
            XCTAssertEqual(model.summary.weight, 70)
        }
    }

    @MainActor
    func testHealthCorrectionInJinPreservesOriginalMeasurement() async throws {
        try await withIsolatedModel { model in
            let original = WeightEntry(weightKg: 70, source: "healthkit", sourceId: UUID().uuidString)
            let record = try AppRecord(kind: "weight", day: model.day, value: original)
            try await model.saveRecord(record)
            try await model.recordWeight(142, unit: .jin, measuredAt: Date(), note: "修正", representative: true, existing: record)
            let corrected = try XCTUnwrap(model.records.first { $0.id == record.id }?.decode(WeightEntry.self))
            XCTAssertEqual(corrected.weightKg, 70)
            XCTAssertEqual(corrected.correctedWeightKg, 71)
            XCTAssertEqual(corrected.measuredAt, original.measuredAt)
            XCTAssertEqual(corrected.sourceId, original.sourceId)
            XCTAssertEqual(model.summary.weight, 71)
        }
    }

    @MainActor
    func testLegacyUnitMigratesOnceAndSyncedProfileCannotOverrideLocalChoice() async throws {
        try await withIsolatedModel { model in
            var profile = BodyProfile()
            profile.weightUnit = "lb"
            try await model.saveProfile(profile)
            XCTAssertEqual(model.weightUnit, .lb)
            model.setWeightUnit(.jin)
            profile.weightUnit = "kg"
            try await model.saveProfile(profile)
            let reloaded = AppModel()
            await reloaded.reload()
            XCTAssertEqual(reloaded.weightUnit, .jin)
            // 单位为本机偏好，上传的旧版档案协议仍只包含 kg/lb，旧 NAS 无需升级。
            XCTAssertTrue(reloaded.records.filter { $0.kind == "profile" }.allSatisfy {
                ["kg", "lb"].contains($0.payload.text("weight_unit"))
            })
            UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: "local_namespace")
            let otherAccount = AppModel()
            await otherAccount.reload()
            XCTAssertEqual(otherAccount.weightUnit, .jin)
        }
    }

    @MainActor
    func testInvalidWeightDoesNotChangePreferenceOrCreateRecord() async throws {
        try await withIsolatedModel { model in
            model.setWeightUnit(.kg)
            for invalid in [0, -1, 1200.1, Double.infinity, Double.nan] {
                do {
                    try await model.recordWeight(invalid, unit: .jin, measuredAt: Date(), note: "", representative: false)
                    XCTFail("无效体重不应保存")
                } catch { }
            }
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertEqual(AppModel().weightUnit, .kg)
        }
    }

    func testTrendAndMovingAverageUseViewerUnitWithoutChangingBodyFat() throws {
        var profile = BodyProfile()
        profile.timezone = "UTC"
        var records: [AppRecord] = []
        for (day, kg) in [("2026-11-01", 70.0), ("2026-11-02", 71.0), ("2026-11-03", 72.0)] {
            records.append(try AppRecord(kind: "weight", day: day, value: WeightEntry(measuredAt: day + "T08:00:00Z", weightKg: kg)))
        }
        records.append(try AppRecord(kind: "measurement", day: "2026-11-03", value: MeasurementEntry(bodyFatPercent: 25)))
        let index = RecordIndex(records: records)
        let end = try XCTUnwrap(TimeFormat.parse("2026-11-03T12:00:00Z"))
        let kilograms = TrendCalculator.calculate(index: index, profile: profile, weightUnit: .kg, metric: "weight", days: 3, end: end)
        let jin = TrendCalculator.calculate(index: index, profile: profile, weightUnit: .jin, metric: "weight", days: 3, end: end)
        XCTAssertEqual(kilograms.points.map(\.value), [70, 71, 72])
        XCTAssertEqual(jin.points.map(\.value), [140, 142, 144])
        XCTAssertEqual(kilograms.averages.map(\.value), [71])
        XCTAssertEqual(jin.averages.map(\.value), [142])
        let bodyFat = TrendCalculator.calculate(index: index, profile: profile, weightUnit: .jin, metric: "body_fat", days: 3, end: end)
        XCTAssertEqual(bodyFat.points.map(\.value), [25])
        XCTAssertEqual(index.representativeWeight(day: "2026-11-03"), 72)
    }

    func testPartnerPayloadDisplaysAccordingToEachViewer() throws {
        // 伙伴共享值来自 weight_kg；显示只读取查看者偏好，不读取对方的档案单位。
        let member: JSONObject = ["weight_kg": .number(70), "weight_unit": .string("kg")]
        let kilograms = try XCTUnwrap(member.number("weight_kg"))
        XCTAssertEqual(WeightUnit.kg.formatted(kilograms: kilograms), "70 公斤")
        XCTAssertEqual(WeightUnit.jin.formatted(kilograms: kilograms), "140 斤")
        XCTAssertEqual(member.number("weight_kg"), 70)
    }

    @MainActor
    private func withIsolatedModel(_ action: (AppModel) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["local_namespace", "sync_enabled", AppModel.weightUnitPreferenceKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set("weight-test-" + UUID().uuidString.lowercased(), forKey: "local_namespace")
        defaults.set(false, forKey: "sync_enabled")
        defaults.removeObject(forKey: AppModel.weightUnitPreferenceKey)
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        try await action(AppModel())
    }
}
