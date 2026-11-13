import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 游标只保存排序边界；前后翻页不缓存已经浏览过的所有记录。
struct LocalPageCursor: Equatable, Sendable {
    var value: String
    var id: String
    var priority: Int = 0
}

struct LocalPage<Element: Sendable>: Sendable {
    var items: [Element] = []
    var previousCursor: LocalPageCursor?
    var nextCursor: LocalPageCursor?
}

struct LocalSyncOverview: Sendable {
    var pendingCount = 0
    var failedCount = 0
    var conflictCount = 0
    var commandCount = 0
    var logCount = 0
    var lastSync: String?
}

struct LocalDiagnosticLog: Identifiable, Sendable {
    var id: String
    var createdAt: String
    var lastSeenAt: String
    var message: String
    var level: String
    var eventCode: String
    var repeatCount: Int
    var cursor: LocalPageCursor { LocalPageCursor(value: createdAt, id: id) }
}

struct LocalFailedRecord: Identifiable, Sendable {
    var id: String
    var entityId: String
    var message: String
    var createdAt: String
    var cursor: LocalPageCursor { LocalPageCursor(value: createdAt, id: id) }
}

struct LocalCommandSummary: Identifiable, Sendable {
    var id: String
    var path: String
    var method: String
    var priority: Int
    var createdAt: String
    var cursor: LocalPageCursor { LocalPageCursor(value: createdAt, id: id, priority: priority) }
}

struct LocalConflictSummary: Identifiable, Sendable {
    var id: String
    var kind: String
    var businessDate: String
    var message: String
    var cursor: LocalPageCursor { LocalPageCursor(value: "", id: id) }
}

struct LocalWeightRow: Identifiable, Sendable {
    var record: AppRecord
    var weight: WeightEntry
    var id: String { record.id }
    var cursor: LocalPageCursor { LocalPageCursor(value: record.businessDate, id: id) }
}

