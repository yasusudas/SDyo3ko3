import Foundation
import SQLite3

/// Confined to the engine actor / its serial task; no UI or image data in the database.
final class HashIndex {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init() throws {
        let path = try FileSystem.appSupport().appendingPathComponent("index.sqlite3").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ImportError.message("索引を開けません。") }
        sqlite3_busy_timeout(db, 3000)
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS hashes (key TEXT PRIMARY KEY, stamp TEXT NOT NULL, sample TEXT, digest TEXT);"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db);db=nil
            let suffix=".corrupt-"+UUID().uuidString
            for ext in ["", "-wal", "-shm"] {
                let file=URL(fileURLWithPath:path+ext)
                if FileManager.default.fileExists(atPath:file.path){try FileManager.default.moveItem(at:file,to:URL(fileURLWithPath:path+ext+suffix))}
            }
            guard sqlite3_open_v2(path,&db,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,
                  sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw ImportError.message("索引を再構築できません。")}
            sqlite3_busy_timeout(db,3000)
        }
    }
    deinit { sqlite3_close(db) }
    func lookup(_ key: String, stamp: FileStamp) -> (String?, String?)? {
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db,"SELECT sample,digest FROM hashes WHERE key=? AND stamp=?",-1,&q,nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(q,1,key,-1,transient); sqlite3_bind_text(q,2,signature(stamp),-1,transient)
        guard sqlite3_step(q) == SQLITE_ROW else { return nil }
        func value(_ col: Int32) -> String? { sqlite3_column_text(q,col).map { String(cString:$0) } }
        return (value(0),value(1))
    }
    func save(_ key: String, stamp: FileStamp, sample: String?, digest: String?) {
        var q: OpaquePointer?; defer { sqlite3_finalize(q) }
        guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO hashes(key,stamp,sample,digest) VALUES(?,?,?,?)",-1,&q,nil) == SQLITE_OK else { return }
        for (i,v) in [key,signature(stamp),sample,digest].enumerated() {
            if let v { sqlite3_bind_text(q,Int32(i+1),v,-1,transient) } else { sqlite3_bind_null(q,Int32(i+1)) }
        }
        sqlite3_step(q)
    }
    private func signature(_ s: FileStamp) -> String { "v1|\(s.size)|\(s.modified)|\(s.changed)|\(s.fileID)" }
}
