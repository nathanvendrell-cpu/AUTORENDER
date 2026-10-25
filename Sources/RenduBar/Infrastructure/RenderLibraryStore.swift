import Foundation
import CryptoKit
import Security
import SQLite3
import Darwin

// Embedded SQLite only. Indexed history/pending queries; no service and no JSONL scan.
final class RenderLibraryStore {
    enum Failure:Error {case invalidRoot,invalidStore,sql(String),tamperedRecord,collision}
    let root:URL
    let libraryID:String
    let db:OpaquePointer
    let key:SymmetricKey
    static let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(root:URL,create:Bool)throws {
        self.root=URL(fileURLWithPath:RenderContextPath.absolute(root.path) ?? root.path)
        try Self.directories(self.root,create:create)
        let file=self.root.appendingPathComponent(".autoren-library.sqlite3")
        let keyFile=self.root.appendingPathComponent(".autoren-library-key")
        var bytes=Data();let keyExists=FileManager.default.fileExists(atPath:keyFile.path)
        if keyExists {
            let fd=open(keyFile.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw Failure.invalidStore};defer{close(fd)}
            var st=stat();guard fstat(fd,&st)==0,(st.st_mode&S_IFMT)==S_IFREG,st.st_size==32 else{throw Failure.invalidStore}
            var b=[UInt8](repeating:0,count:32);guard read(fd,&b,32)==32 else{throw Failure.invalidStore};bytes=Data(b)
        } else {
            guard create,!FileManager.default.fileExists(atPath:file.path) else{throw Failure.invalidStore}
            var b=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,32,&b)==errSecSuccess else{throw Failure.invalidStore}
            let fd=open(keyFile.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw Failure.invalidStore};defer{close(fd)}
            guard write(fd,b,32)==32,fsync(fd)==0 else{throw Failure.invalidStore};bytes=Data(b)
        }
        key=SymmetricKey(data:bytes)
        var info=stat();if lstat(file.path,&info)==0,(info.st_mode&S_IFMT) != S_IFREG {throw Failure.invalidStore}
        var connection:OpaquePointer?
        let flags=(create ? SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE:SQLITE_OPEN_READONLY)|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(file.path,&connection,flags,nil)==SQLITE_OK,let connection else{if let connection{sqlite3_close(connection)};throw Failure.invalidStore}
        db=connection
        do {
            if create {
                try Self.exec(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY,v TEXT NOT NULL); CREATE TABLE IF NOT EXISTS tx(id TEXT PRIMARY KEY,plan TEXT UNIQUE NOT NULL,job TEXT NOT NULL,phase TEXT NOT NULL,state TEXT NOT NULL,updated REAL NOT NULL,data BLOB NOT NULL,mac BLOB NOT NULL); CREATE INDEX IF NOT EXISTS tx_recent ON tx(updated DESC,id); CREATE INDEX IF NOT EXISTS tx_phase ON tx(phase,updated); CREATE INDEX IF NOT EXISTS tx_job ON tx(job,state); CREATE INDEX IF NOT EXISTS tx_artifact ON tx(job,json_extract(CAST(data AS TEXT),'$.plan.candidate.id')); CREATE TABLE IF NOT EXISTS scopes(kind TEXT,parent TEXT,identity TEXT,name TEXT,namekey TEXT,PRIMARY KEY(kind,parent,identity),UNIQUE(kind,parent,namekey));")
            }
            let owner=try Self.scalar(db,"SELECT v FROM meta WHERE k='owner'")
            if owner==nil,create {
                try Self.exec(db,"BEGIN IMMEDIATE")
                try Self.put(db,"owner","AUTORENDER_LIBRARY_1");try Self.put(db,"id",UUID().uuidString);try Self.put(db,"revision","0")
                try Self.exec(db,"COMMIT")
            } else if owner != "AUTORENDER_LIBRARY_1" {throw Failure.invalidStore}
            guard let identity=try Self.scalar(db,"SELECT v FROM meta WHERE k='id'") else{throw Failure.invalidStore}
            libraryID=identity
        } catch {sqlite3_close(db);throw error}
    }
    deinit {sqlite3_close(db)}
    static func directories(_ url:URL,create:Bool)throws {
        var current=URL(fileURLWithPath:"/")
        for part in URL(fileURLWithPath:RenderContextPath.absolute(url.path) ?? url.path).pathComponents.dropFirst() {
            current.appendPathComponent(part);var st=stat()
            if lstat(current.path,&st) != 0 {
                guard errno==ENOENT,create else{throw Failure.invalidRoot}
                guard mkdir(current.path,0o700)==0 || errno==EEXIST else{throw Failure.invalidRoot}
                guard lstat(current.path,&st)==0 else{throw Failure.invalidRoot}
            }
            guard (st.st_mode&S_IFMT)==S_IFDIR else{throw Failure.invalidRoot}
        }
    }
    static func exec(_ db:OpaquePointer,_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw Failure.sql(String(cString:sqlite3_errmsg(db)))}}
    static func statement(_ db:OpaquePointer,_ sql:String)throws->OpaquePointer {var p:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&p,nil)==SQLITE_OK,let p else{throw Failure.invalidStore};return p}
    static func text(_ p:OpaquePointer,_ n:Int32,_ value:String){sqlite3_bind_text(p,n,value,-1,transient)}
    static func scalar(_ db:OpaquePointer,_ sql:String)throws->String? {let p=try statement(db,sql);defer{sqlite3_finalize(p)};return sqlite3_step(p)==SQLITE_ROW ? sqlite3_column_text(p,0).map{String(cString:$0)}:nil}
    static func put(_ db:OpaquePointer,_ name:String,_ value:String)throws {let p=try statement(db,"INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)");defer{sqlite3_finalize(p)};text(p,1,name);text(p,2,value);guard sqlite3_step(p)==SQLITE_DONE else{throw Failure.invalidStore}}
    private func data(_ record:RenderLibraryRecord)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(record)}
    func save(_ record:RenderLibraryRecord)throws {
        guard record.libraryID==libraryID,record.libraryRoot==root.path else{throw Failure.invalidRoot}
        let bytes=try data(record),mac=Data(HMAC<SHA256>.authenticationCode(for:bytes,using:key))
        try Self.exec(db,"BEGIN IMMEDIATE")
        do {
            let p=try Self.statement(db,"INSERT INTO tx(id,plan,job,phase,state,updated,data,mac) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET phase=excluded.phase,state=excluded.state,updated=excluded.updated,data=excluded.data,mac=excluded.mac")
            defer{sqlite3_finalize(p)}
            for (n,v) in [record.id,record.plan.id,record.plan.candidate.jobID,record.phase?.rawValue ?? "prepared",record.state.rawValue].enumerated(){Self.text(p,Int32(n+1),v)}
            sqlite3_bind_double(p,6,Date().timeIntervalSince1970)
            _ = bytes.withUnsafeBytes{sqlite3_bind_blob(p,7,$0.baseAddress,Int32($0.count),Self.transient)}
            _ = mac.withUnsafeBytes{sqlite3_bind_blob(p,8,$0.baseAddress,Int32($0.count),Self.transient)}
            guard sqlite3_step(p)==SQLITE_DONE else{throw Failure.invalidStore}
            let revision=(UInt64(try Self.scalar(db,"SELECT v FROM meta WHERE k='revision'") ?? "0") ?? 0)+1
            try Self.put(db,"revision",String(revision));try Self.exec(db,"COMMIT")
            let index=root.appendingPathComponent(".autoren-library-index.json")
            if FileManager.default.fileExists(atPath:index.path){_ = try RenderLibraryFileStamp.read(index)}
            let info:[String:Any]=["schemaVersion":1,"libraryID":libraryID,"revision":revision,"database":".autoren-library.sqlite3"]
            try JSONSerialization.data(withJSONObject:info,options:.sortedKeys).write(to:index,options:.atomic)
        } catch {_ = try? Self.exec(db,"ROLLBACK");throw error}
    }
    private func decode(_ p:OpaquePointer)throws->RenderLibraryRecord {
        let n=Int(sqlite3_column_bytes(p,0)),m=Int(sqlite3_column_bytes(p,1))
        guard n>0,n<=262144,m==32,let b=sqlite3_column_blob(p,0),let a=sqlite3_column_blob(p,1) else{throw Failure.invalidStore}
        let bytes=Data(bytes:b,count:n),mac=Data(bytes:a,count:m)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac,authenticating:bytes,using:key) else{throw Failure.tamperedRecord}
        let record=try JSONDecoder().decode(RenderLibraryRecord.self,from:bytes)
        guard record.libraryID==libraryID,record.libraryRoot==root.path else{throw Failure.invalidRoot};return record
    }
    func find(planID:String?=nil,recordID:String?=nil)throws->RenderLibraryRecord? {
        let p=try Self.statement(db,"SELECT data,mac FROM tx WHERE "+(planID != nil ? "plan":"id")+"=? LIMIT 1");defer{sqlite3_finalize(p)}
        Self.text(p,1,planID ?? recordID ?? "");return sqlite3_step(p)==SQLITE_ROW ? try decode(p):nil
    }
    func findJob(_ id:String)throws->RenderLibraryRecord? {
        let p=try Self.statement(db,"SELECT data,mac FROM tx WHERE job=? ORDER BY updated DESC LIMIT 1");defer{sqlite3_finalize(p)}
        Self.text(p,1,id);return sqlite3_step(p)==SQLITE_ROW ? try decode(p):nil
    }
    func findArtifact(jobID:String,artifactID:String)throws->RenderLibraryRecord? {
        let p=try Self.statement(db,"SELECT data,mac FROM tx WHERE job=? AND json_extract(CAST(data AS TEXT),'$.plan.candidate.id')=? ORDER BY updated DESC LIMIT 1");defer{sqlite3_finalize(p)}
        Self.text(p,1,jobID);Self.text(p,2,artifactID)
        guard sqlite3_step(p)==SQLITE_ROW else{return nil};let r=try decode(p)
        guard r.plan.candidate.jobID==jobID,r.plan.candidate.id==artifactID else{throw Failure.tamperedRecord};return r
    }
    func recent(limit:Int,pendingOnly:Bool=false)throws->[RenderLibraryRecord] {
        let p=try Self.statement(db,"SELECT data,mac FROM tx "+(pendingOnly ? "WHERE phase NOT IN ('complete','undone','failed') ":"")+"ORDER BY updated DESC,id LIMIT ?")
        defer{sqlite3_finalize(p)};sqlite3_bind_int(p,1,Int32(max(1,min(limit,200))))
        var values:[RenderLibraryRecord]=[];while sqlite3_step(p)==SQLITE_ROW {values.append(try decode(p))};return values
    }
    static func readableName(_ value:String,limit:Int=96)->String {
        let clean=value.precomposedStringWithCanonicalMapping.map{c -> Character in (c=="/" || c=="\\" || c==":" || c.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)) ? "_":c}
        var output="";for c in clean {if output.utf8.count+String(c).utf8.count>limit{break};output.append(c)}
        let result=output.trimmingCharacters(in:.whitespacesAndNewlines);return result.isEmpty || result=="." || result==".." ? "À classer":result
    }
    func scopeName(kind:String,parent:String,identity:String,label:String,reserve:Bool)throws->String {
        let p=try Self.statement(db,"SELECT name FROM scopes WHERE kind=? AND parent=? AND identity=?");defer{sqlite3_finalize(p)}
        for (n,v) in [kind,parent,identity].enumerated(){Self.text(p,Int32(n+1),v)}
        if sqlite3_step(p)==SQLITE_ROW,let text=sqlite3_column_text(p,0){return String(cString:text)}
        let base=Self.readableName(label);var name=base
        let q=try Self.statement(db,"SELECT identity FROM scopes WHERE kind=? AND parent=? AND namekey=?");defer{sqlite3_finalize(q)}
        Self.text(q,1,kind);Self.text(q,2,parent);Self.text(q,3,base.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")))
        if sqlite3_step(q)==SQLITE_ROW {name=base+"__"+RenderContextPath.digest(identity).prefix(16)}
        if reserve {
            let r=try Self.statement(db,"INSERT INTO scopes(kind,parent,identity,name,namekey) VALUES(?,?,?,?,?)");defer{sqlite3_finalize(r)}
            for (n,v) in [kind,parent,identity,name,name.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))].enumerated(){Self.text(r,Int32(n+1),v)}
            guard sqlite3_step(r)==SQLITE_DONE else{throw Failure.collision}
        }
        return name
    }
}
