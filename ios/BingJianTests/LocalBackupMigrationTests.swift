import Foundation
import XCTest
@testable import BingJian

final class LocalBackupMigrationTests: XCTestCase {
    func testManifestFailuresDoNotPublishOrphansOrDamageEarlierBackupsAndRetrySucceeds() async throws {
        let store = try LocalDatabase(namespace: "backup-publish-" + UUID().uuidString.lowercased())
        let directory = await store.directory
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let backup = LocalBackupService(directory: root, password: "fixture-backup-password")
        var record = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70))
        try await store.save(record, deviceId: "fixture")
        let original = try await backup.create(store: store)
        let published = root.appendingPathComponent(directory.lastPathComponent)
        #if os(iOS) && !targetEnvironment(simulator)
        for suffix in [".bjar", ".json"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: published.appendingPathComponent(original.id + suffix).path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete, "正常发布必须保留完整文件保护")
        }
        #elseif targetEnvironment(simulator)
        print("模拟器不提供真机文件保护属性；本例验证发布/回滚，完整保护等级需在真机验收")
        #endif
        let originalFiles = Set(try FileManager.default.contentsOfDirectory(atPath: published.path))
        record.payload["weight_kg"] = .number(69)
        try await store.save(record, deviceId: "fixture")
        for failBeforeWrite in [true, false] {
            let failing = LocalBackupService(directory: root, password: "fixture-backup-password", writeManifest: { data, url in
                if failBeforeWrite { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: [.atomic])
                // 文件系统真实返回移动源不存在，覆盖归档已移动后清单发布失败的回滚分支。
                try FileManager.default.removeItem(at: url)
            })
            for _ in 0..<2 {
                do { _ = try await failing.create(store: store); XCTFail("清单失败不能返回已发布备份") }
                catch { XCTAssertTrue(error is CocoaError) }
                let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: published.path).filter { $0 != "status.json" })
                XCTAssertEqual(remaining, originalFiles, "失败重试不得增加孤包或删除旧备份")
                let old = try await backup.open(original, store: store)
                XCTAssertEqual(old.records.first?.payload.number("weight_kg"), 70)
                try FileManager.default.removeItem(at: old.temporaryDirectory)
            }
        }
        let retried = try await backup.create(store: store)
        let recovered = try await backup.open(retried, store: store)
        defer { try? FileManager.default.removeItem(at: recovered.temporaryDirectory) }
        XCTAssertEqual(recovered.records.first?.payload.number("weight_kg"), 69)
        let entries = try await backup.entries(namespace: directory.lastPathComponent)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.id == original.id })
    }

    func testBackupRetainsSevenVerifiedVersionsAndCannotCrossNamespace() async throws {
        let store = try LocalDatabase(namespace: "backup-fixture-" + UUID().uuidString.lowercased())
        let directory = await store.directory
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let backup = LocalBackupService(directory: root, password: "fixture-backup-password")
        let empty = try await backup.create(store: store)
        XCTAssertEqual(empty.recordCount, 0)
        var record = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70))
        for index in 0..<9 {
            record.payload["note"] = .string("修订 \(index)")
            try await store.save(record, deviceId: "fixture")
            let created = try await backup.create(store: store, force: index != 0)
            XCTAssertEqual(created.recordCount, 1, "空版本不能让首次真实记录等待六小时")
        }
        let entries = try await backup.entries(namespace: directory.lastPathComponent)
        XCTAssertEqual(entries.count, 7)
        let latest = try XCTUnwrap(entries.first)
        let contents = try await backup.open(latest, store: store)
        defer { try? FileManager.default.removeItem(at: contents.temporaryDirectory) }
        XCTAssertEqual(contents.records.first?.payload.text("note"), "修订 8")
        let other = try LocalDatabase(namespace: "backup-other-" + UUID().uuidString.lowercased())
        let otherDirectory = await other.directory
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        do { _ = try await backup.open(latest, store: other); XCTFail("不能跨空间恢复") }
        catch { XCTAssertEqual((error as? APIError)?.code, "BACKUP_IDENTITY") }
    }

    func testAutomaticBackupKeepsMissingPhotoReferenceButFullExportRejectsIt() async throws {
        let store = try LocalDatabase(namespace: "backup-missing-" + UUID().uuidString.lowercased())
        let directory = await store.directory
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: root) }
        let photo = UUID().uuidString.lowercased()
        let record = try AppRecord(kind: "meal", day: "2026-11-19", value: MealEntry(photoIds: [photo]))
        try await store.save(record, deviceId: "fixture")
        let backup = LocalBackupService(directory: root, password: "fixture-backup-password")
        let entry = try await backup.create(store: store)
        XCTAssertEqual(entry.missingPhotoCount, 1)
        let opened = try await backup.open(entry, store: store)
        defer { try? FileManager.default.removeItem(at: opened.temporaryDirectory) }
        XCTAssertEqual(opened.records.first?.payload.strings("photo_ids"), [photo])
        XCTAssertEqual(opened.manifest.strings("missing_photo_ids"), [photo])
        do {
            _ = try await LocalArchive.export(store: store, password: "fixture-backup-password", includePhotos: true, userId: "fixture")
            XCTFail("完整导出不能隐瞒缺图")
        } catch { XCTAssertEqual((error as? APIError)?.code, "MISSING_PHOTO") }
    }

    func testMigrationStableMappingAndPhotoEvidenceRemainLinked() throws {
        let photo = UUID().uuidString.lowercased(), mealId = UUID().uuidString.lowercased()
        var meal = MealEntry(items: [FoodItem(name: "测试食物")], photoIds: [photo])
        meal.aiTaskId = "old-task"
        meal.items[0].evidencePhotoIds = [photo]
        let record = try AppRecord(kind: "meal", day: "2026-11-19", value: meal, id: mealId)
        let favorite = try AppRecord(kind: "favorite", day: "2026-11-19", value: FavoriteFood(name: "测试收藏", food: meal.items[0]))
        let source = ArchiveContents(records: [record, favorite], photos: [ArchivePhoto(id: photo, mealId: mealId, url: URL(fileURLWithPath: "/fixture"))],
                                     temporaryDirectory: URL(fileURLWithPath: "/fixture"), manifest: ["source_binding": .string("old:owner")])
        let plan = try LocalMigration.plan(source, target: [], targetBinding: "cloud:owner")
        let migrated = try XCTUnwrap(plan.contents.records.first)
        let migratedMeal = try XCTUnwrap(migrated.decode(MealEntry.self))
        XCTAssertNotEqual(migrated.id, record.id)
        XCTAssertEqual(plan.contents.photos.first?.mealId, migrated.id)
        XCTAssertEqual(migratedMeal.photoIds, migratedMeal.items[0].evidencePhotoIds)
        XCTAssertNil(migratedMeal.aiTaskId)
        let migratedFavorite = try XCTUnwrap(plan.contents.records.first { $0.kind == "favorite" }?.decode(FavoriteFood.self))
        XCTAssertEqual(migratedFavorite.food.evidencePhotoIds, migratedMeal.photoIds)
        let second = try LocalMigration.plan(source, target: plan.contents.records, targetBinding: "cloud:owner")
        XCTAssertEqual(second.identicalCount, 2)
        XCTAssertEqual(second.newCount, 0)
        XCTAssertEqual(second.contents.records.first?.id, migrated.id)
        let other = try LocalMigration.plan(source, target: [], targetBinding: "cloud:other")
        XCTAssertNotEqual(other.contents.records.first?.id, migrated.id)
    }

    func testRestoreKeepsCurrentDeletionAndRejectsConcurrentTargetEdits() async throws {
        let store = try LocalDatabase(namespace: "restore-fixture-" + UUID().uuidString.lowercased())
        let directory = await store.directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 70))
        try await store.save(original, deviceId: "fixture")
        let preview = try await store.allRecords()
        let contents = ArchiveContents(records: [original], photos: [], temporaryDirectory: directory)
        var removed = original
        removed.deletedAt = TimeFormat.iso()
        try await store.save(removed, deviceId: "fixture")
        do {
            _ = try await store.importArchive(contents, preferIncoming: true, restoreDeleted: false, deviceId: "fixture", expectedRecords: preview)
            XCTFail("预览后变化必须要求重新确认")
        } catch { XCTAssertEqual((error as? APIError)?.code, "MIGRATION_TARGET_CHANGED") }
        let count = try await store.importArchive(contents, preferIncoming: true, restoreDeleted: false, deviceId: "fixture")
        XCTAssertEqual(count, 0)
        let saved = try await store.record(original.id)
        XCTAssertNotNil(saved?.deletedAt)
        var archivedDeletion = original
        archivedDeletion.id = UUID().uuidString.lowercased()
        archivedDeletion.deletedAt = TimeFormat.iso()
        let deletedPackage = ArchiveContents(records: [archivedDeletion], photos: [], temporaryDirectory: directory)
        _ = try await store.importArchive(deletedPackage, preferIncoming: false, restoreDeleted: false, deviceId: "fixture", preserveDeletionMarkers: true)
        let restoredMarker = try await store.record(archivedDeletion.id)
        XCTAssertNotNil(restoredMarker?.deletedAt, "备份中的删除标记不能作为活跃记录导入")
    }

    func testBoundLocalSourceCannotBeReadWithoutPasswordArchive() async throws {
        let store = try LocalDatabase(namespace: "migration-bound-" + UUID().uuidString.lowercased())
        let directory = await store.directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.setMetadata("bound_user", value: "server:other-account")
        let source = LocalMigrationSource(id: directory.lastPathComponent, binding: "server:other-account", recordCount: 0, firstDay: "", lastDay: "")
        do { _ = try await LocalMigration.snapshot(source); XCTFail("目录可见不代表来源账号授权") }
        catch { XCTAssertEqual((error as? APIError)?.code, "MIGRATION_SOURCE") }
    }

    func testMigrationPersistsPhotosAndVersionRestoresBusinessDataWithoutOldGrants() async throws {
        let source = try LocalDatabase(namespace: "migration-source-" + UUID().uuidString.lowercased())
        let target = try LocalDatabase(namespace: "migration-target-" + UUID().uuidString.lowercased())
        let sourceDirectory = await source.directory, targetDirectory = await target.directory
        let backupRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
            try? FileManager.default.removeItem(at: backupRoot)
        }
        let mealID = UUID().uuidString.lowercased(), photoID = UUID().uuidString.lowercased()
        // 合成字节只核对备份附件的完整性；真实 JPEG 另由跨语言验收验证。
        let photoBytes = Data((0..<100_000).map { UInt8($0 % 251) })
        var food = FoodItem(name: "虚构迁移餐食")
        food.evidencePhotoIds = [photoID]
        var meal = MealEntry(items: [food], photoIds: [photoID])
        meal.note = "迁移前的备注"
        meal.aiTaskId = "synthetic-old-task"
        let original = try AppRecord(kind: "meal", day: "2026-11-19", value: meal, id: mealID)
        let weight = try AppRecord(kind: "weight", day: "2026-11-19", value: WeightEntry(weightKg: 72.35))
        let favorite = try AppRecord(kind: "favorite", day: "2026-11-19", value: FavoriteFood(name: "虚构收藏", food: food))
        try await source.savePhoto(photoBytes, id: photoID, mealId: mealID)
        for record in [original, weight, favorite] { try await source.save(record, deviceId: "fixture") }
        let sourceInfo = LocalMigrationSource(id: sourceDirectory.lastPathComponent,
            binding: "local:" + sourceDirectory.lastPathComponent, recordCount: 3, firstDay: "2026-11-19", lastDay: "2026-11-19")
        let snapshot = try await LocalMigration.snapshot(sourceInfo)
        defer { try? FileManager.default.removeItem(at: snapshot.temporaryDirectory) }
        let binding = "synthetic-cloud:synthetic-owner"
        try await target.setMetadata("bound_user", value: binding)
        let plan = try LocalMigration.plan(snapshot, target: [], targetBinding: binding)
        let imported = try await target.importArchive(plan.contents, preferIncoming: false, restoreDeleted: false,
            deviceId: "fixture", preserveDeletionMarkers: true, expectedRecords: plan.expectedTarget)
        XCTAssertEqual(imported, 3)
        let persisted = try await target.allRecords()
        let savedMeal = try XCTUnwrap(persisted.first { $0.kind == "meal" })
        let content = try XCTUnwrap(savedMeal.decode(MealEntry.self))
        XCTAssertNotEqual(savedMeal.id, mealID)
        XCTAssertNil(content.aiTaskId)
        XCTAssertEqual(content.photoIds, content.items[0].evidencePhotoIds)
        let targetPhoto = await target.photoURL(try XCTUnwrap(content.photoIds.first))
        XCTAssertEqual(try Data(contentsOf: targetPhoto), photoBytes)
        XCTAssertEqual(persisted.first { $0.kind == "weight" }?.decode(WeightEntry.self)?.weightKg, 72.35)
        XCTAssertEqual(persisted.first { $0.kind == "favorite" }?.decode(FavoriteFood.self)?.food.evidencePhotoIds, content.photoIds)
        let repeated = try LocalMigration.plan(snapshot, target: persisted, targetBinding: binding)
        XCTAssertEqual(repeated.identicalCount, 3)
        let duplicateCount = try await target.importArchive(repeated.contents, preferIncoming: false, restoreDeleted: false,
            deviceId: "fixture", preserveDeletionMarkers: true, expectedRecords: repeated.expectedTarget)
        XCTAssertEqual(duplicateCount, 0)

        try await target.setMetadata("fixture_old_grant", value: "must-not-return")
        try await target.enqueueCommand(path: "/shares/fixture", method: "PUT", body: ["fixture": .bool(true)])
        let backups = LocalBackupService(directory: backupRoot, password: "fixture-backup-password")
        let version = try await backups.create(store: target)
        XCTAssertEqual(version.recordCount, 3)
        XCTAssertEqual(version.photoCount, 1)
        try await target.clearLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPhoto.path))
        let recovery = try await backups.open(version, store: target)
        defer { try? FileManager.default.removeItem(at: recovery.temporaryDirectory) }
        let restored = try await target.importArchive(recovery, preferIncoming: true, restoreDeleted: false,
            deviceId: "fixture", preserveDeletionMarkers: true, expectedRecords: [])
        XCTAssertEqual(restored, 3)
        let recovered = try await target.allRecords()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0.payload) }),
                       Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0.payload) }))
        XCTAssertEqual(try Data(contentsOf: targetPhoto), photoBytes)
        let commands = try await target.pendingCommands()
        let oldGrant = try await target.metadata("fixture_old_grant")
        let currentBinding = try await target.metadata("bound_user")
        XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(oldGrant)
        XCTAssertEqual(currentBinding, binding)
        let unchangedSource = try await source.record(mealID)
        let sourcePhoto = await source.photoURL(photoID)
        XCTAssertEqual(unchangedSource?.payload, original.payload)
        XCTAssertEqual(try Data(contentsOf: sourcePhoto), photoBytes)
    }
}
