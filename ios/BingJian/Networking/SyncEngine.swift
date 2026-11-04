import CryptoKit
import Foundation

struct SyncReport: Sendable {
    var uploaded = 0
    var downloaded = 0
    var conflicts = 0
    var failed = 0
}

actor SyncEngine {
    private let api: APIClient
    private let store: LocalDatabase
    private var running = false

    init(api: APIClient, store: LocalDatabase) {
        self.api = api
        self.store = store
    }

    func synchronize() async throws -> SyncReport {
        guard !running else { return SyncReport() }
        running = true
        defer { running = false }
        var report = SyncReport()
        do {
            guard let session = await api.currentSession() else { throw APIError(code: "AUTH_REQUIRED", message: "登录后可同步") }
            let capabilities = try await api.send("capabilities")
            guard let handshake = capabilities.object else { throw APIError(code: "INVALID_RESPONSE", message: "服务握手失败") }
            let oldGeneration = try await store.metadata("generation")
            if let oldGeneration, oldGeneration != String(session.generation) {
                throw APIError(code: "GENERATION_CHANGED", message: "服务器个人数据已重置，请在数据管理中确认清理本机旧副本后重新同步")
            }
            let knownInstance = try await store.metadata("instance_id")
            if let knownInstance, knownInstance != handshake.text("instance_id") {
                throw APIError(code: "SERVER_CHANGED", message: "服务器身份已变化，请确认迁移后重新建立同步")
            }
            try await sendCommands()
            let oldEpoch = try await store.metadata("epoch")
            if oldEpoch != handshake.text("epoch") {
                report.downloaded += try await restoreSnapshot()
            }
            try await store.setMetadata("instance_id", value: handshake.text("instance_id"))
            try await store.setMetadata("generation", value: String(session.generation))
            try await store.setMetadata("epoch", value: handshake.text("epoch"))
            try await uploadPhotos()
            while true {
                try Task.checkCancellation()
                let mutations = try await store.nextBatch()
                if mutations.isEmpty { break }
                let array = try mutations.map { JSONValue.object(try Codec.object($0)) }
                let response = try await api.send("sync/push", method: "POST", body: [
                    "epoch": .string(handshake.text("epoch")), "generation": .number(Double(session.generation)),
                    "changes": .array(array)
                ])
                let results = response.object?.objects("results") ?? []
                var shouldStop = false
                for result in results {
                    let changeId = result.text("change_id")
                    if ["accepted", "duplicate"].contains(result.text("status")),
                       let object = result["entity"]?.object {
                        try await store.acknowledge(changeId: changeId, remote: Codec.decode(AppRecord.self, from: object))
                        report.uploaded += 1
                    } else if result.text("status") == "conflict",
                              let mutation = mutations.first(where: { $0.changeId == changeId }) {
                        let remote = try result["entity"]?.object.map { try Codec.decode(AppRecord.self, from: $0) }
                        try await store.addConflict(entityId: mutation.entityId, remote: remote, message: result.text("message"))
                        report.conflicts += 1
                    } else {
                        try await store.reject(changeId: changeId, message: result.text("message"), retryable: result.flag("retryable"))
                        shouldStop = shouldStop || result.flag("retryable")
                        report.failed += 1
                    }
                }
                if results.count != mutations.count {
                    throw APIError(code: "INVALID_RESPONSE", message: "服务器缺少部分同步回执", retryable: true)
                }
                if shouldStop { break }
            }
            do { report.downloaded += try await pullChanges() }
            catch let error as APIError where error.code == "CURSOR_EXPIRED" || error.code == "EPOCH_CHANGED" {
                report.downloaded += try await restoreSnapshot()
            }
            try await store.setMetadata("last_sync", value: TimeFormat.iso())
            try await store.log("同步结果，上传 \(report.uploaded) 条，接收 \(report.downloaded) 条，失败 \(report.failed) 条，冲突 \(report.conflicts) 条")
            return report
        } catch {
            try? await store.resetInflight()
            try? await store.log("同步未完成。\(error.localizedDescription)")
            throw error
        }
    }

    private func sendCommands() async throws {
        for command in try await store.pendingCommands() {
            try Task.checkCancellation()
            var body = command["body"]?.object ?? [:]
            do {
                _ = try await api.send(command.text("path"), method: command.text("method"), body: body)
            } catch let error as APIError where error.code == "VERSION_CONFLICT" &&
                command.text("path").hasSuffix("/consent") && body.strings("scopes").isEmpty {
                let base = String(command.text("path").dropLast("/consent".count))
                let response = try await api.send(base + "/consents")
                let latest = response.array?.compactMap(\.object).first { $0.text("recipient_id") == body.text("recipient_id") }
                body["expected_version"] = .number(latest?.number("version") ?? 0)
                _ = try await api.send(command.text("path"), method: command.text("method"), body: body)
            }
            try await store.removeCommand(command.text("id"))
        }
    }

    private func uploadPhotos() async throws {
        for (id, mealId, url) in try await store.pendingPhotos() {
            try Task.checkCancellation()
            guard let record = try await store.record(mealId), record.deletedAt == nil,
                  let meal = record.decode(MealEntry.self), meal.syncPhotos,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            try await uploadPhoto(id: id, mealId: mealId, url: url, temporary: false)
        }
    }

    func uploadRecognitionPhotos(mealId: String, photoIds: [String]) async throws {
        for id in photoIds {
            try Task.checkCancellation()
            try await uploadPhoto(id: id, mealId: mealId, url: store.photoURL(id), temporary: true)
        }
    }

    private func uploadPhoto(id: String, mealId: String, url: URL, temporary: Bool) async throws {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let initialized = try await api.send("media/upload-init", method: "POST",
            body: ["id": .string(id), "meal_id": .string(mealId), "size": .number(Double(data.count)),
                   "sha256": .string(hash), "mime_type": .string("image/jpeg"), "temporary": .bool(temporary)])
        var offset = Int(initialized.object?.number("received_size") ?? 0)
        var status = initialized.object?.text("status") ?? ""
        var attempts = 0
        while status != "ready" {
            try Task.checkCancellation()
            guard offset >= 0 && offset <= data.count && attempts < 64 else {
                throw APIError(code: "IMAGE_UPLOAD", message: "图片上传偏移无效，请稍后重试", retryable: true)
            }
            let end = min(offset + 1024 * 1024, data.count)
            let responseData = try await api.request("media/\(id)", method: "PUT",
                data: data.subdata(in: offset..<end), query: ["offset": String(offset)], contentType: "application/octet-stream")
            let response = try JSONDecoder().decode(JSONObject.self, from: responseData)
            if response.text("status") == "hash_mismatch" {
                throw APIError(code: "IMAGE_HASH", message: "图片校验失败，请重试", retryable: true)
            }
            offset = Int(response.number("received_size") ?? Double(end))
            status = response.text("status")
            attempts += 1
        }
        if !temporary { try await store.photoUploaded(id) }
    }

    private func pullChanges() async throws -> Int {
        var total = 0
        while true {
            try Task.checkCancellation()
            var query: [String: String] = [:]
            if let cursor = try await store.metadata("sync_cursor") { query["cursor"] = cursor }
            let response = try await api.send("sync/pull", query: query)
            guard let object = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "同步结果无效") }
            let records = try object.objects("entities").map { try Codec.decode(AppRecord.self, from: $0) }
            try await store.applyRemote(records, cursor: object.text("cursor"))
            total += records.count
            if !object.flag("has_more") { return total }
        }
    }

    private func restoreSnapshot() async throws -> Int {
        let response = try await api.send("sync/snapshots", method: "POST", body: [:])
        guard let snapshot = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "快照创建失败") }
        let snapshotId = snapshot.text("snapshot_id")
        var after = ""
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await api.send("sync/snapshots/\(snapshotId)", query: ["after": after])
            guard let object = page.object else { throw APIError(code: "INVALID_RESPONSE", message: "快照内容无效") }
            let records = try object.objects("entities").map { try Codec.decode(AppRecord.self, from: $0) }
            seen.formUnion(records.map(\.id))
            try await store.applyRemote(records, cursor: nil)
            after = object.text("after")
            if !object.flag("has_more") { break }
        }
        try await store.finishSnapshot(cursor: snapshot.text("cursor"), seen: seen)
        return seen.count
    }
}
