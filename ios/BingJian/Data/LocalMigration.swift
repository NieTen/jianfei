import CryptoKit
import Foundation
import SQLite3

struct LocalMigrationSource: Identifiable, Sendable {
    var id: String
    var binding: String
    var recordCount: Int
    var firstDay: String
    var lastDay: String
}

struct LocalMigrationPlan: Sendable {
    var contents: ArchiveContents
    var sourceBinding: String
    var targetBinding: String
    var newCount: Int
    var identicalCount: Int
    var conflictCount: Int
    var deletedCount: Int
    var expectedTarget: [AppRecord]
    var firstDay: String
    var lastDay: String
    var samples: [AppRecord]
}

/// 迁移是显式复制业务内容，不修改源空间，也不转移会话、授权、任务或同步游标。
enum LocalMigration {
    static func sources(excluding namespace: String) async throws -> [LocalMigrationSource] {
        try await Task.detached(priority: .utility) {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BingJian")
            return try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).compactMap { root in
                guard root.lastPathComponent != namespace, root.resolvingSymlinksInPath().deletingLastPathComponent() == base.resolvingSymlinksInPath(),
                      FileManager.default.fileExists(atPath: root.appendingPathComponent("records.sqlite3").path) else { return nil }
                var connection: OpaquePointer?
                guard sqlite3_open_v2(root.appendingPathComponent("records.sqlite3").path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                    sqlite3_close(connection); return nil
                }
                defer { sqlite3_close(connection) }
                let binding = try rows(connection, "SELECT value FROM metadata WHERE key='bound_user'").first?.first ?? nil
                // 设备持有旧目录不等于已获该账号授权，已绑定来源须提供原账号导出的密码归档。
                guard binding == nil else { return nil }
                let summary = try rows(connection, "SELECT COUNT(id),MIN(business_date),MAX(business_date) FROM records WHERE json_extract(document,'$.deleted_at') IS NULL").first ?? []
                guard summary.count == 3, let count = Int(summary[0] ?? "0"), count > 0 else { return nil }
                return LocalMigrationSource(id: root.lastPathComponent, binding: "local:" + root.lastPathComponent,
                                            recordCount: count, firstDay: summary[1] ?? "", lastDay: summary[2] ?? "")
            }
        }.value
    }

    static func snapshot(_ source: LocalMigrationSource) async throws -> ArchiveContents {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BingJian")
        let root = base.appendingPathComponent(source.id).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == base.resolvingSymlinksInPath(), source.binding == "local:" + source.id else { throw invalid() }
        return try await LocalSnapshotReader.read(directory: root,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            includePhotos: true, includeDeleted: true, allowMissingPhotos: false, requireUnbound: true)
    }

    static func plan(_ source: ArchiveContents, target: [AppRecord], targetBinding: String) throws -> LocalMigrationPlan {
        let sourceBinding = source.manifest.text("source_binding", fallback: "archive:" + source.manifest.text("user_id"))
        guard !targetBinding.isEmpty, sourceBinding != targetBinding, sourceBinding != "archive:" else { throw invalid() }
        let targetById = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
        var sourceIndex: [String: AppRecord] = [:]
        for record in target {
            if let sourceId = record.sourceId { sourceIndex[record.kind + ":" + sourceId] = record }
        }
        var mapping: [String: String] = [:], photoMapping: [String: String] = [:]
        let prefix = "migration-v1|" + sourceBinding + "|" + targetBinding
        for record in source.records {
            mapping[record.id] = record.sourceId.flatMap { sourceIndex[record.kind + ":" + $0]?.id }
                ?? stableID(prefix + "|record|" + record.id)
        }
        for photo in source.photos { photoMapping[photo.id] = stableID(prefix + "|photo|" + photo.id) }
        var incoming: [AppRecord] = []
        var newCount = 0, identicalCount = 0, conflictCount = 0, deletedCount = 0
        var firstDay = "", lastDay = "", samples: [AppRecord] = []
        for original in source.records {
            var record = original
            record.id = mapping[original.id]!
            record.version = 0
            record.deviceId = ""
            if record.kind == "meal", var meal = record.decode(MealEntry.self) {
                meal.photoIds = meal.photoIds.compactMap { photoMapping[$0] }
                for index in meal.items.indices { meal.items[index].evidencePhotoIds = meal.items[index].evidencePhotoIds.compactMap { photoMapping[$0] } }
                meal.aiTaskId = nil
                meal.aiResult = nil
                record.payload = try Codec.object(meal)
            }
            if record.kind == "favorite", var favorite = record.decode(FavoriteFood.self) {
                favorite.food.evidencePhotoIds = favorite.food.evidencePhotoIds.compactMap { photoMapping[$0] }
                record.payload = try Codec.object(favorite)
            }
            if record.deletedAt != nil || targetById[record.id]?.deletedAt != nil { deletedCount += 1 }
            else if let old = targetById[record.id] {
                if old.payload == record.payload { identicalCount += 1 } else { conflictCount += 1 }
            } else { newCount += 1 }
            incoming.append(record)
            if record.deletedAt == nil {
                if firstDay.isEmpty || record.businessDate < firstDay { firstDay = record.businessDate }
                if lastDay.isEmpty || record.businessDate > lastDay { lastDay = record.businessDate }
                if samples.count < 5 { samples.append(record) }
            }
        }
        let photos = source.photos.map { photo in
            ArchivePhoto(id: photoMapping[photo.id]!, mealId: mapping[photo.mealId] ?? photo.mealId, url: photo.url)
        }
        return LocalMigrationPlan(contents: ArchiveContents(records: incoming, photos: photos, temporaryDirectory: source.temporaryDirectory,
                                                            manifest: source.manifest), sourceBinding: sourceBinding, targetBinding: targetBinding,
                                  newCount: newCount, identicalCount: identicalCount, conflictCount: conflictCount, deletedCount: deletedCount,
                                  expectedTarget: target, firstDay: firstDay, lastDay: lastDay, samples: samples)
    }

    static func stableID(_ value: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }.joined(separator: "-")
    }

    private static func rows(_ connection: OpaquePointer?, _ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw invalid() }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw invalid() }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
    }

    private static func invalid() -> APIError {
        APIError(code: "MIGRATION_SOURCE", message: "迁移来源或目标身份无效，请重新选择；不能迁移到同一空间")
    }
}
