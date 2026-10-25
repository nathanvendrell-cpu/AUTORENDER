import Foundation
import CryptoKit
import SQLite3

extension RenderLibraryStore {
    private struct Done:Codable {let manifestID:String;let artifactID:String;let recordID:String;let state:RenderLibraryState}
    private func manifestSchema()throws {
        try Self.exec(db,"CREATE TABLE IF NOT EXISTS manifests(id TEXT PRIMARY KEY,jid TEXT,updated REAL NOT NULL DEFAULT 0,done INTEGER NOT NULL DEFAULT 0,data BLOB NOT NULL,mac BLOB NOT NULL); CREATE INDEX IF NOT EXISTS tx_job_recent ON tx(job,updated DESC,id DESC); CREATE INDEX IF NOT EXISTS manifest_pending ON manifests(done,updated,id); CREATE TABLE IF NOT EXISTS manifest_items(mid TEXT,aid TEXT,pos INTEGER,data BLOB NOT NULL,mac BLOB NOT NULL,PRIMARY KEY(mid,aid),UNIQUE(mid,pos)); CREATE INDEX IF NOT EXISTS manifest_page ON manifest_items(mid,pos); CREATE TABLE IF NOT EXISTS manifest_done(mid TEXT,aid TEXT,data BLOB NOT NULL,mac BLOB NOT NULL,PRIMARY KEY(mid,aid));")
    }
    private func encodeSigned<T:Encodable>(_ value:T)throws->(Data,Data) {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];let d=try e.encode(value);return(d,Data(HMAC<SHA256>.authenticationCode(for:d,using:key)))}
    private func decodeSigned<T:Decodable>(_ p:OpaquePointer,as:T.Type)throws->T {
        let n=Int(sqlite3_column_bytes(p,0)),m=Int(sqlite3_column_bytes(p,1));guard n>0,n<=262144,m==32,let b=sqlite3_column_blob(p,0),let a=sqlite3_column_blob(p,1) else{throw Failure.invalidStore}
        let d=Data(bytes:b,count:n),mac=Data(bytes:a,count:m);guard HMAC<SHA256>.isValidAuthenticationCode(mac,authenticating:d,using:key) else{throw Failure.tamperedRecord};return try JSONDecoder().decode(T.self,from:d)
    }
    private func signedColumns<T:Encodable>(_ p:OpaquePointer,_ first:Int32,_ value:T)throws {
        let(d,m)=try encodeSigned(value)
        _=d.withUnsafeBytes{sqlite3_bind_blob(p,first,$0.baseAddress,Int32(d.count),Self.transient)}
        _=m.withUnsafeBytes{sqlite3_bind_blob(p,first+1,$0.baseAddress,Int32(m.count),Self.transient)}
    }
    func manifest(_ id:String)throws->RenderLibraryManifestCheckpoint? {
        try manifestSchema();let p=try Self.statement(db,"SELECT data,mac FROM manifests WHERE id=?");defer{sqlite3_finalize(p)};Self.text(p,1,id)
        guard sqlite3_step(p)==SQLITE_ROW else{return nil};let v=try decodeSigned(p,as:RenderLibraryManifestCheckpoint.self);guard v.id==id else{throw Failure.tamperedRecord};return v
    }
    func saveManifest(_ value:RenderLibraryManifestCheckpoint)throws {
        try manifestSchema();guard value.expectedCount>0,value.expectedCount<=50_000,value.nextCursor>=0 else{throw Failure.invalidStore}
        let p=try Self.statement(db,"INSERT INTO manifests(id,jid,updated,done,data,mac) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated,done=excluded.done,data=excluded.data,mac=excluded.mac");defer{sqlite3_finalize(p)};Self.text(p,1,value.id);Self.text(p,2,value.jobID);sqlite3_bind_double(p,3,Date().timeIntervalSince1970);sqlite3_bind_int(p,4,value.listingComplete && value.processedCursor==value.expectedCount ? 1:0);try signedColumns(p,5,value);guard sqlite3_step(p)==SQLITE_DONE else{throw Failure.invalidStore}
    }
    func pendingManifests(limit:Int)throws->[RenderLibraryManifestCheckpoint] {
        try manifestSchema();let p=try Self.statement(db,"SELECT data,mac FROM manifests WHERE done=0 ORDER BY updated,id LIMIT ?");defer{sqlite3_finalize(p)};sqlite3_bind_int(p,1,Int32(max(1,min(16,limit))))
        var result:[RenderLibraryManifestCheckpoint]=[];while sqlite3_step(p)==SQLITE_ROW {result.append(try decodeSigned(p,as:RenderLibraryManifestCheckpoint.self))};return result
    }
    func appendManifestPage(_ items:[RenderLibraryManifestItem],checkpoint:RenderLibraryManifestCheckpoint)throws {
        try manifestSchema();guard items.count<=64 else{throw Failure.invalidStore};try Self.exec(db,"BEGIN IMMEDIATE")
        do {
            for item in items {
                guard item.manifestID==checkpoint.id,item.position>=0,item.position<checkpoint.expectedCount else{throw Failure.invalidStore}
                let p=try Self.statement(db,"INSERT OR IGNORE INTO manifest_items(mid,aid,pos,data,mac) VALUES(?,?,?,?,?)");defer{sqlite3_finalize(p)}
                Self.text(p,1,item.manifestID);Self.text(p,2,item.artifact.id);sqlite3_bind_int(p,3,Int32(item.position));try signedColumns(p,4,item);guard sqlite3_step(p)==SQLITE_DONE else{throw Failure.invalidStore}
                // Exact retry only; a changed path or position cannot borrow a prior artifact ID.
                let q=try Self.statement(db,"SELECT data,mac FROM manifest_items WHERE mid=? AND aid=?");defer{sqlite3_finalize(q)};Self.text(q,1,item.manifestID);Self.text(q,2,item.artifact.id)
                guard sqlite3_step(q)==SQLITE_ROW else{throw Failure.invalidStore};let prior=try decodeSigned(q,as:RenderLibraryManifestItem.self)
                guard prior.position==item.position,prior.artifact.path==item.artifact.path,prior.artifact.id==item.artifact.id else{throw Failure.collision}
            }
            try saveManifest(checkpoint);try Self.exec(db,"COMMIT")
        }catch{try? Self.exec(db,"ROLLBACK");throw error}
    }
    func manifestPage(_ id:String,after:Int,limit:Int)throws->[RenderLibraryManifestItem] {
        try manifestSchema();let p=try Self.statement(db,"SELECT data,mac FROM manifest_items WHERE mid=? AND pos>=? ORDER BY pos LIMIT ?");defer{sqlite3_finalize(p)};Self.text(p,1,id);sqlite3_bind_int(p,2,Int32(after));sqlite3_bind_int(p,3,Int32(max(1,min(64,limit))))
        var result:[RenderLibraryManifestItem]=[];while sqlite3_step(p)==SQLITE_ROW {let item=try decodeSigned(p,as:RenderLibraryManifestItem.self);guard item.manifestID==id else{throw Failure.tamperedRecord};result.append(item)};return result
    }
    func settleManifest(_ record:RenderLibraryRecord)throws {
        guard let mid=record.manifestID,var m=try manifest(mid),m.jobID==record.plan.candidate.jobID,[RenderLibraryState.moved,.copiedSourceKept,.undone].contains(record.state) else{return}
        let done=Done(manifestID:mid,artifactID:record.plan.candidate.id,recordID:record.id,state:record.state)
        try Self.exec(db,"BEGIN IMMEDIATE")
        do {
            let prior=try Self.statement(db,"SELECT data,mac FROM manifest_done WHERE mid=? AND aid=?");defer{sqlite3_finalize(prior)};Self.text(prior,1,mid);Self.text(prior,2,done.artifactID)
            let old:Done?=sqlite3_step(prior)==SQLITE_ROW ? try decodeSigned(prior,as:Done.self):nil
            if old?.state != .undone && old != nil {m.registeredCount-=1};if old?.state == .moved {m.movedCount-=1}
            if done.state != .undone {m.registeredCount+=1};if done.state == .moved {m.movedCount+=1}
            guard m.registeredCount>=0,m.registeredCount<=m.expectedCount,m.movedCount>=0,m.movedCount<=m.registeredCount else{throw Failure.invalidStore}
            let p=try Self.statement(db,"INSERT INTO manifest_done(mid,aid,data,mac) VALUES(?,?,?,?) ON CONFLICT(mid,aid) DO UPDATE SET data=excluded.data,mac=excluded.mac");defer{sqlite3_finalize(p)};Self.text(p,1,mid);Self.text(p,2,done.artifactID);try signedColumns(p,3,done);guard sqlite3_step(p)==SQLITE_DONE else{throw Failure.invalidStore}
            try saveManifest(m);try Self.exec(db,"COMMIT")
        }catch{try? Self.exec(db,"ROLLBACK");throw error}
    }
    func validateWholeManifest(_ id:String)throws->Bool {
        guard let m=try manifest(id),m.complete,m.listingComplete,m.registeredCount==m.expectedCount,m.movedCount==m.expectedCount else{return false}
        let p=try Self.statement(db,"SELECT data,mac FROM manifest_done WHERE mid=?");defer{sqlite3_finalize(p)};Self.text(p,1,id);var n=0
        while sqlite3_step(p)==SQLITE_ROW {let d=try decodeSigned(p,as:Done.self);guard d.manifestID==id,d.state == .moved else{throw Failure.tamperedRecord};n+=1}
        return n==m.expectedCount
    }
    func recordsForJob(_ jobID:String,cursor:String?,limit:Int)throws->RenderLibraryJobPage {
        let count=max(1,min(50,limit));var before=Double.greatestFiniteMagnitude,beforeID=""
        if let cursor {
            guard cursor.utf8.count<=128,let d=Data(base64Encoded:cursor),let parts=try JSONSerialization.jsonObject(with:d) as? [String],parts.count==2,let timestamp=Double(parts[0]),timestamp.isFinite else{throw Failure.invalidStore}
            before=timestamp;beforeID=parts[1]
        }
        let p=try Self.statement(db,"SELECT id,updated FROM tx WHERE job=? AND (updated<? OR (updated=? AND id<?)) ORDER BY updated DESC,id DESC LIMIT ?");defer{sqlite3_finalize(p)}
        Self.text(p,1,jobID);sqlite3_bind_double(p,2,before);sqlite3_bind_double(p,3,before);Self.text(p,4,beforeID);sqlite3_bind_int(p,5,Int32(count+1))
        var records:[RenderLibraryRecord]=[],next:String?;var lastID="",lastTime=0.0
        while sqlite3_step(p)==SQLITE_ROW {
            if records.count==count {next=try JSONSerialization.data(withJSONObject:[String(lastTime),lastID]).base64EncodedString();break}
            guard let key=sqlite3_column_text(p,0) else{throw Failure.invalidStore};let id=String(cString:key)
            guard let r=try find(recordID:id),r.plan.candidate.jobID==jobID else{throw Failure.tamperedRecord}
            records.append(r);lastID=id;lastTime=sqlite3_column_double(p,1)
        }
        return RenderLibraryJobPage(records:records,nextCursor:next)
    }

}
