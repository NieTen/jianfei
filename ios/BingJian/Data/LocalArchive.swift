import CommonCrypto
import CryptoKit
import Foundation
import Security

struct ArchivePhoto: Sendable {
    var id: String
    var mealId: String
    var url: URL
}

struct ArchiveContents: Sendable {
    var records: [AppRecord]
    var photos: [ArchivePhoto]
    var temporaryDirectory: URL
}

enum LocalArchive {
    private static let magic = Data("BJAR2".utf8)
    private static let chunkSize = 64 * 1024

    static func export(store: LocalDatabase, password: String, includePhotos: Bool, userId: String) async throws -> URL {
        guard password.count >= 10 else { throw APIError(code: "ARCHIVE_PASSWORD", message: "导出密码至少需要 10 位") }
        let records = try await store.allRecords().filter { $0.deletedAt == nil }
        var photos: [ArchivePhoto] = []
        if includePhotos {
            var seen = Set<String>()
            for record in records where record.kind == "meal" {
                for id in record.decode(MealEntry.self)?.photoIds ?? [] where !seen.contains(id) {
                    let url = await store.photoURL(id)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw APIError(code: "MISSING_PHOTO", message: "部分照片尚未下载，请先查看照片或选择不包含照片")
                    }
                    photos.append(ArchivePhoto(id: id, mealId: record.id, url: url))
                    seen.insert(id)
                }
            }
        }
        let savedPhotos = photos
        return try await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let plain = root.appendingPathComponent("records.plain")
            let destination = root.appendingPathComponent("并肩记录-\(TimeFormat.day()).bjar")
            try createFile(plain)
            let output = try FileHandle(forWritingTo: plain)
            do {
                let manifest = try JSONEncoder().encode(["schema_version": JSONValue.number(1), "user_id": .string(userId),
                    "exported_at": .string(TimeFormat.iso()), "includes_photos": .bool(includePhotos)])
                try frame(output, metadata: ["type": .string("manifest"), "length": .number(Double(manifest.count))], data: manifest)
                for record in records {
                    let data = try Codec.encoder().encode(record)
                    try frame(output, metadata: ["type": .string("entity"), "length": .number(Double(data.count))], data: data)
                }
                for photo in savedPhotos {
                    let attributes = try FileManager.default.attributesOfItem(atPath: photo.url.path)
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                    try frameHeader(output, metadata: ["type": .string("photo"), "id": .string(photo.id),
                        "meal_id": .string(photo.mealId), "length": .number(Double(size)), "sha256": .string(try digest(photo.url))])
                    let source = try FileHandle(forReadingFrom: photo.url)
                    defer { try? source.close() }
                    while let data = try source.read(upToCount: chunkSize), !data.isEmpty { try output.write(contentsOf: data) }
                }
                try frame(output, metadata: ["type": .string("end"), "length": .number(0)], data: Data())
                try output.close()
                try encrypt(plain, to: destination, password: password)
                try FileManager.default.removeItem(at: plain)
                return destination
            } catch {
                try? output.close()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }.value
    }

    static func open(_ source: URL, password: String) async throws -> ArchiveContents {
        try await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let plain = root.appendingPathComponent("decrypted")
            do {
                try decrypt(source, to: plain, password: password)
                let input = try FileHandle(forReadingFrom: plain)
                defer { try? input.close() }
                var records: [AppRecord] = []
                var photos: [ArchivePhoto] = []
                var recordIds = Set<String>()
                var photoIds = Set<String>()
                var hasManifest = false
                while true {
                    let headerLength = Int(try uint32(readExact(input, 4)))
                    guard headerLength <= 64 * 1024 else { throw corrupt() }
                    let metadata = try JSONDecoder().decode(JSONObject.self, from: readExact(input, headerLength))
                    let size = Int(metadata.number("length") ?? -1)
                    guard size >= 0 && size <= 15 * 1024 * 1024 else { throw corrupt() }
                    if metadata.text("type") == "end" {
                        guard size == 0, hasManifest, (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw corrupt() }
                        break
                    }
                    let data = try readExact(input, size)
                    switch metadata.text("type") {
                    case "manifest":
                        let manifest = try JSONDecoder().decode(JSONObject.self, from: data)
                        guard manifest.number("schema_version") == 1 else { throw corrupt() }
                        hasManifest = true
                    case "entity":
                        let record = try Codec.decoder().decode(AppRecord.self, from: data)
                        guard UUID(uuidString: record.id) != nil, supportedKinds.contains(record.kind) else { throw corrupt() }
                        try RecordValidator.validate(record)
                        guard recordIds.insert(record.id).inserted else { throw corrupt() }
                        records.append(record)
                    case "photo":
                        let id = metadata.text("id")
                        guard UUID(uuidString: id) != nil, UUID(uuidString: metadata.text("meal_id")) != nil,
                              photoIds.insert(id).inserted,
                              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.text("sha256") else { throw corrupt() }
                        let target = root.appendingPathComponent(id + ".jpg")
                        try data.write(to: target, options: [.atomic, .completeFileProtection])
                        photos.append(ArchivePhoto(id: id, mealId: metadata.text("meal_id"), url: target))
                    default: throw corrupt()
                    }
                }
                try FileManager.default.removeItem(at: plain)
                return ArchiveContents(records: records, photos: photos, temporaryDirectory: root)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw APIError(code: "ARCHIVE_INVALID", message: "导入包无法解密或校验，请检查密码与文件完整性")
            }
        }.value
    }

    private static let supportedKinds: Set<String> = ["profile", "weight", "meal", "daily_status", "goal", "health_day", "measurement", "workout", "food_preference", "favorite"]

    static func digest(_ path: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        var output = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { bytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &output, 32)
            }
        }
        guard status == kCCSuccess else { throw corrupt() }
        return SymmetricKey(data: output)
    }

    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw corrupt() }
        return Data(bytes)
    }

    private static func encrypt(_ source: URL, to destination: URL, password: String) throws {
        let salt = try random(16)
        let prefix = try random(8)
        let header = magic + salt + prefix
        let key = try key(password, salt: salt)
        try createFile(destination)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: header)
        var counter: UInt32 = 0
        while true {
            let data = try input.read(upToCount: chunkSize) ?? Data()
            let encoded = bigEndian(counter)
            let sealed = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: prefix + encoded), authenticating: header + encoded)
            let ciphertext = sealed.ciphertext + sealed.tag
            try output.write(contentsOf: bigEndian(UInt32(ciphertext.count)))
            try output.write(contentsOf: ciphertext)
            counter += 1
            if data.isEmpty { break }
        }
    }

    private static func decrypt(_ source: URL, to destination: URL, password: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        try createFile(destination)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        let header = try readExact(input, 29)
        guard header.prefix(5) == magic else { throw corrupt() }
        let prefix = Data(header[21..<29])
        let key = try key(password, salt: Data(header[5..<21]))
        var counter: UInt32 = 0
        var total = 0
        while true {
            let size = Int(try uint32(readExact(input, 4)))
            guard size >= 16 && size <= chunkSize + 16 else { throw corrupt() }
            let cipher = try readExact(input, size)
            let encoded = bigEndian(counter)
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: prefix + encoded),
                                              ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: header + encoded)
            counter += 1
            if plaintext.isEmpty {
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw corrupt() }
                break
            }
            total += plaintext.count
            guard total <= 4 * 1024 * 1024 * 1024 else { throw corrupt() }
            try output.write(contentsOf: plaintext)
        }
    }

    private static func frameHeader(_ output: FileHandle, metadata: JSONObject) throws {
        let data = try JSONEncoder().encode(metadata)
        try output.write(contentsOf: bigEndian(UInt32(data.count)))
        try output.write(contentsOf: data)
    }

    private static func frame(_ output: FileHandle, metadata: JSONObject, data: Data) throws {
        try frameHeader(output, metadata: metadata)
        try output.write(contentsOf: data)
    }

    private static func createFile(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw APIError(code: "DISK_FULL", message: "无法创建导出文件，请检查剩余空间")
        }
    }

    private static func readExact(_ input: FileHandle, _ count: Int) throws -> Data {
        let data = try input.read(upToCount: count) ?? Data()
        guard data.count == count else { throw corrupt() }
        return data
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private static func uint32(_ data: Data) -> UInt32 { data.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func corrupt() -> APIError { APIError(code: "ARCHIVE_INVALID", message: "归档内容或密码无效") }
}
