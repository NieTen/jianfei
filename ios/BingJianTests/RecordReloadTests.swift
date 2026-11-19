import Foundation
import XCTest
@testable import BingJian

final class RecordReloadTests: XCTestCase {
    func testConcurrentRecordTimestampsMatchStoredMillisecondPrecision() async {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = (0..<128).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 0.123456) }
        let expected = dates.map { reference.string(from: $0) }
        await withTaskGroup(of: (Int, String).self) { group in
            for (position, date) in dates.enumerated() {
                group.addTask { (position, TimeFormat.iso(date)) }
            }
            for await (position, timestamp) in group {
                XCTAssertEqual(timestamp, expected[position])
            }
        }
    }

    func testTenThousandRecordsReadOneUpdateAndKeepTheCompleteHistory() async throws {
        let fixture = try await LocalSQLiteFixture()
        let template = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70))
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<9999)
        INSERT INTO records(id,kind,business_date,document)
        SELECT '00000000-0000-0000-0000-'||printf('%012d',n),'weight','2026-11-19',
               json_set(?,'$.id','00000000-0000-0000-0000-'||printf('%012d',n)) FROM numbers
        """, [try Codec.json(template)])
        let initial = try await fixture.store.recordChanges(since: nil)
        let index = RecordIndex(records: initial.records)
        var value = try XCTUnwrap(initial.records.first)
        value.payload["weight_kg"] = .number(69)
        try await fixture.store.save(value, deviceId: "fixture-device")
        let start = ContinuousClock.now
        let update = try await fixture.store.recordChanges(since: initial.revision)
        let ids = Set(update.records.map(\.id)).union(update.removedIds)
        let replaced = initial.records.filter { ids.contains($0.id) }
        let merged = RecordIndex.merging(initial.records, updates: update.records, removing: ids)
        let updatedIndex = index.replacing(replaced, with: update.records)
        print("一万业务记录中的单条保存：读取 \(update.records.count) 条增量并合并内存索引 \(start.duration(to: .now))")
        XCTAssertFalse(update.replacesAll)
        XCTAssertEqual(update.records.count, 1)
        XCTAssertEqual(merged.count, 10_000)
        XCTAssertEqual(Set(merged.map(\.id)), Set(initial.records.map(\.id)))
        XCTAssertEqual(merged.first?.payload.number("weight_kg"), 69)
        XCTAssertEqual(updatedIndex.byKind, RecordIndex(records: merged).byKind)
        XCTAssertEqual(updatedIndex.weightsByDay, RecordIndex(records: merged).weightsByDay)
        let unchangedStart = ContinuousClock.now
        let unchanged = try await fixture.store.recordChanges(since: update.revision)
        print("一万业务记录无变化重载检查：\(unchangedStart.duration(to: .now))")
        XCTAssertTrue(unchanged.isEmpty)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM records"), 10_000)
    }

    func testDatabaseChangesIgnoreQueueOnlyWorkAndReturnOnlyChangedRecords() async throws {
        let fixture = try await LocalSQLiteFixture()
        var originals: [AppRecord] = []
        for number in 0..<1_000 {
            originals.append(try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70),
                id: String(format: "00000000-0000-0000-0000-%012d", number)))
        }
        try await fixture.store.save(originals, deviceId: "fixture-device")
        let baseline = try await fixture.store.recordChanges(since: nil)
        XCTAssertTrue(baseline.replacesAll)
        XCTAssertEqual(baseline.records.count, 1_000)
        try await fixture.store.setMetadata("last_sync", value: "queue-only")
        try await fixture.store.log("仅诊断变化")
        try await fixture.store.enqueueCommand(path: "fixture/queued", method: "POST", body: [:])
        let unchanged = try await fixture.store.recordChanges(since: baseline.revision)
        XCTAssertTrue(unchanged.isEmpty)
        XCTAssertEqual(unchanged.revision, baseline.revision)

        var changed = try XCTUnwrap(baseline.records.first)
        changed.businessDate = "2026-11-20"
        changed.payload["weight_kg"] = .number(69)
        try await fixture.store.save(changed, deviceId: "fixture-device")
        let delta = try await fixture.store.recordChanges(since: baseline.revision)
        XCTAssertFalse(delta.replacesAll)
        XCTAssertEqual(delta.records.map(\.id), [changed.id])
        XCTAssertEqual(delta.records.first?.businessDate, "2026-11-20")
        XCTAssertTrue(delta.removedIds.isEmpty)
        let after = try await fixture.store.recordChanges(since: delta.revision)
        XCTAssertTrue(after.isEmpty)

        // 相同服务端记录回放不触发无意义的重新发布。
        let remote = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 72))
        try await fixture.store.applyRemote([remote], cursor: nil)
        let remoteBaseline = try await fixture.store.recordChanges(since: delta.revision)
        try await fixture.store.applyRemote([remote], cursor: "another-cursor")
        let replay = try await fixture.store.recordChanges(since: remoteBaseline.revision)
        XCTAssertTrue(replay.isEmpty)
        XCTAssertEqual(replay.revision, remoteBaseline.revision)
    }

    func testRecordChangeTrackingFallsBackForOverflowExternalWritesAndStoreChanges() async throws {
        let fixture = try await LocalSQLiteFixture()
        let empty = try await fixture.store.recordChanges(since: nil)
        let values = try (0..<513).map {
            try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70),
                id: String(format: "00000000-0000-0000-0000-%012d", $0))
        }
        try await fixture.store.save(values, deviceId: "fixture-device")
        let overflow = try await fixture.store.recordChanges(since: empty.revision)
        XCTAssertTrue(overflow.replacesAll)
        XCTAssertEqual(overflow.records.count, 513)
        var replaced = try XCTUnwrap(overflow.records.first)
        replaced.payload["weight_kg"] = .number(68)
        try fixture.execute("UPDATE records SET document=? WHERE id=?", [try Codec.json(replaced), replaced.id])
        let external = try await fixture.store.recordChanges(since: overflow.revision)
        XCTAssertTrue(external.replacesAll, "其他SQLite连接写入不能被内存变更日志忽略")
        XCTAssertEqual(external.records.first { $0.id == replaced.id }?.payload.number("weight_kg"), 68)
        let another = try await LocalSQLiteFixture()
        let isolated = try await another.store.recordChanges(since: external.revision)
        XCTAssertTrue(isolated.replacesAll)
        XCTAssertTrue(isolated.records.isEmpty)
        try await fixture.store.clearLocalData()
        let cleared = try await fixture.store.recordChanges(since: external.revision)
        XCTAssertTrue(cleared.replacesAll)
        XCTAssertTrue(cleared.records.isEmpty)
    }

    func testPhysicalDeletionAndRolledBackWritesRemainCorrectForIncrementalReload() async throws {
        let fixture = try await LocalSQLiteFixture()
        let retained = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70))
        let removed = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 71))
        try await fixture.store.applyRemote([retained, removed], cursor: "before")
        let baseline = try await fixture.store.recordChanges(since: nil)
        try await fixture.store.beginSnapshot()
        try await fixture.store.applySnapshotPage([retained])
        let last = try await fixture.store.finishSnapshot(cursor: "after")
        XCTAssertNil(last)
        let delta = try await fixture.store.recordChanges(since: baseline.revision)
        XCTAssertFalse(delta.replacesAll)
        XCTAssertEqual(delta.removedIds, [removed.id])
        XCTAssertTrue(delta.records.isEmpty)

        let phantom = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 72))
        var invalid = phantom
        invalid.id = UUID().uuidString.lowercased()
        invalid.payload["weight_kg"] = .number(.nan)
        try await fixture.store.beginSnapshot()
        do { try await fixture.store.applySnapshotPage([phantom, invalid]); XCTFail("NaN正文必须回滚整页") }
        catch {}
        let rolledBack = try await fixture.store.recordChanges(since: delta.revision)
        let merged = RecordIndex.merging([retained], updates: rolledBack.records, removing: rolledBack.removedIds)
        XCTAssertEqual(merged, [retained], "保守变更标记不能把已回滚的记录发布到界面")
        let actual = try await fixture.store.allRecords()
        XCTAssertEqual(actual, [retained])
    }

    func testIncrementalIndexMatchesFullRebuildForMovedHiddenDeletedAndChangedKinds() throws {
        var rows: [AppRecord] = []
        for number in 0..<84 {
            let day = String(format: "2026-11-%02d", number % 28 + 1)
            rows.append(try AppRecord(kind: "weight", day: day,
                value: WeightEntry(measuredAt: day + "T08:00:00Z", weightKg: 65 + Double(number % 10), hidden: number % 13 == 0),
                id: String(format: "00000000-0000-0000-0000-%012d", number)))
        }
        var profile = try AppRecord(kind: "profile", day: "2026-10-01", value: BodyProfile(age: 30, sexForFormula: "male", heightCm: 175, timezone: "UTC"))
        var goal = try AppRecord(kind: "goal", day: "2026-11-01", value: GoalEntry(targetWeightKg: 62))
        rows += [profile, goal]
        rows = RecordIndex.merging([], updates: rows, removing: [])
        var index = RecordIndex(records: rows)
        for step in 0..<12 {
            var value = try XCTUnwrap(rows.first { $0.id == String(format: "00000000-0000-0000-0000-%012d", step) })
            switch step % 4 {
            case 0: value.businessDate = "2026-11-28"; value.payload["measured_at"] = .string("2026-11-28T23:00:00Z")
            case 1: value.payload["hidden"] = .bool(true)
            case 2: value.payload["source_deleted"] = .bool(true)
            default: value.deletedAt = "2026-11-30T00:00:00Z"
            }
            var updates = [value]
            if step == 3 {
                profile.payload["age"] = .number(35)
                profile.businessDate = "2026-11-15"
                updates.append(profile)
            }
            if step == 4 {
                goal.payload["target_weight_kg"] = .number(60)
                updates.append(goal)
            }
            if step == 5 {
                value.kind = "meal"
                value.payload = try Codec.object(MealEntry(eatenAt: value.businessDate + "T12:00:00Z", status: "confirmed",
                    items: [FoodItem(name: "手动热量", amount: 1, nutritionBasis: "total", basisKcal: 500)]))
                updates = [value]
            }
            let removed = step == 10 ? Set([goal.id]) : Set<String>()
            let ids = Set(updates.map(\.id)).union(removed)
            let previous = rows.filter { ids.contains($0.id) }
            index = index.replacing(previous, with: updates)
            // 参照集合用独立的过滤+全排序构造，避免用增量合并实现验证自身。
            let expectedRows = (rows.filter { !ids.contains($0.id) } + updates).sorted {
                $0.businessDate == $1.businessDate ? $0.id < $1.id : $0.businessDate > $1.businessDate
            }
            rows = RecordIndex.merging(rows, updates: updates, removing: ids)
            XCTAssertEqual(rows, expectedRows)
            let expected = RecordIndex(records: rows)
            XCTAssertEqual(index.byKind, expected.byKind)
            XCTAssertEqual(index.byDay, expected.byDay)
            XCTAssertEqual(index.weightsByDay, expected.weightsByDay)
            XCTAssertEqual(index.weightDays, expected.weightDays)
            XCTAssertEqual(index.profiles, expected.profiles)
            XCTAssertEqual(try Codec.object(index.goal), try Codec.object(expected.goal))
            let now = try XCTUnwrap(TimeFormat.parse("2026-11-28T23:30:00Z"))
            XCTAssertEqual(index.currentProfile(now: now), expected.currentProfile(now: now))
            for day in ["2026-11-01", "2026-11-15", "2026-11-28"] {
                XCTAssertEqual(index.forSummary(day: day), expected.forSummary(day: day))
                let summary = EnergyCalculator.summary(records: index.forSummary(day: day), day: day, now: now)
                let reference = EnergyCalculator.summary(records: expected.forSummary(day: day), day: day, now: now)
                XCTAssertEqual(summary.weight, reference.weight)
                XCTAssertEqual(summary.intake, reference.intake)
                XCTAssertEqual(summary.expenditure, reference.expenditure)
                XCTAssertEqual(summary.missingMeals, reference.missingMeals)
            }
            for metric in ["weight", "intake"] {
                let trend = TrendCalculator.calculate(index: index, profile: index.currentProfile(now: now), weightUnit: .jin, metric: metric, days: 28, end: now)
                let reference = TrendCalculator.calculate(index: expected, profile: expected.currentProfile(now: now), weightUnit: .jin, metric: metric, days: 28, end: now)
                XCTAssertEqual(trend.points.map(\.day), reference.points.map(\.day))
                XCTAssertEqual(trend.points.map(\.value), reference.points.map(\.value))
                XCTAssertEqual(trend.averages.map(\.value), reference.averages.map(\.value))
            }
        }
    }
}
