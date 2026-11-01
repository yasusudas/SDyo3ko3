import Foundation
import SQLite3

struct HistoryLocation: Codable, Equatable, Sendable {
    var originalName: String
    var sourcePath: String?
    var destinationPath: String
    var captureFolder: String?
    var origin: String
}

struct HistoryRecord: Codable, Equatable, Sendable {
    var digest: String
    var size: Int64
    var originalName: String
    var sourcePath: String?
    var destinationPath: String
    var captureFolder: String?
    var recordedAt: Date
    var importedAt: Date?
    var origin: String
    var videoFingerprint: VideoFingerprint? = nil
    var additionalLocations: [HistoryLocation]? = nil

    var location: HistoryLocation {
        HistoryLocation(originalName: originalName, sourcePath: sourcePath, destinationPath: destinationPath, captureFolder: captureFolder, origin: origin)
    }

    func validated() throws {
        let locations = [location] + (additionalLocations ?? [])
        guard validSHA256(digest), size > 0, recordedAt.timeIntervalSince1970.isFinite,
              importedAt?.timeIntervalSince1970.isFinite != false, locations.count <= 10000,
              locations.allSatisfy({ !$0.originalName.isEmpty && !$0.destinationPath.isEmpty &&
                  [$0.originalName, $0.sourcePath ?? "", $0.destinationPath, $0.captureFolder ?? "", $0.origin].allSatisfy { $0.utf8.count <= 32768 && !$0.contains("\0") } }) else {
            throw ImportError.message("取り込み履歴に不正な記録があります。既存の履歴は保持します。")
        }
        try videoFingerprint?.validate()
    }

    func merging(_ other: HistoryRecord) throws -> HistoryRecord {
        guard digest == other.digest, size == other.size else { throw ImportError.message("異なる履歴は結合できません。") }
        if let a = videoFingerprint, let b = other.videoFingerprint, a.digest != b.digest || a.algorithm != b.algorithm {
            throw ImportError.message("同じファイルの動画ハッシュが競合しています。既存の履歴を保持して読み込みを停止しました。")
        }
        var result = self
        result.recordedAt = min(recordedAt, other.recordedAt)
        result.importedAt = [importedAt, other.importedAt].compactMap { $0 }.min()
        result.videoFingerprint = videoFingerprint ?? other.videoFingerprint
        var locations = additionalLocations ?? []
        for candidate in [other.location] + (other.additionalLocations ?? []) where candidate != location && !locations.contains(candidate) { locations.append(candidate) }
        result.additionalLocations = locations.isEmpty ? nil : locations
        try result.validated()
        return result
    }
}

struct HistoryArchive: Codable {
    var format = "yo3komi-history"
    var version = 1
    var exportedAt = Date()
    var records: [HistoryRecord]
}
struct HistorySummary: Sendable { var records: Int; var videos: Int }
struct HistoryMergeResult: Sendable { var added: Int; var merged: Int; var total: Int }

/// Authoritative records survive cache cleanup, moving media, and removal of the original destination.
/// Old JSON records remain readable. Pending merge journals recover interrupted multi-record imports.
final class ImportHistory {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let backup: URL
    private let merges: URL

