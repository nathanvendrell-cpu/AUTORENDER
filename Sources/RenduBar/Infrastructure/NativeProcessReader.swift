import Darwin
import Foundation

struct NativeProcessRead {
    var snapshots: [NativeProcessSnapshot] = []
    var partial = false
    var issue: String?
}
protocol NativeProcessReading { func read() -> NativeProcessRead }

struct NativeProcessReader: NativeProcessReading {
    let maximumPIDs = 8192
    let maximumCandidates = 64
    let maximumArgumentBytes = 64*1024
    static func producer(_ executable: String) -> String? {
        let name=(executable as NSString).lastPathComponent.lowercased()
        if name=="blender" { return "Blender" }
        if name=="ffmpeg" { return "ffmpeg" }
        return nil
    }
    func read() -> NativeProcessRead {
        var result=NativeProcessRead()
        var pids=[Int32](repeating:0,count:maximumPIDs)
        let bytes=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS),0,$0.baseAddress,Int32($0.count)) }
        guard bytes>0 else { result.partial=true;result.issue="Processus locaux inaccessibles";return result }
        if Int(bytes)>=pids.count*MemoryLayout<Int32>.size { result.partial=true }
        for pid in pids.prefix(min(Int(bytes)/MemoryLayout<Int32>.size,pids.count)) where pid>0 {
            guard !Task.isCancelled else { return result }
            var info=proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))==MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid==getuid() else { continue }
            var path=[CChar](repeating:0,count:4*Int(MAXPATHLEN))
            guard proc_pidpath(pid,&path,UInt32(path.count))>0 else { continue }
            let executable=String(cString:path)
            guard Self.producer(executable) != nil else { continue }
            guard result.snapshots.count<maximumCandidates else { result.partial=true;break }
            let identity=NativeProcessIdentity(pid:pid,birthSeconds:info.pbi_start_tvsec,birthMicroseconds:info.pbi_start_tvusec,executable:executable)
            let args=arguments(pid:pid,executable:executable)
            var after=proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,Int32(MemoryLayout<proc_bsdinfo>.size))==MemoryLayout<proc_bsdinfo>.size,
                  after.pbi_uid==info.pbi_uid,after.pbi_start_tvsec==info.pbi_start_tvsec,after.pbi_start_tvusec==info.pbi_start_tvusec else { result.partial=true;continue }
            var afterPath=[CChar](repeating:0,count:4*Int(MAXPATHLEN))
            guard proc_pidpath(pid,&afterPath,UInt32(afterPath.count))>0,String(cString:afterPath)==executable else { result.partial=true;continue }
            if args==nil { result.partial=true }
            result.snapshots.append(NativeProcessSnapshot(identity:identity,arguments:args))
        }
        if result.partial { result.issue="Couverture locale partielle · commandes inaccessibles ou limite atteinte" }
        return result
    }
    private func arguments(pid: Int32, executable: String) -> [String]? {
        var mib=[Int32(CTL_KERN),Int32(KERN_PROCARGS2),pid]
        var buffer=[UInt8](repeating:0,count:maximumArgumentBytes)
        var size=buffer.count
        defer { buffer.withUnsafeMutableBytes { raw in if let base=raw.baseAddress { memset(base,0,raw.count) } } }
        guard sysctl(&mib,u_int(mib.count),&buffer,&size,nil,0)==0,size>=MemoryLayout<Int32>.size,size<=buffer.count else { return nil }
        // KERN_PROCARGS2 returns a kernel buffer with argv and a trailing environment.
        // Decode exactly argc strings. Never inspect/decode the trailing environment; erase buffer on exit.
        return Self.decodeArguments(buffer,size:size,executable:executable)
    }

    static func decodeArguments(_ buffer:[UInt8],size:Int,executable:String) -> [String]? {
        guard size>=MemoryLayout<Int32>.size,size<=buffer.count else { return nil }
        let argc=buffer.withUnsafeBytes { $0.loadUnaligned(as:Int32.self) }
        guard argc>0,argc<=256 else { return nil }
        var cursor=MemoryLayout<Int32>.size
        guard let executableEnd=buffer[cursor..<size].firstIndex(of:0) else { return nil }
        cursor=executableEnd+1
        while cursor<size && buffer[cursor]==0 { cursor+=1 }
        var values:[String]=[]
        for _ in 0..<argc {
            guard cursor<size,let end=buffer[cursor..<size].firstIndex(of:0),end-cursor<=4096,
                  let value=String(bytes:buffer[cursor..<end],encoding:.utf8) else { return nil }
            if values.isEmpty, value != executable, value.lowercased() != (executable as NSString).lastPathComponent.lowercased() { return nil }
            values.append(value);cursor=end+1
        }
        return values
    }
}
