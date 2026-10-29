import Foundation
import SQLite3

struct HistoryRecord:Codable,Sendable {
    var digest:String
    var size:Int64
    var originalName:String
    var sourcePath:String?
    var destinationPath:String
    var captureFolder:String?
    var recordedAt:Date
    var importedAt:Date?
    var origin:String
}
/// Authoritative history is independent of the disposable hash cache and source/destination existence.
/// Every first-seen hash also has an atomic JSON recovery record.
final class ImportHistory {
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private let backup:URL
    init() throws {
        let root=try FileSystem.appSupport()
        backup=root.appendingPathComponent("HistoryRecords",isDirectory:true)
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("history.sqlite3")
        let existed=FileManager.default.fileExists(atPath:url.path)
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{throw ImportError.message("取り込み履歴を開けません。履歴を削除せず、アクセス権を確認してください。")}
        sqlite3_busy_timeout(db,3000)
        var rebuilt=false
        let sql="PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS history(digest TEXT NOT NULL,size INTEGER NOT NULL,record BLOB NOT NULL,PRIMARY KEY(digest,size)); CREATE INDEX IF NOT EXISTS history_size ON history(size);"
        if sqlite3_exec(db,sql,nil,nil,nil) != SQLITE_OK {
            sqlite3_close(db);db=nil;rebuilt=true
            let suffix=".damaged-"+UUID().uuidString
            for ext in ["","-wal","-shm"] where FileManager.default.fileExists(atPath:url.path+ext){try FileManager.default.moveItem(atPath:url.path+ext,toPath:url.path+ext+suffix)}
            guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw ImportError.message("取り込み履歴を復旧できません。")}
        }
        // Replay atomic recovery records, including the small crash window between JSON and SQLite.
        let files=try FileManager.default.contentsOfDirectory(at:backup,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
        if existed,(rebuilt && files.isEmpty || count()>files.count){throw ImportError.message("取り込み履歴の復旧用記録が見つかりません。履歴フォルダを確認してください。")}
        guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK else{throw ImportError.message("履歴の復旧を開始できません。") }
        for file in files {
            let record=try JSONDecoder().decode(HistoryRecord.self,from:Data(contentsOf:file))
            guard record.digest.count==64,record.digest.allSatisfy(\.isHexDigit),file.deletingPathExtension().lastPathComponent==record.digest else{throw ImportError.message("取り込み履歴の復旧記録が壊れています。履歴を保存したまま確認してください。")}
            try insert(record)
        }
        guard sqlite3_exec(db,"COMMIT",nil,nil,nil)==SQLITE_OK else{throw ImportError.message("履歴の復旧を確定できません。") }
    }
    deinit{sqlite3_close(db)}
    func hasSize(_ size:Int64)->Bool{
        var q:OpaquePointer?;defer{sqlite3_finalize(q)}
        guard sqlite3_prepare_v2(db,"SELECT 1 FROM history WHERE size=? LIMIT 1",-1,&q,nil)==SQLITE_OK else{return true}
        sqlite3_bind_int64(q,1,size);return sqlite3_step(q)==SQLITE_ROW
    }
    func lookup(_ digest:String,size:Int64)throws->HistoryRecord?{
        var q:OpaquePointer?;defer{sqlite3_finalize(q)}
        guard sqlite3_prepare_v2(db,"SELECT record FROM history WHERE digest=? AND size=?",-1,&q,nil)==SQLITE_OK else{throw ImportError.message("取り込み履歴の照合に失敗しました。")}
        sqlite3_bind_text(q,1,digest,-1,transient);sqlite3_bind_int64(q,2,size)
        let status=sqlite3_step(q)
        if status==SQLITE_DONE{return nil}
        guard status==SQLITE_ROW,let bytes=sqlite3_column_blob(q,0) else{throw ImportError.message("取り込み履歴を読み取れません。")}
        return try JSONDecoder().decode(HistoryRecord.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(q,0))))
    }
    func record(digest:String,size:Int64,name:String,source:URL?,destination:URL,folder:String?,origin:String)throws{
        if try lookup(digest,size:size) != nil{return}
        let record=HistoryRecord(digest:digest,size:size,originalName:name,sourcePath:source?.path,destinationPath:destination.path,captureFolder:folder,recordedAt:Date(),importedAt:origin=="verified-import" ? Date():nil,origin:origin)
        try JSONEncoder().encode(record).write(to:backup.appendingPathComponent(digest+".json"),options:.atomic)
        try insert(record)
    }
    private func insert(_ record:HistoryRecord)throws{
        let data=try JSONEncoder().encode(record)
        var q:OpaquePointer?;defer{sqlite3_finalize(q)}
        guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO history(digest,size,record) VALUES(?,?,?)",-1,&q,nil)==SQLITE_OK else{throw ImportError.message("取り込み履歴を保存できません。")}
        sqlite3_bind_text(q,1,record.digest,-1,transient);sqlite3_bind_int64(q,2,record.size)
        _=data.withUnsafeBytes{sqlite3_bind_blob(q,3,$0.baseAddress,Int32(data.count),transient)}
        guard sqlite3_step(q)==SQLITE_DONE else{throw ImportError.message("取り込み履歴の保存に失敗しました。コピー済みファイルを残して停止します。")}
    }
    func count()->Int{
        var q:OpaquePointer?;defer{sqlite3_finalize(q)}
        guard sqlite3_prepare_v2(db,"SELECT count(*) FROM history",-1,&q,nil)==SQLITE_OK,sqlite3_step(q)==SQLITE_ROW else{return 0}
        return Int(sqlite3_column_int64(q,0))
    }
}