    init(root: URL? = nil) throws {
        let root = try root ?? FileSystem.appSupport()
        backup = root.appendingPathComponent("HistoryRecords", isDirectory: true)
        merges = root.appendingPathComponent("HistoryMerges", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: merges, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.sqlite3")
        let existed = FileManager.default.fileExists(atPath: url.path)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ImportError.message("取り込み履歴を開けません。履歴を削除せず、アクセス権を確認してください。") }
        sqlite3_busy_timeout(db, 3000)
        var rebuilt = false
        let schema = "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS history(digest TEXT NOT NULL,size INTEGER NOT NULL,record BLOB NOT NULL,video_digest TEXT,PRIMARY KEY(digest,size)); CREATE INDEX IF NOT EXISTS history_size ON history(size);"
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil; rebuilt = true
            let suffix = ".damaged-" + UUID().uuidString
            for ext in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + ext) { try FileManager.default.moveItem(atPath: url.path + ext, toPath: url.path + ext + suffix) }
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ImportError.message("取り込み履歴を復旧できません。") }
            try execute(schema)
        }
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(history)", -1, &q, nil) == SQLITE_OK else { throw ImportError.message("履歴の形式を確認できません。") }
        var hasVideo = false
        while sqlite3_step(q) == SQLITE_ROW { if let name = sqlite3_column_text(q, 1), String(cString: name) == "video_digest" { hasVideo = true } }
        sqlite3_finalize(q)
        if !hasVideo { try execute("ALTER TABLE history ADD COLUMN video_digest TEXT") }
        try execute("CREATE INDEX IF NOT EXISTS history_video ON history(video_digest)")
        let files = try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let pending = try FileManager.default.contentsOfDirectory(at: merges, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        if existed, (rebuilt && files.isEmpty && pending.isEmpty || count() > files.count && pending.isEmpty) { throw ImportError.message("取り込み履歴の復旧用記録が見つかりません。履歴フォルダを確認してください。") }
        try execute("BEGIN IMMEDIATE")
        do {
            for file in files {
                let record = try JSONDecoder().decode(HistoryRecord.self, from: Data(contentsOf: file))
                try record.validated()
                guard file.deletingPathExtension().lastPathComponent == record.digest else { throw ImportError.message("履歴の復旧記録名が不正です。") }
                let combined = try lookup(record.digest, size: record.size).map { try $0.merging(record) } ?? record
                try insert(combined)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        for journal in pending {
            let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(contentsOf: journal))
            _ = try merge(records, journal: journal)
        }
    }
    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ImportError.message("取り込み履歴の保存・復旧に失敗しました。履歴は削除せず保持してください。") }
    }
    func hasSize(_ size: Int64) -> Bool {
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM history WHERE size=? LIMIT 1", -1, &q, nil) == SQLITE_OK else { return true }
        sqlite3_bind_int64(q, 1, size); return sqlite3_step(q) == SQLITE_ROW
    }
    func lookup(_ digest: String, size: Int64) throws -> HistoryRecord? { try find("SELECT record FROM history WHERE digest=? AND size=?", text: digest, size: size) }
    func lookupVideo(_ fingerprint: VideoFingerprint) throws -> HistoryRecord? { try find("SELECT record FROM history WHERE video_digest=? LIMIT 1", text: fingerprint.digest) }
    private func find(_ sql: String, text: String, size: Int64? = nil) throws -> HistoryRecord? {
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db, sql, -1, &q, nil) == SQLITE_OK else { throw ImportError.message("取り込み履歴の照合に失敗しました。") }
        sqlite3_bind_text(q, 1, text, -1, transient)
        if let size { sqlite3_bind_int64(q, 2, size) }
        let status = sqlite3_step(q)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(q, 0) else { throw ImportError.message("取り込み履歴を読み取れません。") }
        return try JSONDecoder().decode(HistoryRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(q, 0))))
    }
    func record(digest: String, size: Int64, name: String, source: URL?, destination: URL, folder: String?, origin: String, video: VideoFingerprint? = nil) throws {
        let record = HistoryRecord(digest: digest, size: size, originalName: name, sourcePath: source?.path, destinationPath: destination.path, captureFolder: folder, recordedAt: Date(), importedAt: origin == "verified-import" ? Date() : nil, origin: origin, videoFingerprint: video)
        try record.validated()
        let old = try find("SELECT record FROM history WHERE digest=? LIMIT 1", text: digest)
        let combined = try old.map { try $0.merging(record) } ?? record
        if combined == old { return }
        try saveRecovery(combined)
        try insert(combined)
    }
    private func saveRecovery(_ record: HistoryRecord) throws {
        try JSONEncoder().encode(record).write(to: backup.appendingPathComponent(record.digest + ".json"), options: .atomic)
    }
    private func insert(_ record: HistoryRecord) throws {
        let data = try JSONEncoder().encode(record)
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO history(digest,size,record,video_digest) VALUES(?,?,?,?)", -1, &q, nil) == SQLITE_OK else { throw ImportError.message("取り込み履歴を保存できません。") }
        sqlite3_bind_text(q, 1, record.digest, -1, transient); sqlite3_bind_int64(q, 2, record.size)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(q, 3, $0.baseAddress, Int32(data.count), transient) }
        if let video = record.videoFingerprint { sqlite3_bind_text(q, 4, video.digest, -1, transient) } else { sqlite3_bind_null(q, 4) }
        guard sqlite3_step(q) == SQLITE_DONE else { throw ImportError.message("取り込み履歴を保存できません。コピー済みファイルを残して停止します。") }
    }
    func count() -> Int { (try? summary().records) ?? 0 }
    func summary() throws -> HistorySummary {
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db, "SELECT count(*),count(video_digest) FROM history", -1, &q, nil) == SQLITE_OK, sqlite3_step(q) == SQLITE_ROW else { throw ImportError.message("取り込み履歴の件数を確認できません。") }
        return HistorySummary(records: Int(sqlite3_column_int64(q, 0)), videos: Int(sqlite3_column_int64(q, 1)))
    }
    private func allRecords() throws -> [HistoryRecord] {
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db, "SELECT record FROM history ORDER BY digest,size", -1, &q, nil) == SQLITE_OK else { throw ImportError.message("取り込み履歴を読み取れません。") }
        var result: [HistoryRecord] = []
        while true {
            let status = sqlite3_step(q)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(q, 0) else { throw ImportError.message("取り込み履歴を読み取れません。") }
            result.append(try JSONDecoder().decode(HistoryRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(q, 0)))))
        }
    }
    func exportFile(to url: URL) throws -> Int {
        let records = try allRecords()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(HistoryArchive(records: records)).write(to: url, options: .atomic)
        return records.count
    }
    func importFile(from url: URL) throws -> HistoryMergeResult {
        guard try FileSystem.stamp(url).size <= 512 * 1024 * 1024 else { throw ImportError.message("履歴ファイルが大きすぎます（上限512MB）。") }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let archive: HistoryArchive
        do { archive = try decoder.decode(HistoryArchive.self, from: data) }
        catch { throw ImportError.message("yo3komiの履歴JSONを読み込めません。ファイルの形式を確認してください。") }
        guard archive.format == "yo3komi-history", archive.version == 1, archive.exportedAt.timeIntervalSince1970.isFinite else { throw ImportError.message("対応していない履歴ファイル形式です。既存の履歴は保持します。") }
        return try merge(archive.records)
    }
    private func merge(_ incoming: [HistoryRecord], journal: URL? = nil) throws -> HistoryMergeResult {
        guard incoming.count <= 1_000_000 else { throw ImportError.message("履歴の件数が多すぎます。") }
        var combined: [String: HistoryRecord] = [:]
        var sizes: [String: Int64] = [:]
        var added = 0
        // Validate and resolve every conflict before any persistent mutation.
        for record in incoming {
            try Task.checkCancellation()
            try record.validated()
            if let size = sizes[record.digest], size != record.size {
                throw ImportError.message("同じハッシュに異なるファイルサイズが記録されています。既存の履歴は保持します。")
            }
            sizes[record.digest] = record.size
            let key = record.digest + ":" + String(record.size)
            if let previous = combined[key] { combined[key] = try previous.merging(record) }
            else if let previous = try lookup(record.digest, size: record.size) { combined[key] = try previous.merging(record) }
            else {
                if try find("SELECT record FROM history WHERE digest=? LIMIT 1", text: record.digest) != nil {
                    throw ImportError.message("同じハッシュに異なるファイルサイズが記録されています。既存の履歴は保持します。")
                }
                combined[key] = record; added += 1
            }
        }
        let records = combined.values.sorted { $0.digest < $1.digest }
        if records.isEmpty { return HistoryMergeResult(added: 0, merged: 0, total: count()) }
        let pending = journal ?? merges.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(records).write(to: pending, options: .atomic)
        try execute("BEGIN IMMEDIATE")
        do { for record in records { try insert(record) }; try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
        // Journal stays until every recovery record is durable. Replaying it is idempotent.
        for record in records { try saveRecovery(record) }
        try FileManager.default.removeItem(at: pending)
        return HistoryMergeResult(added: added, merged: incoming.count - added, total: count())
    }
}
