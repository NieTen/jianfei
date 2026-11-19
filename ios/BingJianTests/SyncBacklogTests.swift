import Foundation
import XCTest
@testable import BingJian

/// 只用本机 TCP、随机测试库与内存凭据；不读取真实 Keychain 或连接配置中的云服务。
private actor SyncBacklogProbe {
    var commands: [String] = []
    var photos: [String] = []
    var pulls = 0
    var failPath: String?
    var failureUsed = false

    init(failPath: String? = nil) { self.failPath = failPath }

    func response(_ request: LocalHTTPRequest) -> LocalHTTPResponse {
        if request.path == "/api/v1/capabilities" {
            return reply("{\"instance_id\":\"fixture-instance\",\"epoch\":\"fixture-epoch\"}")
        }
        if request.path.hasPrefix("/api/v1/fixture/") {
            if request.path == failPath, !failureUsed {
                failureUsed = true
                return reply("{\"code\":\"TEMPORARY\",\"message\":\"模拟短暂断网\",\"retryable\":true}", status: 503)
            }
            commands.append(request.path)
            return reply("{}")
        }
        if request.path == "/api/v1/media/upload-init" {
            let body = (try? JSONDecoder().decode(JSONObject.self, from: request.body)) ?? [:]
            photos.append(body.text("id"))
            return reply("{\"status\":\"ready\",\"received_size\":0}")
        }
        if request.path.hasPrefix("/api/v1/sync/pull") {
            pulls += 1
            return reply("{\"entities\":[],\"cursor\":\"fixture-cursor\",\"has_more\":false}")
        }
        return reply("{\"code\":\"UNEXPECTED_TEST_REQUEST\"}", status: 500)
    }

    private func reply(_ value: String, status: Int = 200) -> LocalHTTPResponse {
        LocalHTTPResponse(status: status, body: Data(value.utf8))
    }
}

private actor SyncBacklogGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class SyncBacklogSession {
    let api: APIClient
    private let defaults: UserDefaults
    private let name = "sync-backlog-" + UUID().uuidString.lowercased()

    init(port: UInt16) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("http://127.0.0.1:\(port)", forKey: "server_url")
        api = APIClient(defaults: defaults, persistCredentials: false)
    }

    deinit { defaults.removePersistentDomain(forName: name) }

    func prepare(_ store: LocalDatabase) async throws {
        try await api.setSession(SessionCredentials(accessToken: "fixture-access", refreshToken: "fixture-refresh",
            expiresIn: 3600, userId: "fixture-user", displayName: "测试", deviceId: "fixture-device",
            generation: 1, epoch: "fixture-epoch", instanceId: "fixture-instance"))
        try await store.setMetadata("bound_user", value: "fixture-instance:fixture-user")
        try await store.setMetadata("epoch", value: "fixture-epoch")
    }
}