/// 按本地身份隔离的 SQLite 存储；actor 串行化访问，事务保证记录与待发变更一起落库。
/// 同步回执、冲突、游标也在这里保存；不要绕过此层直接改 UI 内存数组冒充已保存。
actor LocalDatabase {
    private var connection: OpaquePointer?
    private var statusIndexesReady = false
    private var diagnosticSchemaReady = false
    private var diagnosticCleanupRunning = false
    private var weightIndexReady = false
    let directory: URL

    init(namespace: String) throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("BingJian", isDirectory: true).appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("media"), withIntermediateDirectories: true)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(resource)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        if sqlite3_open(directory.appendingPathComponent("records.sqlite3").path, &connection) != SQLITE_OK {
            throw APIError(code: "LOCAL_DATABASE", message: "本地数据库无法打开")
        }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, business_date TEXT NOT NULL, document TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_records_date ON records(kind,business_date);
        CREATE TABLE IF NOT EXISTS outbox(change_id TEXT PRIMARY KEY, entity_id TEXT NOT NULL, document TEXT NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL, error TEXT);
        CREATE INDEX IF NOT EXISTS idx_outbox_entity ON outbox(entity_id,created_at);
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conflicts(entity_id TEXT PRIMARY KEY, remote TEXT, message TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY, path TEXT NOT NULL, method TEXT NOT NULL, body TEXT NOT NULL, priority INTEGER NOT NULL, created_at TEXT NOT NULL, error TEXT);
        CREATE TABLE IF NOT EXISTS logs(id TEXT PRIMARY KEY, created_at TEXT NOT NULL, message TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, meal_id TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
        UPDATE outbox SET state='pending' WHERE state='inflight';
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            throw APIError(code: "LOCAL_MIGRATION", message: "本地数据库初始化失败")
        }
    }

    deinit { sqlite3_close(connection) }

    private func execute(_ sql: String, _ values: [String?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(values, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func query(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(values, statement)
        var result: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String?] = []
            for index in 0..<sqlite3_column_count(statement) {
                if let pointer = sqlite3_column_text(statement, index) { row.append(String(cString: pointer)) }
                else { row.append(nil) }
            }
            result.append(row)
        }
        return result
    }

    private func bind(_ values: [String?], _ statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
    }

    private func failure() -> APIError {
        APIError(code: "LOCAL_DATABASE", message: "本地数据操作失败，请检查剩余存储空间")
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func put(_ record: AppRecord) throws {
        try execute("INSERT INTO records(id,kind,business_date,document) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,business_date=excluded.business_date,document=excluded.document",
                    [record.id, record.kind, record.businessDate, try Codec.json(record)])
    }

    func allRecords() throws -> [AppRecord] {
        try query("SELECT document FROM records ORDER BY business_date DESC,id").compactMap { row in
            guard let value = row[0]?.data(using: .utf8) else { return nil }
            return try Codec.decoder().decode(AppRecord.self, from: value)
        }
    }

    private func pageSize(_ requested: Int) -> Int { min(100, max(1, requested)) }

    private func page<Element: Sendable>(_ rows: [Element], limit: Int, after: LocalPageCursor?,
                                         before: LocalPageCursor?, cursor: (Element) -> LocalPageCursor) -> LocalPage<Element> {
        let more = rows.count > limit
        var items = Array(rows.prefix(limit))
        if before != nil { items.reverse() }
        return LocalPage(items: items,
                         previousCursor: (before != nil ? more : after != nil) ? items.first.map(cursor) : nil,
                         nextCursor: (before != nil || more) ? items.last.map(cursor) : nil)
    }

    private func prepareStatusIndexes() throws {
        guard !statusIndexesReady else { return }
        // 在存储 actor 中建立索引，旧库升级不在 AppModel 的主线程构造过程中扫描大表。
        try execute("CREATE INDEX IF NOT EXISTS idx_outbox_state_page ON outbox(state,created_at DESC,change_id DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_commands_page ON commands(priority DESC,created_at,id)")
        statusIndexesReady = true
    }

    func syncOverview() throws -> LocalSyncOverview {
        try prepareStatusIndexes()
        let row = try query("""
        SELECT (SELECT COUNT(change_id) FROM outbox),
               (SELECT COUNT(change_id) FROM outbox WHERE state='failed'),
               (SELECT COUNT(entity_id) FROM conflicts),
               (SELECT COUNT(id) FROM commands),
               (SELECT COUNT(id) FROM logs),
               (SELECT value FROM metadata WHERE key='last_sync')
        """).first ?? []
        guard row.count == 6 else { throw failure() }
        return LocalSyncOverview(pendingCount: Int(row[0] ?? "0") ?? 0, failedCount: Int(row[1] ?? "0") ?? 0,
                                 conflictCount: Int(row[2] ?? "0") ?? 0, commandCount: Int(row[3] ?? "0") ?? 0,
                                 logCount: Int(row[4] ?? "0") ?? 0, lastSync: row[5])
    }

    func weightHistoryPage(showHidden: Bool = false, after: LocalPageCursor? = nil,
                           before: LocalPageCursor? = nil, limit: Int = 50) throws -> LocalPage<LocalWeightRow> {
        if !weightIndexReady {
            try execute("CREATE INDEX IF NOT EXISTS idx_records_page ON records(kind,business_date DESC,id DESC)")
            weightIndexReady = true
        }
        let size = pageSize(limit)
        var predicate = "kind='weight' AND json_extract(document,'$.deleted_at') IS NULL"
        if !showHidden {
            predicate += " AND COALESCE(json_extract(document,'$.payload.hidden'),0)=0 AND COALESCE(json_extract(document,'$.payload.source_deleted'),0)=0"
        }
        var values: [String?] = []
        if let boundary = before ?? after {
            predicate += before != nil ? " AND (business_date,id)>(?,?)" : " AND (business_date,id)<(?,?)"
            values += [boundary.value, boundary.id]
        }
        values.append(String(size + 1))
        let order = before != nil ? "business_date ASC,id ASC" : "business_date DESC,id DESC"
        let rows = try query("SELECT document FROM records WHERE \(predicate) ORDER BY \(order) LIMIT ?", values).map { row in
            let record = try Codec.decoder().decode(AppRecord.self, from: Data((row[0] ?? "{}").utf8))
            return LocalWeightRow(record: record, weight: try Codec.decode(WeightEntry.self, from: record.payload))
        }
        return page(rows, limit: size, after: after, before: before, cursor: { $0.cursor })
    }

    func failedRecordsPage(after: LocalPageCursor? = nil, before: LocalPageCursor? = nil,
                           limit: Int = 50) throws -> LocalPage<LocalFailedRecord> {
        try prepareStatusIndexes()
        let size = pageSize(limit)
        var predicate = "state='failed'"
        var values: [String?] = []
        if let boundary = before ?? after {
            predicate += before != nil ? " AND (created_at,change_id)>(?,?)" : " AND (created_at,change_id)<(?,?)"
            values += [boundary.value, boundary.id]
        }
        values.append(String(size + 1))
        let order = before != nil ? "created_at ASC,change_id ASC" : "created_at DESC,change_id DESC"
        let rows = try query("SELECT change_id,entity_id,error,created_at FROM outbox WHERE \(predicate) ORDER BY \(order) LIMIT ?", values).map {
            LocalFailedRecord(id: $0[0] ?? "", entityId: $0[1] ?? "", message: $0[2] ?? "请检查记录字段", createdAt: $0[3] ?? "")
        }
        return page(rows, limit: size, after: after, before: before, cursor: { $0.cursor })
    }

    func commandsPage(after: LocalPageCursor? = nil, before: LocalPageCursor? = nil,
                      limit: Int = 50) throws -> LocalPage<LocalCommandSummary> {
        try prepareStatusIndexes()
        let size = pageSize(limit)
        var predicate = "1=1"
        var values: [String?] = []
        if let boundary = before ?? after {
            predicate = before != nil
                ? "(priority>? OR (priority=? AND (created_at,id)<(?,?)))"
                : "(priority<? OR (priority=? AND (created_at,id)>(?,?)))"
            values += [String(boundary.priority), String(boundary.priority), boundary.value, boundary.id]
        }
        values.append(String(size + 1))
        let order = before != nil ? "priority ASC,created_at DESC,id DESC" : "priority DESC,created_at ASC,id ASC"
        let rows = try query("SELECT id,path,method,priority,created_at FROM commands WHERE \(predicate) ORDER BY \(order) LIMIT ?", values).map {
            LocalCommandSummary(id: $0[0] ?? "", path: $0[1] ?? "", method: $0[2] ?? "", priority: Int($0[3] ?? "0") ?? 0, createdAt: $0[4] ?? "")
        }
        return page(rows, limit: size, after: after, before: before, cursor: { $0.cursor })
    }

    func conflictsPage(after: LocalPageCursor? = nil, before: LocalPageCursor? = nil,
                       limit: Int = 50) throws -> LocalPage<LocalConflictSummary> {
        let size = pageSize(limit)
        var predicate = "1=1"
        var values: [String?] = []
        if let boundary = before ?? after {
            predicate = before != nil ? "c.entity_id<?" : "c.entity_id>?"
            values.append(boundary.id)
        }
        values.append(String(size + 1))
        let order = before != nil ? "DESC" : "ASC"
        let rows = try query("""
        SELECT c.entity_id,r.kind,r.business_date,c.message
        FROM conflicts c JOIN records r ON r.id=c.entity_id
        WHERE \(predicate) ORDER BY c.entity_id \(order) LIMIT ?
        """, values).map {
            LocalConflictSummary(id: $0[0] ?? "", kind: $0[1] ?? "", businessDate: $0[2] ?? "", message: $0[3] ?? "记录冲突")
        }
        return page(rows, limit: size, after: after, before: before, cursor: { $0.cursor })
    }

    /// 进入详情后才解码双方正文；摘要列表不逐行查询记录。
    func conflict(_ id: String) throws -> SyncConflict? {
        guard let row = try query("""
        SELECT c.entity_id,r.document,c.remote,c.message
        FROM conflicts c JOIN records r ON r.id=c.entity_id WHERE c.entity_id=?
        """, [id]).first else { return nil }
        let local = try Codec.decoder().decode(AppRecord.self, from: Data((row[1] ?? "{}").utf8))
        let remote = try row[2].map { try Codec.decoder().decode(AppRecord.self, from: Data($0.utf8)) }
        return SyncConflict(id: row[0] ?? id, local: local, remote: remote, message: row[3] ?? "记录冲突")
    }

    func record(_ id: String) throws -> AppRecord? {
        guard let text = try query("SELECT document FROM records WHERE id=?", [id]).first?[0],
              let data = text.data(using: .utf8) else { return nil }
        return try Codec.decoder().decode(AppRecord.self, from: data)
    }

    func save(_ records: [AppRecord], deviceId: String) throws {
        for record in records { try RecordValidator.validate(record) }
        // 首次引导中的档案和体重同时落库，避免只保存一半后退出引导。
        try transaction {
            for record in records { try saveValidated(record, deviceId: deviceId, sync: true) }
        }
    }

    func save(_ record: AppRecord, deviceId: String, sync: Bool = true, expectedPayload: JSONObject? = nil) throws {
        try RecordValidator.validate(record)
        try transaction {
            if var expected = expectedPayload {
                guard let current = try self.record(record.id), current.deletedAt == nil, current.kind == record.kind else {
                    throw APIError(code: "MEAL_VERSION_CHANGED", message: "这条记录已变化或删除，请重新确认识别结果")
                }
                var actual = current.payload
                // 任务状态可异步推进；识别确认只允许覆盖没有发生实质编辑的同一份餐次。
                for key in ["ai_task_id", "ai_result"] { expected.removeValue(forKey: key); actual.removeValue(forKey: key) }
                guard actual == expected else {
                    throw APIError(code: "MEAL_VERSION_CHANGED", message: "餐次已在识别期间修改，请重新确认识别结果")
                }
            }
            try saveValidated(record, deviceId: deviceId, sync: sync)
        }
    }

    private func saveValidated(_ record: AppRecord, deviceId: String, sync: Bool = true) throws {
            var value = record
            if let old = try self.record(value.id) { value.version = old.version }
            value.updatedAt = TimeFormat.iso()
            value.deviceId = deviceId
            try put(value)
            if sync {
                try execute("DELETE FROM outbox WHERE entity_id=? AND state IN ('pending','failed')", [value.id])
                let mutation = SyncMutation(changeId: UUID().uuidString.lowercased(), entityId: value.id,
                    kind: value.kind, businessDate: value.businessDate, payload: value.payload,
                    sourceId: value.sourceId, baseVersion: value.version, deletedAt: value.deletedAt)
                try execute("INSERT INTO outbox(change_id,entity_id,document,state,created_at) VALUES(?,?,?,'pending',?)",
                            [mutation.changeId, value.id, try Codec.json(mutation), TimeFormat.iso()])
            }
    }

    // 同一实体的较早变更未处理时，后续变更不能越过它；取出后标记为发送中以等待逐条回执。
    func nextBatch() throws -> [SyncMutation] {
        try transaction {
            let rows = try query("SELECT o.document FROM outbox o WHERE o.state='pending' AND NOT EXISTS(SELECT 1 FROM outbox p WHERE p.entity_id=o.entity_id AND p.created_at<o.created_at) ORDER BY o.created_at LIMIT 200")
            let values = try rows.compactMap { row -> SyncMutation? in
                guard let data = row[0]?.data(using: .utf8) else { return nil }
                return try Codec.decoder().decode(SyncMutation.self, from: data)
            }
            for value in values { try execute("UPDATE outbox SET state='inflight' WHERE change_id=?", [value.changeId]) }
            return values
        }
    }

    func acknowledge(changeId: String, remote: AppRecord) throws {
        try transaction {
            try execute("DELETE FROM outbox WHERE change_id=?", [changeId])
            let pending = try query("SELECT change_id,document FROM outbox WHERE entity_id=?", [remote.id])
            if pending.isEmpty { try put(remote) }
            else {
                if var current = try record(remote.id) {
                    current.version = remote.version
                    try put(current)
                }
                for row in pending {
                    guard let id = row[0], let data = row[1]?.data(using: .utf8) else { continue }
                    var mutation = try Codec.decoder().decode(SyncMutation.self, from: data)
                    mutation.baseVersion = remote.version
                    try execute("UPDATE outbox SET document=? WHERE change_id=?", [try Codec.json(mutation), id])
                }
            }
        }
    }

    func resetInflight() throws { try execute("UPDATE outbox SET state='pending' WHERE state='inflight'") }

    func reject(changeId: String, message: String, retryable: Bool) throws {
        try execute("UPDATE outbox SET state=?,error=? WHERE change_id=?", [retryable ? "pending" : "failed", message, changeId])
    }

    func retryFailed() throws { try execute("UPDATE outbox SET state='pending',error=NULL WHERE state='failed'") }

    func failedRecords() throws -> [JSONObject] {
        try query("SELECT entity_id,error FROM outbox WHERE state='failed' ORDER BY created_at DESC LIMIT 100").map {
            ["entity_id": .string($0[0] ?? ""), "message": .string($0[1] ?? "请检查记录字段")]
        }
    }

    func addConflict(entityId: String, remote: AppRecord?, message: String) throws {
        let encoded = try remote.map { try Codec.json($0) }
        try execute("INSERT INTO conflicts(entity_id,remote,message) VALUES(?,?,?) ON CONFLICT(entity_id) DO UPDATE SET remote=excluded.remote,message=excluded.message",
                    [entityId, encoded, message])
        try execute("UPDATE outbox SET state='conflict' WHERE entity_id=?", [entityId])
    }

    func conflicts() throws -> [SyncConflict] {
        try query("SELECT entity_id,remote,message FROM conflicts").compactMap { row in
            guard let id = row[0], let local = try record(id) else { return nil }
            let remote = try row[1].map { try Codec.decoder().decode(AppRecord.self, from: Data($0.utf8)) }
            return SyncConflict(id: id, local: local, remote: remote, message: row[2] ?? "记录冲突")
        }
    }

    func resolve(_ conflict: SyncConflict, keepLocal: Bool, deviceId: String) throws {
        var createdFiles: [URL] = []
        do {
            try transaction {
                var local = conflict.local
                if keepLocal {
                    if conflict.remote?.deletedAt != nil || conflict.remote == nil {
                        local.id = UUID().uuidString.lowercased()
                        local.sourceId = nil
                        local.version = 0
                        local.deletedAt = nil
                        if var meal = local.decode(MealEntry.self), local.kind == "meal" {
                            var mappings: [String: String] = [:]
                            for id in meal.photoIds {
                                let newId = UUID().uuidString.lowercased()
                                let destination = photoURL(newId)
                                guard FileManager.default.fileExists(atPath: photoURL(id).path) else {
                                    throw APIError(code: "MISSING_PHOTO", message: "恢复餐次前请补齐本机照片，或先移除不可用照片")
                                }
                                try FileManager.default.copyItem(at: photoURL(id), to: destination)
                                createdFiles.append(destination)
                                mappings[id] = newId
                                try execute("INSERT INTO media(id,meal_id,uploaded) VALUES(?,?,0)", [newId, local.id])
                            }
                            meal.photoIds = meal.photoIds.compactMap { mappings[$0] }
                            meal.items = meal.items.map { original in
                                var item = original
                                item.evidencePhotoIds = item.evidencePhotoIds.compactMap { mappings[$0] }
                                return item
                            }
                            meal.aiTaskId = nil
                            meal.aiResult = nil
                            local.payload = try Codec.object(meal)
                        }
                        if var weight = local.decode(WeightEntry.self), local.kind == "weight" {
                            weight.source = "manual"
                            weight.sourceId = nil
                            weight.hidden = false
                            weight.sourceDeleted = false
                            local.payload = try Codec.object(weight)
                        }
                    } else { local.version = conflict.remote?.version ?? 0 }
                    try RecordValidator.validate(local)
                }
                try execute("DELETE FROM outbox WHERE entity_id=?", [conflict.id])
                try execute("DELETE FROM conflicts WHERE entity_id=?", [conflict.id])
                if let remote = conflict.remote { try put(remote) }
                else { try execute("DELETE FROM records WHERE id=?", [conflict.id]) }
                if keepLocal { try saveValidated(local, deviceId: deviceId) }
            }
        } catch {
            for file in createdFiles { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    func applyRemote(_ values: [AppRecord], cursor: String?) throws {
        try transaction {
            for value in values {
                let pending = try query("SELECT change_id FROM outbox WHERE entity_id=? LIMIT 1", [value.id])
                if !pending.isEmpty, let local = try record(value.id) {
                    if value.version > local.version {
                        try addConflict(entityId: value.id, remote: value, message: "另一设备修改了这条记录")
                    }
                } else { try put(value) }
            }
            if let cursor { try setMetadata("sync_cursor", value: cursor) }
        }
    }

    func metadata(_ key: String) throws -> String? {
        try query("SELECT value FROM metadata WHERE key=?", [key]).first?[0]
    }

    func setMetadata(_ key: String, value: String?) throws {
        if let value {
            try execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
        } else { try execute("DELETE FROM metadata WHERE key=?", [key]) }
    }

    func setMetadataBatch(_ values: [String: String]) throws {
        try transaction {
            for (key, value) in values { try setMetadata(key, value: value) }
        }
    }

    func metadataPrefix(_ prefix: String) throws -> [String: String] {
        let rows = try query("SELECT key,value FROM metadata WHERE key LIKE ?", [prefix + "%"])
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let key = row[0], let value = row[1] else { return nil }
            return (key, value)
        })
    }

    func pendingCount() throws -> Int {
        Int(try query("SELECT COUNT(change_id) FROM outbox").first?[0] ?? "0") ?? 0
    }

    func savePhoto(_ data: Data, id: String, mealId: String) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: mealId) != nil else {
            throw APIError(code: "INVALID_PHOTO_ID", message: "照片标识无效")
        }
        try data.write(to: photoURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try execute("INSERT INTO media(id,meal_id,uploaded) VALUES(?,?,0) ON CONFLICT(id) DO UPDATE SET meal_id=excluded.meal_id",
                    [id, mealId])
    }

    func photoURL(_ id: String) -> URL {
        let safeId = UUID(uuidString: id)?.uuidString.lowercased() ?? "_invalid"
        return directory.appendingPathComponent("media").appendingPathComponent(safeId + ".jpg")
    }

    func pendingPhotos() throws -> [(String, String, URL)] {
        try query("SELECT id,meal_id FROM media WHERE uploaded=0").compactMap { row in
            guard let id = row[0], let mealId = row[1] else { return nil }
            return (id, mealId, photoURL(id))
        }
    }

    func photoUploaded(_ id: String) throws { try execute("UPDATE media SET uploaded=1 WHERE id=?", [id]) }

    func enqueueCommand(path: String, method: String, body: JSONObject, priority: Int = 0) throws {
        try transaction {
            if path.hasSuffix("/consent") {
                for row in try query("SELECT id,body FROM commands WHERE path=?", [path]) {
                    let previous = try JSONDecoder().decode(JSONObject.self, from: Data((row[1] ?? "{}").utf8))
                    if previous.text("recipient_id") == body.text("recipient_id") {
                        try execute("DELETE FROM commands WHERE id=?", [row[0]])
                    }
                }
            }
            try execute("INSERT INTO commands(id,path,method,body,priority,created_at) VALUES(?,?,?,?,?,?)",
                    [UUID().uuidString.lowercased(), path, method, try Codec.json(body), String(priority), TimeFormat.iso()])
        }
    }

    func pendingCommands() throws -> [JSONObject] {
        try query("SELECT id,path,method,body,priority FROM commands ORDER BY priority DESC,created_at").map { row in
            ["id": .string(row[0] ?? ""), "path": .string(row[1] ?? ""), "method": .string(row[2] ?? ""),
             "body": .object(try JSONDecoder().decode(JSONObject.self, from: Data((row[3] ?? "{}").utf8))),
             "priority": .number(Double(row[4] ?? "0") ?? 0)]
        }
    }

    func removeCommand(_ id: String) throws { try execute("DELETE FROM commands WHERE id=?", [id]) }

    private func prepareDiagnosticSchema() throws {
        guard !diagnosticSchemaReady else { return }
        let columns = Set(try query("PRAGMA table_info(logs)").compactMap { $0[1] })
        for (name, definition) in [
            ("level", "TEXT NOT NULL DEFAULT 'info'"),
            ("event_code", "TEXT NOT NULL DEFAULT 'diagnostic'"),
            ("repeat_count", "INTEGER NOT NULL DEFAULT 1"),
            ("last_seen_at", "TEXT NOT NULL DEFAULT ''")
        ] where !columns.contains(name) {
            try execute("ALTER TABLE logs ADD COLUMN \(name) \(definition)")
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_logs_page ON logs(created_at DESC,id DESC)")
        diagnosticSchemaReady = true
    }

    func log(_ message: String) throws {
        try prepareDiagnosticSchema()
        // 限制单条体积，并合并短时间内连续出现的相同诊断；不改变原始排序时间。
        let text = String(message.prefix(1024))
        let warning = text.contains("未完成") || text.contains("等待连接") || text.contains("尚未提交")
        let event = text.hasPrefix("同步结果") ? "sync_summary" : (warning ? "operation_waiting" : "diagnostic")
        let timestamp = TimeFormat.iso()
        let cutoff = TimeFormat.iso(Date().addingTimeInterval(-300))
        try transaction {
            let previous = try query("SELECT id,substr(message,1,1024),last_seen_at,created_at FROM logs ORDER BY created_at DESC,id DESC LIMIT 1").first
            if let previous, previous[1] == text, (previous[2].flatMap { $0.isEmpty ? nil : $0 } ?? previous[3] ?? "") >= cutoff {
                try execute("UPDATE logs SET repeat_count=repeat_count+1,last_seen_at=? WHERE id=?", [timestamp, previous[0]])
            } else {
                try execute("INSERT INTO logs(id,created_at,message,level,event_code,repeat_count,last_seen_at) VALUES(?,?,?,?,?,1,?)",
                            [UUID().uuidString.lowercased(), timestamp, text, warning ? "warning" : "info", event, timestamp])
            }
        }
        if try trimDiagnosticLogsBatch() { scheduleDiagnosticCleanup() }
    }

    /// 一次至多删除 200 条；仅处理诊断表，绝不取消待发变更、冲突或离线命令。
    @discardableResult
    func trimDiagnosticLogsBatch() throws -> Bool {
        try prepareDiagnosticSchema()
        return try transaction {
            let cutoff = TimeFormat.iso(Date().addingTimeInterval(-14 * 24 * 60 * 60))
            try execute("DELETE FROM logs WHERE id IN (SELECT id FROM logs WHERE created_at<? ORDER BY created_at,id LIMIT 200)", [cutoff])
            let expired = Int(sqlite3_changes(connection))
            var removed = expired
            if expired < 200, let boundary = try query("SELECT created_at,id FROM logs ORDER BY created_at DESC,id DESC LIMIT 1 OFFSET 199").first {
                try execute("DELETE FROM logs WHERE id IN (SELECT id FROM logs WHERE (created_at,id)<(?,?) ORDER BY created_at,id LIMIT ?)",
                            [boundary[0], boundary[1], String(200 - expired)])
                removed += Int(sqlite3_changes(connection))
            }
            try execute("UPDATE logs SET message=substr(message,1,1024) WHERE id IN (SELECT id FROM (SELECT id,message FROM logs ORDER BY created_at DESC,id DESC LIMIT 200) WHERE length(message)>1024)")
            return removed == 200
        }
    }

    private func scheduleDiagnosticCleanup() {
        guard !diagnosticCleanupRunning else { return }
        diagnosticCleanupRunning = true
        Task { [weak self] in await self?.finishDiagnosticCleanup() }
    }

    private func finishDiagnosticCleanup() async {
        defer { diagnosticCleanupRunning = false }
        do {
            while !Task.isCancelled, try trimDiagnosticLogsBatch() {
                // 每批释放事务与 actor，让记录保存、查询和取消先获得执行机会。
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            // 下次写入或打开日志会重试；不递归写日志制造新的清理任务。
        }
    }

    func diagnosticLogsPage(after: LocalPageCursor? = nil, before: LocalPageCursor? = nil,
                            limit: Int = 50) throws -> LocalPage<LocalDiagnosticLog> {
        try prepareDiagnosticSchema()
        let size = pageSize(limit)
        var predicate = "1=1"
        var values: [String?] = []
        if let boundary = before ?? after {
            predicate = before != nil ? "(created_at,id)>(?,?)" : "(created_at,id)<(?,?)"
            values += [boundary.value, boundary.id]
        }
        values.append(String(size + 1))
        let order = before != nil ? "created_at ASC,id ASC" : "created_at DESC,id DESC"
        let rows = try query("SELECT id,created_at,last_seen_at,substr(message,1,1024),level,event_code,repeat_count FROM logs WHERE \(predicate) ORDER BY \(order) LIMIT ?", values).map {
            LocalDiagnosticLog(id: $0[0] ?? "", createdAt: $0[1] ?? "", lastSeenAt: ($0[2]?.isEmpty == false ? $0[2] : $0[1]) ?? "",
                               message: $0[3] ?? "", level: $0[4] ?? "info", eventCode: $0[5] ?? "diagnostic", repeatCount: Int($0[6] ?? "1") ?? 1)
        }
        scheduleDiagnosticCleanup()
        return page(rows, limit: size, after: after, before: before, cursor: { $0.cursor })
    }

    func logs() throws -> [(String, String)] {
        try diagnosticLogsPage(limit: 100).items.map { ($0.lastSeenAt, $0.message) }
    }

    func beginSnapshot() throws {
        try setMetadata("snapshot_seen", value: "[]")
    }

    func finishSnapshot(cursor: String, seen: Set<String>) throws {
        try transaction {
            for value in try allRecords() where !seen.contains(value.id) {
                let dirty = try query("SELECT change_id FROM outbox WHERE entity_id=? LIMIT 1", [value.id])
                if dirty.isEmpty { try execute("DELETE FROM records WHERE id=?", [value.id]) }
                else if value.version > 0 {
                    try addConflict(entityId: value.id, remote: nil, message: "服务器已移除这条记录，可选择另存为新记录")
                }
            }
            try setMetadata("sync_cursor", value: cursor)
        }
    }

    func clearLocalData() throws {
        try transaction {
            for table in ["records", "outbox", "conflicts", "media", "logs"] {
                try execute("DELETE FROM " + table + " WHERE 1=1")
            }
            try execute("DELETE FROM metadata WHERE key!='bound_user'")
            try execute("DELETE FROM commands WHERE priority<100")
            try setMetadata("sync_cursor", value: nil)
            try setMetadata("health_disabled_after_delete", value: "true")
        }
        let photos = directory.appendingPathComponent("media")
        for url in try FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func importArchive(_ contents: ArchiveContents, preferIncoming: Bool, restoreDeleted: Bool, deviceId: String) throws -> Int {
        for record in contents.records { try RecordValidator.validate(record) }
        var createdFiles: [URL] = []
        var imported = 0
        do {
            try transaction {
                var mealMappings: [String: String] = [:]
                var photoMappings: [String: String] = [:]
                var importedMeals = Set<String>()
                for original in contents.records {
                    let existing = try record(original.id)
                    if existing != nil && !preferIncoming { continue }
                    var value = original
                    if existing?.deletedAt != nil {
                        guard restoreDeleted else { continue }
                        value.id = UUID().uuidString.lowercased()
                        value.sourceId = nil
                        value.deletedAt = nil
                        if value.kind == "weight", var weight = value.decode(WeightEntry.self) {
                            weight.source = "manual"
                            weight.sourceId = nil
                            weight.hidden = false
                            weight.sourceDeleted = false
                            value.payload = try Codec.object(weight)
                        }
                        if value.kind == "meal", var meal = value.decode(MealEntry.self) {
                            mealMappings[original.id] = value.id
                            for id in meal.photoIds {
                                photoMappings[id] = photoMappings[id] ?? UUID().uuidString.lowercased()
                            }
                            meal.photoIds = meal.photoIds.compactMap { photoMappings[$0] }
                            meal.items = meal.items.map { original in
                                var item = original
                                item.evidencePhotoIds = item.evidencePhotoIds.compactMap { photoMappings[$0] }
                                return item
                            }
                            meal.aiTaskId = nil
                            meal.aiResult = nil
                            value.payload = try Codec.object(meal)
                        }
                    }
                    if value.kind == "meal" { importedMeals.insert(value.id) }
                    value.version = value.id == original.id ? existing?.version ?? 0 : 0
                    value.deviceId = deviceId
                    value.updatedAt = TimeFormat.iso()
                    try put(value)
                    try execute("DELETE FROM outbox WHERE entity_id=? AND state!='inflight'", [value.id])
                    let mutation = SyncMutation(changeId: UUID().uuidString.lowercased(), entityId: value.id, kind: value.kind,
                        businessDate: value.businessDate, payload: value.payload, sourceId: value.sourceId,
                        baseVersion: value.version, deletedAt: nil)
                    try execute("INSERT INTO outbox(change_id,entity_id,document,state,created_at) VALUES(?,?,?,'pending',?)",
                                [mutation.changeId, value.id, try Codec.json(mutation), TimeFormat.iso()])
                    imported += 1
                }
                for photo in contents.photos {
                    let mealId = mealMappings[photo.mealId] ?? photo.mealId
                    guard importedMeals.contains(mealId) else { continue }
                    let photoId = photoMappings[photo.id] ?? photo.id
                    let target = photoURL(photoId)
                    if FileManager.default.fileExists(atPath: target.path) {
                        if try LocalArchive.digest(target) != LocalArchive.digest(photo.url) {
                            throw APIError(code: "PHOTO_CONFLICT", message: "同一照片标识的内容不同，请先处理照片冲突")
                        }
                    } else {
                        try FileManager.default.copyItem(at: photo.url, to: target)
                        createdFiles.append(target)
                    }
                    try execute("INSERT INTO media(id,meal_id,uploaded) VALUES(?,?,0) ON CONFLICT(id) DO UPDATE SET meal_id=excluded.meal_id,uploaded=0",
                                [photoId, mealId])
                }
            }
            return imported
        } catch {
            for url in createdFiles { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
