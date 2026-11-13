import Foundation
import SQLite3
import XCTest
@testable import BingJian

/// 用独立 SQLite 连接准备大量历史数据；查询、分页、迁移和清理均调用实际 LocalDatabase。
private final class LocalSQLiteFixture {
    let store: LocalDatabase
    let directory: URL
    private var connection: OpaquePointer?

    init() async throws {
        store = try LocalDatabase(namespace: "database-performance-" + UUID().uuidString.lowercased())
        directory = await store.directory
        guard sqlite3_open(directory.appendingPathComponent("records.sqlite3").path, &connection) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: 1)
        }
        sqlite3_busy_timeout(connection, 5000)
    }

    deinit {
        sqlite3_close(connection)
        try? FileManager.default.removeItem(at: directory)
    }

    func execute(_ sql: String, _ values: [String?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func scalar(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func texts(_ sql: String, column: Int32 = 0) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            if let value = sqlite3_column_text(statement, column) { result.append(String(cString: value)) }
        }
    }

    func plan(_ sql: String, expectedIndex: String) throws {
        // 索引由 actor 的另一条连接创建；新只读连接避免 EXPLAIN 复用造数连接的旧 schema 缓存。
        var reader: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("records.sqlite3").path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw failure()
        }
        defer { sqlite3_finalize(statement); sqlite3_close(reader) }
        guard sqlite3_prepare_v2(reader, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 3) { rows.append(String(cString: value)) }
        }
        let details = rows.joined(separator: "；")
        print("SQLite 查询计划：\(details)")
        XCTAssertTrue(details.contains(expectedIndex), "应使用分页索引 \(expectedIndex)")
        XCTAssertFalse(details.contains("USE TEMP B-TREE"), "列表排序不能建立全量临时排序树")
    }

    private func failure() -> NSError {
        NSError(domain: "SQLiteFixture", code: Int(sqlite3_errcode(connection)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
    }
}

final class LocalDatabasePerformanceTests: XCTestCase {
    // 日常回归默认十万条；性能验收可扩大到五十万，避免读取任意无界测试参数。
    private var largeRowCount: Int {
        min(500_000, max(100_000, Int(ProcessInfo.processInfo.environment["BINGJIAN_PERFORMANCE_ROWS"] ?? "") ?? 100_000))
    }

    func testRecognitionConfirmationChecksPayloadInsideTheSaveTransaction() async throws {
        let fixture = try await LocalSQLiteFixture()
        let original = try AppRecord(kind: "meal", day: "2026-11-13", value: MealEntry(items: [FoodItem(name: "原始餐次")]))
        try await fixture.store.save(original, deviceId: "fixture-device")
        var taskUpdate = original
        taskUpdate.payload["ai_task_id"] = .string(UUID().uuidString.lowercased())
        taskUpdate.payload["ai_result"] = .object(["status": .string("completed")])
        try await fixture.store.save(taskUpdate, deviceId: "fixture-device")
        var accepted = taskUpdate
        accepted.payload["note"] = .string("用户确认了识别结果")
        try await fixture.store.save(accepted, deviceId: "fixture-device", expectedPayload: original.payload)
        let confirmed = try await fixture.store.record(original.id)
        XCTAssertEqual(confirmed?.payload.text("note"), "用户确认了识别结果", "仅任务元数据推进不能阻止结果确认")

        var edited = accepted
        edited.payload["note"] = .string("识别期间另一次实质编辑")
        try await fixture.store.save(edited, deviceId: "fixture-device")
        let beforeRecord = try await fixture.store.record(original.id)
        let beforeQueue = try fixture.texts("SELECT change_id||':'||document||':'||state FROM outbox ORDER BY change_id")
        var stale = accepted
        stale.payload["note"] = .string("过期AI结果不能覆盖")
        do {
            try await fixture.store.save(stale, deviceId: "fixture-device", expectedPayload: accepted.payload)
            XCTFail("并发实质修改必须拒绝")
        } catch { XCTAssertEqual((error as? APIError)?.code, "MEAL_VERSION_CHANGED") }
        let afterRecord = try await fixture.store.record(original.id)
        XCTAssertEqual(afterRecord, beforeRecord)
        XCTAssertEqual(try fixture.texts("SELECT change_id||':'||document||':'||state FROM outbox ORDER BY change_id"), beforeQueue,
                       "校验失败必须回滚整个事务，不得替换待同步变更标识或正文")

        var deleted = edited
        deleted.deletedAt = TimeFormat.iso()
        try await fixture.store.save(deleted, deviceId: "fixture-device")
        let deletedQueue = try fixture.texts("SELECT change_id||':'||document||':'||state FROM outbox ORDER BY change_id")
        do {
            try await fixture.store.save(stale, deviceId: "fixture-device", expectedPayload: edited.payload)
            XCTFail("已删除餐次不能被识别结果复活")
        } catch { XCTAssertEqual((error as? APIError)?.code, "MEAL_VERSION_CHANGED") }
        let stillDeleted = try await fixture.store.record(original.id)
        XCTAssertNotNil(stillDeleted?.deletedAt)
        XCTAssertEqual(try fixture.texts("SELECT change_id||':'||document||':'||state FROM outbox ORDER BY change_id"), deletedQueue)
    }

    func testLargeQueuedCommandsPageWithoutLoadingBodiesOrDroppingRows() async throws {
        let fixture = try await LocalSQLiteFixture()
        let rowCount = largeRowCount
        let timestamp = TimeFormat.iso()
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<CAST(? AS INTEGER))
        INSERT INTO commands(id,path,method,body,priority,created_at)
        SELECT printf('command-%06d',n),'/fixture/'||n,'POST','正文不应在摘要页解码',n%3,? FROM numbers
        """, [String(rowCount - 1), timestamp])
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<999)
        INSERT INTO records(id,kind,business_date,document)
        SELECT printf('record-%06d',n),'weight','2026-11-13','正文不应在概览中解码' FROM numbers
        """)
        try fixture.execute("INSERT INTO conflicts(entity_id,remote,message) SELECT id,'未解码远端正文','测试冲突' FROM records")
        try fixture.execute("INSERT INTO outbox(change_id,entity_id,document,state,created_at,error) SELECT 'change-'||id,id,'未解码变更正文','failed',?,'测试失败' FROM records", [timestamp])
        let overviewStart = ContinuousClock.now
        let overview = try await fixture.store.syncOverview()
        print("队列规模 \(rowCount)，概览含首次索引准备：\(overviewStart.duration(to: .now))")
        XCTAssertEqual(overview.commandCount, rowCount)
        XCTAssertEqual(overview.pendingCount, 1_000)
        XCTAssertEqual(overview.failedCount, 1_000)
        XCTAssertEqual(overview.conflictCount, 1_000)
        let conflicts = try await fixture.store.conflictsPage()
        let failures = try await fixture.store.failedRecordsPage()
        XCTAssertEqual(conflicts.items.count, 50)
        XCTAssertEqual(failures.items.count, 50)
        XCTAssertEqual(conflicts.items.first?.id, "record-000000")
        XCTAssertEqual(failures.items.first?.id, "change-record-000999")
        var conflictIds: [String] = [], failureIds: [String] = []
        var conflictCursor: LocalPageCursor?, failureCursor: LocalPageCursor?
        repeat {
            let batch = try await fixture.store.conflictsPage(after: conflictCursor)
            conflictIds.append(contentsOf: batch.items.map(\.id))
            conflictCursor = batch.nextCursor
        } while conflictCursor != nil
        repeat {
            let batch = try await fixture.store.failedRecordsPage(after: failureCursor)
            failureIds.append(contentsOf: batch.items.map(\.id))
            failureCursor = batch.nextCursor
        } while failureCursor != nil
        XCTAssertTrue(conflictIds == (0..<1_000).map { String(format: "record-%06d", $0) })
        XCTAssertTrue(failureIds == (0..<1_000).reversed().map { String(format: "change-record-%06d", $0) })
        let nextConflicts = try await fixture.store.conflictsPage(after: conflicts.nextCursor)
        let previousConflicts = try await fixture.store.conflictsPage(before: nextConflicts.previousCursor)
        let nextFailures = try await fixture.store.failedRecordsPage(after: failures.nextCursor)
        let previousFailures = try await fixture.store.failedRecordsPage(before: nextFailures.previousCursor)
        XCTAssertEqual(previousConflicts.items.map(\.id), conflicts.items.map(\.id))
        XCTAssertEqual(previousFailures.items.map(\.id), failures.items.map(\.id))

        let firstStart = ContinuousClock.now
        let first = try await fixture.store.commandsPage()
        print("命令首批 \(first.items.count) 条：\(firstStart.duration(to: .now))")
        let secondStart = ContinuousClock.now
        let second = try await fixture.store.commandsPage(after: first.nextCursor)
        print("命令第二批 \(second.items.count) 条：\(secondStart.duration(to: .now))")
        let previous = try await fixture.store.commandsPage(before: second.previousCursor)
        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(previous.items.map(\.id), first.items.map(\.id))
        XCTAssertNil(previous.previousCursor)
        let capped = try await fixture.store.commandsPage(limit: 100_000)
        XCTAssertEqual(capped.items.count, 100)
        try fixture.plan("SELECT id,path,method,priority,created_at FROM commands WHERE (priority<? OR (priority=? AND (created_at,id)>(?,?))) ORDER BY priority DESC,created_at ASC,id ASC LIMIT ?", expectedIndex: "idx_commands_page")
        try fixture.plan("SELECT change_id,entity_id,error,created_at FROM outbox WHERE state='failed' AND (created_at,change_id)<(?,?) ORDER BY created_at DESC,change_id DESC LIMIT ?", expectedIndex: "idx_outbox_state_page")

        var allIds: [String] = []
        var slowestPage = Duration.zero
        let traversalStart = ContinuousClock.now
        var cursor: LocalPageCursor?
        repeat {
            let batchStart = ContinuousClock.now
            let batch = try await fixture.store.commandsPage(after: cursor, limit: 100)
            slowestPage = max(slowestPage, batchStart.duration(to: .now))
            XCTAssertLessThanOrEqual(batch.items.count, 100)
            allIds.append(contentsOf: batch.items.map(\.id))
            cursor = batch.nextCursor
        } while cursor != nil
        print("命令全量分页遍历 \(allIds.count) 条：\(traversalStart.duration(to: .now))，最慢单页：\(slowestPage)")
        let expected = (0..<rowCount).sorted { left, right in
            left % 3 == right % 3 ? left < right : left % 3 > right % 3
        }.map { String(format: "command-%06d", $0) }
        XCTAssertTrue(allIds == expected, "相同时间和不同优先级的大量操作必须完整、稳定、无重复地遍历")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM commands"), rowCount)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM records"), 1_000)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(change_id) FROM outbox"), 1_000)

        // 边界记录已完成并移除后，游标仍按原排序值继续，不能跳过下一条。
        let boundary = try XCTUnwrap(first.items.last)
        try fixture.execute("DELETE FROM commands WHERE id=?", [boundary.id])
        let afterDeletion = try await fixture.store.commandsPage(after: first.nextCursor)
        XCTAssertEqual(afterDeletion.items.map(\.id), second.items.map(\.id))
        let isolated = try await LocalSQLiteFixture()
        let empty = try await isolated.store.syncOverview()
        XCTAssertEqual(empty.commandCount, 0)
        XCTAssertEqual(empty.conflictCount, 0)
    }

    func testWeightHistoryPagesApplyVisibilityAndKeepEveryStoredMeasurement() async throws {
        let fixture = try await LocalSQLiteFixture()
        var expectedVisible: [AppRecord] = [], expectedAll: [AppRecord] = []
        try fixture.execute("BEGIN IMMEDIATE")
        for index in 0..<10_000 {
            let day = String(format: "2026-11-%02d", index % 5 + 1)
            let weight = WeightEntry(measuredAt: "2026-11-01T08:00:00Z", weightKg: 70,
                                     hidden: index % 10 == 0, sourceDeleted: index % 15 == 0)
            var record = try AppRecord(kind: "weight", day: day, value: weight,
                                       id: String(format: "00000000-0000-0000-0000-%012d", index))
            if index % 20 == 0 { record.deletedAt = TimeFormat.iso() }
            try fixture.execute("INSERT INTO records(id,kind,business_date,document) VALUES(?,?,?,?)",
                                [record.id, record.kind, record.businessDate, try Codec.json(record)])
            if record.deletedAt == nil {
                expectedAll.append(record)
                if !weight.hidden && !weight.sourceDeleted { expectedVisible.append(record) }
            }
        }
        try fixture.execute("COMMIT")
        for showHidden in [false, true] {
            var ids: [String] = [], cursor: LocalPageCursor?
            repeat {
                let batch = try await fixture.store.weightHistoryPage(showHidden: showHidden, after: cursor, limit: 100_000)
                XCTAssertLessThanOrEqual(batch.items.count, 100)
                ids.append(contentsOf: batch.items.map(\.id))
                cursor = batch.nextCursor
            } while cursor != nil
            let expected = (showHidden ? expectedAll : expectedVisible).sorted {
                ($0.businessDate, $0.id) > ($1.businessDate, $1.id)
            }.map(\.id)
            XCTAssertTrue(ids == expected, "体重分页不能漏掉同一天的记录，隐藏筛选也不能改变磁盘原始数据")
        }
        let first = try await fixture.store.weightHistoryPage()
        try fixture.plan("SELECT document FROM records WHERE kind='weight' AND json_extract(document,'$.deleted_at') IS NULL AND COALESCE(json_extract(document,'$.payload.hidden'),0)=0 AND COALESCE(json_extract(document,'$.payload.source_deleted'),0)=0 AND (business_date,id)<(?,?) ORDER BY business_date DESC,id DESC LIMIT ?", expectedIndex: "idx_records_page")
        let second = try await fixture.store.weightHistoryPage(after: first.nextCursor)
        let previous = try await fixture.store.weightHistoryPage(before: second.previousCursor)
        XCTAssertEqual(previous.items.map(\.id), first.items.map(\.id))
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM records"), 10_000)
    }

    func testLargeLegacyLogsTrimInBatchesWithoutTouchingRecordsQueuesOrPhotos() async throws {
        let fixture = try await LocalSQLiteFixture()
        let rowCount = largeRowCount
        let record = try AppRecord(kind: "weight", day: "2026-11-13", value: WeightEntry(weightKg: 70))
        try await fixture.store.save(record, deviceId: "fixture-device")
        try await fixture.store.addConflict(entityId: record.id, remote: record, message: "保留此冲突")
        try await fixture.store.enqueueCommand(path: "/fixture/preserve", method: "POST", body: ["preserve": .bool(true)], priority: 100)
        let photoId = UUID().uuidString.lowercased(), mealId = UUID().uuidString.lowercased()
        let photo = Data("fixture-photo-bytes".utf8)
        try await fixture.store.savePhoto(photo, id: photoId, mealId: mealId)
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<CAST(? AS INTEGER))
        INSERT INTO logs(id,created_at,message)
        SELECT printf('legacy-%06d',n),?,CASE WHEN n=CAST(? AS INTEGER) THEN ? ELSE '旧版诊断' END FROM numbers
        """, [String(rowCount - 1), TimeFormat.iso(Date().addingTimeInterval(-3600)), String(rowCount - 1), String(repeating: "长", count: 5000)])

        let cleanupStart = ContinuousClock.now
        let more = try await fixture.store.trimDiagnosticLogsBatch()
        XCTAssertTrue(more)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM logs"), rowCount - 200, "一次清理最多处理200条旧日志")
        let legacyPageStart = ContinuousClock.now
        let legacyPage = try await fixture.store.diagnosticLogsPage()
        print("旧诊断尚有约 \(rowCount - 200) 条时读取首批 \(legacyPage.items.count) 条：\(legacyPageStart.duration(to: .now))")
        XCTAssertEqual(legacyPage.items.count, 50)
        try fixture.plan("SELECT id,created_at,last_seen_at,substr(message,1,1024),level,event_code,repeat_count FROM logs WHERE (created_at,id)<(?,?) ORDER BY created_at DESC,id DESC LIMIT ?", expectedIndex: "idx_logs_page")
        var batches = 1
        while try await fixture.store.trimDiagnosticLogsBatch() {
            batches += 1
            XCTAssertLessThan(batches, rowCount / 200 + 5)
        }
        print("旧诊断 \(rowCount) 条整理到 200 条：\(cleanupStart.duration(to: .now))，每批最多 200 条")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM logs"), 200)
        XCTAssertLessThanOrEqual(try fixture.scalar("SELECT MAX(length(message)) FROM logs"), 1024)
        try await fixture.store.log("同步未完成。测试网络暂不可用")
        try await fixture.store.log("同步未完成。测试网络暂不可用")
        try await fixture.store.log("同步未完成。测试网络暂不可用")
        let logPageStart = ContinuousClock.now
        let logs = try await fixture.store.diagnosticLogsPage()
        print("诊断首批 \(logs.items.count) 条：\(logPageStart.duration(to: .now))")
        XCTAssertEqual(logs.items.count, 50)
        XCTAssertEqual(logs.items.first?.repeatCount, 3)
        XCTAssertEqual(logs.items.first?.level, "warning")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM logs"), 200)
        let second = try await fixture.store.diagnosticLogsPage(after: logs.nextCursor)
        let previous = try await fixture.store.diagnosticLogsPage(before: second.previousCursor)
        XCTAssertEqual(previous.items.map(\.id), logs.items.map(\.id))
        let overview = try await fixture.store.syncOverview()
        XCTAssertEqual(overview.pendingCount, 1)
        XCTAssertEqual(overview.conflictCount, 1)
        XCTAssertEqual(overview.commandCount, 1)
        let saved = try await fixture.store.record(record.id)
        XCTAssertEqual(saved?.payload, record.payload)
        let detail = try await fixture.store.conflict(record.id)
        XCTAssertEqual(detail?.remote?.id, record.id)
        let photoURL = await fixture.store.photoURL(photoId)
        XCTAssertEqual(try Data(contentsOf: photoURL), photo)

        // 仅诊断的时间保留策略生效，旧业务数据和待执行队列仍然保留。
        try fixture.execute("INSERT INTO logs(id,created_at,message) VALUES('expired-fixture',?,'应过期的诊断')", [TimeFormat.iso(Date().addingTimeInterval(-15 * 86400))])
        try await fixture.store.trimDiagnosticLogsBatch()
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM logs WHERE id='expired-fixture'"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM records"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(change_id) FROM outbox"), 1)
    }
}