final class SyncBacklogTests: XCTestCase {
    func testLargeExecutionQueriesOnlyDecodeBoundedBodiesAndEligiblePhotos() async throws {
        let fixture = try await LocalSQLiteFixture()
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<99999)
        INSERT INTO commands(id,path,method,body,priority,created_at)
        SELECT printf('command-%06d',n),'/fixture/'||n,'POST',
               CASE WHEN n=99999 THEN '本批次之外的损坏正文' ELSE json_object('ordinal',n) END,
               n%3,'2026-11-19T00:00:00Z' FROM numbers
        """)
        let start = ContinuousClock.now
        let first = try await fixture.store.pendingCommands(limit: 100_000)
        print("十万命令中执行正文首批 \(first.count) 条：\(start.duration(to: .now))")
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(first.map { $0["body"]?.object?.number("ordinal") }, (0..<100).map { Double(2 + 3 * $0) })
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM commands"), 100_000)
        try fixture.plan("SELECT id,path,method,body,priority FROM commands ORDER BY priority DESC,created_at,id LIMIT 50", expectedIndex: "idx_commands_page")

        let shared = try AppRecord(kind: "meal", day: "2026-11-19", value: MealEntry(syncPhotos: true))
        let local = try AppRecord(kind: "meal", day: "2026-11-19", value: MealEntry(syncPhotos: false))
        try await fixture.store.save(shared, deviceId: "fixture-device", sync: false)
        try await fixture.store.save(local, deviceId: "fixture-device", sync: false)
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<99999)
        INSERT INTO media(id,meal_id,uploaded)
        SELECT printf('photo-%06d',n),CASE WHEN n%1000=0 THEN ? ELSE ? END,0 FROM numbers
        """, [shared.id, local.id])
        let photoStart = ContinuousClock.now
        let photos = try await fixture.store.pendingPhotos()
        print("十万照片中筛选可同步首批 \(photos.items.count) 条：\(photoStart.duration(to: .now))")
        XCTAssertEqual(photos.items.map(\.id), (0..<50).map { String(format: "photo-%06d", $0 * 1000) })
        let remainder = try await fixture.store.pendingPhotos(after: photos.nextCursor)
        XCTAssertEqual(remainder.items.map(\.id), (50..<100).map { String(format: "photo-%06d", $0 * 1000) })
        XCTAssertNil(remainder.nextCursor)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM media WHERE uploaded=0"), 100_000,
                       "筛选或翻页不得将未授权照片标为已上传或删除")
        try fixture.plan("SELECT m.id,m.meal_id FROM media m JOIN records r ON r.id=m.meal_id WHERE m.uploaded=0 AND m.id>'photo-050000' ORDER BY m.id LIMIT 51", expectedIndex: "idx_media_pending")
    }

    func testSnapshotReconciliationUsesBatchesAndPreservesDirtyRecordsAcrossRestart() async throws {
        let fixture = try await LocalSQLiteFixture()
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<99999)
        INSERT INTO records(id,kind,business_date,document)
        SELECT printf('removed-%06d',n),'weight','2026-11-19','{"version":1}' FROM numbers
        """)
        // 大量旧正文故意不含完整封套，核对只需要id/version，不能重新解码全库。
        var dirty = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70))
        dirty.version = 3
        let local = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 71))
        let remote = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 72))
        let abandoned = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 73))
        try await fixture.store.save(dirty, deviceId: "fixture-device")
        try await fixture.store.save(local, deviceId: "fixture-device")
        let queues = try fixture.texts("SELECT change_id||document FROM outbox ORDER BY change_id")
        try await fixture.store.setMetadata("sync_cursor", value: "before-snapshot")
        try await fixture.store.beginSnapshot()
        try await fixture.store.applySnapshotPage([abandoned])
        let first = try await fixture.store.finishSnapshot(cursor: "must-not-commit", limit: 100_000)
        XCTAssertNotNil(first)
        let partialCursor = try await fixture.store.metadata("sync_cursor")
        XCTAssertEqual(partialCursor, "before-snapshot")
        XCTAssertGreaterThanOrEqual(try fixture.scalar("SELECT COUNT(id) FROM records"), 99_903,
                                    "一次核对的硬上限为100，不能在单次事务清理整库")

        // 模拟快照中途取消/重试：新集合不继承上一轮已见id。
        try await fixture.store.beginSnapshot()
        try await fixture.store.applySnapshotPage([remote])
        let cleanupStart = ContinuousClock.now
        var boundary: String?, batches = 0
        repeat {
            boundary = try await fixture.store.finishSnapshot(cursor: "complete-snapshot", after: boundary)
            batches += 1
            XCTAssertLessThan(batches, 1_010)
        } while boundary != nil
        print("十万旧记录快照核对 \(batches) 个有界事务：\(cleanupStart.duration(to: .now))")
        let finalCursor = try await fixture.store.metadata("sync_cursor")
        XCTAssertEqual(finalCursor, "complete-snapshot")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM records"), 3)
        let retained = try await fixture.store.allRecords()
        XCTAssertEqual(Set(retained.map(\.id)), Set([dirty.id, local.id, remote.id]))
        XCTAssertEqual(try fixture.texts("SELECT change_id||document FROM outbox ORDER BY change_id"), queues,
                       "冲突可调整队列状态，但不能丢弃变更正文或替换幂等标识")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(change_id) FROM outbox WHERE state='conflict'"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(change_id) FROM outbox WHERE state='pending'"), 1)
        let conflict = try await fixture.store.conflict(dirty.id)
        XCTAssertNotNil(conflict)
        XCTAssertNil(conflict?.remote)
        let localConflict = try await fixture.store.conflict(local.id)
        XCTAssertNil(localConflict, "从未上传的本地新增记录不应被当成服务器删除冲突")
    }

    func testCommandExecutionContinuesInPriorityOrderWithoutSkippingFailure() async throws {
        let fixture = try await LocalSQLiteFixture()
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<450)
        INSERT INTO commands(id,path,method,body,priority,created_at)
        SELECT printf('command-%06d',n),'fixture/'||n,'POST','{}',
               CASE WHEN n<10 THEN 100 ELSE 0 END,'2026-11-19T00:00:00Z' FROM numbers
        """)
        let probe = SyncBacklogProbe(failPath: "/api/v1/fixture/7")
        let server = try LocalHTTPTestServer(handler: { await probe.response($0) })
        defer { server.stop() }
        let session = try SyncBacklogSession(port: await server.start())
        try await session.prepare(fixture.store)
        let engine = SyncEngine(api: session.api, store: fixture.store)
        do { _ = try await engine.synchronize(); XCTFail("中途失败必须保留失败及其后的命令") }
        catch { XCTAssertEqual((error as? APIError)?.code, "TEMPORARY") }
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM commands"), 444)
        var calls = await probe.commands
        XCTAssertEqual(calls, (0..<7).map { "/api/v1/fixture/\($0)" })
        let earlyPulls = await probe.pulls
        XCTAssertEqual(earlyPulls, 0, "命令尚未完成时不得越过队列进入数据同步")

        let first = try await engine.synchronize()
        XCTAssertTrue(first.needsContinuation)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM commands"), 244)
        // 下一轮读取队首，刚加入的撤权优先于剩余普通命令。
        try await fixture.store.enqueueCommand(path: "fixture/new-revoke", method: "POST", body: [:], priority: 100)
        let second = try await engine.synchronize()
        XCTAssertTrue(second.needsContinuation)
        calls = await probe.commands
        XCTAssertEqual(calls[207], "/api/v1/fixture/new-revoke")
        let last = try await engine.synchronize()
        XCTAssertFalse(last.needsContinuation)
        calls = await probe.commands
        XCTAssertEqual(calls.filter { $0 != "/api/v1/fixture/new-revoke" }, (0...450).map { "/api/v1/fixture/\($0)" })
        XCTAssertEqual(Set(calls).count, 452)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM commands"), 0)
        let pulls = await probe.pulls
        XCTAssertEqual(pulls, 1)
    }

    func testPhotoExecutionContinuesPastMissingFilesWithoutDiscardingThem() async throws {
        let fixture = try await LocalSQLiteFixture()
        let meal = try AppRecord(kind: "meal", day: "2026-11-19", value: MealEntry(syncPhotos: true))
        try await fixture.store.save(meal, deviceId: "fixture-device", sync: false)
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<200)
        INSERT INTO media(id,meal_id,uploaded) SELECT '00000000-0000-0000-0000-'||printf('%012d',n),?,0 FROM numbers
        """, [meal.id])
        let availablePhoto = "00000000-0000-0000-0000-000000000200"
        try await fixture.store.savePhoto(Data("fixture-photo".utf8), id: availablePhoto, mealId: meal.id)
        let probe = SyncBacklogProbe()
        let server = try LocalHTTPTestServer(handler: { await probe.response($0) })
        defer { server.stop() }
        let session = try SyncBacklogSession(port: await server.start())
        try await session.prepare(fixture.store)
        let engine = SyncEngine(api: session.api, store: fixture.store)
        let first = try await engine.synchronize()
        XCTAssertTrue(first.needsContinuation)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM media WHERE uploaded=0"), 201)
        let second = try await engine.synchronize()
        XCTAssertFalse(second.needsContinuation)
        let uploads = await probe.photos
        XCTAssertEqual(uploads, [availablePhoto], "缺文件条目不能让后面的可用照片永远得不到处理")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM media WHERE uploaded=0"), 200)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(id) FROM media"), 201)
    }

    func testCancellationKeepsTheUnacknowledgedCommandAndBlocksAnotherIdentity() async throws {
        let fixture = try await LocalSQLiteFixture()
        try await fixture.store.enqueueCommand(path: "fixture/held", method: "POST", body: ["preserve": .bool(true)])
        let before = try fixture.texts("SELECT id||body FROM commands ORDER BY id")
        let received = expectation(description: "命令已经发送，服务器尚未确认")
        let gate = SyncBacklogGate(), probe = SyncBacklogProbe()
        let server = try LocalHTTPTestServer(handler: { request in
            if request.path == "/api/v1/fixture/held" { received.fulfill(); await gate.wait() }
            return await probe.response(request)
        })
        defer { server.stop(); Task { await gate.release() } }
        let session = try SyncBacklogSession(port: await server.start())
        try await session.prepare(fixture.store)
        let engine = SyncEngine(api: session.api, store: fixture.store)
        let operation = Task { try await engine.synchronize() }
        await fulfillment(of: [received], timeout: 5)
        operation.cancel()
        let result = await operation.result
        await gate.release()
        if case .success = result { XCTFail("已取消的同步不能报告完成") }
        XCTAssertEqual(try fixture.texts("SELECT id||body FROM commands ORDER BY id"), before)

        try await session.api.setSession(SessionCredentials(accessToken: "other-access", refreshToken: "other-refresh",
            expiresIn: 3600, userId: "another-user", displayName: "另一个账号", deviceId: "other-device",
            generation: 1, epoch: "fixture-epoch", instanceId: "fixture-instance"))
        do { _ = try await engine.synchronize(); XCTFail("旧数据库不能由新账号继续发送") }
        catch { XCTAssertEqual((error as? APIError)?.code, "ACCOUNT_CHANGED") }
        XCTAssertEqual(try fixture.texts("SELECT id||body FROM commands ORDER BY id"), before)
    }
}
