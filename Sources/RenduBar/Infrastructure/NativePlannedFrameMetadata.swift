import Foundation
import CoreFoundation
import Darwin

/// Explicit private association, supplied from configuration and a fresh process snapshot.
/// Does not decode arguments, execute producer scripts or discover output directories.
enum NativePlannedFrameMetadata {
    struct Binding: Equatable {
        let pid: Int32
        let birthSeconds: UInt64
        let birthMicroseconds: UInt64
        let executable: String
        let scene: String
        var bornAt: Date { Date(timeIntervalSince1970: Double(birthSeconds) + Double(birthMicroseconds) / 1_000_000) }
    }

    struct Mapping: Equatable {
        static func ==(a:Mapping,b:Mapping)->Bool {
            var left=a,right=b;left.expectedMetadata=nil;right.expectedMetadata=nil
            return left.metadataPath==right.metadataPath && left.outputRoot==right.outputRoot && left.binding==right.binding && left.plannedKey==right.plannedKey && left.filenamePattern==right.filenamePattern && left.completedKey==right.completedKey && left.frameKey==right.frameKey && left.secondsKey==right.secondsKey && left.totalKey==right.totalKey && left.maximumBytes==right.maximumBytes && left.exclusiveOutputScope==right.exclusiveOutputScope && left.requirePNGEnvelope==right.requirePNGEnvelope && left.expectedVariant==right.expectedVariant && left.expectedMode==right.expectedMode && left.expectedFrames==right.expectedFrames
        }
        var metadataPath: String
        var outputRoot: String
        let binding: Binding
        let plannedKey: String
        let filenamePattern: String // Exactly one contiguous # placeholder in one basename.
        var completedKey = "completed"
        var frameKey = "frame"
        var secondsKey = "seconds"
        var totalKey: String? = nil
        var maximumBytes = 32 * 1024 // Explicitly configurable up to 256 KiB.
        var requirePNGEnvelope = false
        var expectedMetadata:Fingerprint? = nil
        var expectedVariant:String? = nil
        var expectedMode:String? = nil
        var expectedFrames:[Int]? = nil
        var exclusiveOutputScope = false // Collector must reject competing process mappings.
    }

    struct Fingerprint: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Int64
        let modified: Date
    }

    struct Sample {
        let mapping: Mapping
        let planned: [Int]
        let files: [Int: Fingerprint]
        let observedAt: Date
        let metadataModified: Date
        let payloadCompletedHints: Int // Diagnostic only; never a progress numerator.
        let completed: Int? // nil on the first sample; stable verified files on later samples.
        let historicalMedianSeconds: Double? // Observed durations, never FPS or active cadence.
        let outputAdvanced: Bool // Specific expected file appearance/growth, with birth/freshness checks.
        var total: Int { planned.count }
    }

    enum Failure: Error { case mapping, identity, metadata, unstable, limit, fileType }

    static func filename(frame: Int, pattern: String) -> String? {
        guard (1...1_000_000).contains(frame), pattern.utf8.count <= 256,
              !pattern.contains("/"), !pattern.contains("\\"),
              pattern.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-#").contains($0) }),
              let start = pattern.firstIndex(of: "#") else { return nil }
        let end = pattern[start...].firstIndex(where: { $0 != "#" }) ?? pattern.endIndex
        let width = pattern.distance(from: start, to: end)
        let tail = pattern[end...]
        guard (1...8).contains(width), !tail.contains("#") else { return nil }
        let digits = String(frame)
        guard digits.count <= width else { return nil }
        return String(pattern[..<start]) + String(repeating: "0", count: width - digits.count) + digits + tail
    }

    /// Pure schema decoding. Planned IDs define the total; duplicates count once.
    static func decode(_ data: Data, mapping: Mapping) throws -> (planned: [Int], seconds: [Int: Double], hints: Int) {
        guard (1...(256 * 1024)).contains(mapping.maximumBytes), data.count <= mapping.maximumBytes else { throw Failure.limit }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object[mapping.plannedKey] as? [Any], !raw.isEmpty, raw.count <= 10_000 else { throw Failure.metadata }
        var unique = Set<Int>()
        for value in raw {
            guard let frame = integer(value), (1...1_000_000).contains(frame),
                  filename(frame: frame, pattern: mapping.filenamePattern) != nil else { throw Failure.metadata }
            unique.insert(frame)
        }
        let planned = unique.sorted()
        if let expected=mapping.expectedFrames {
            guard raw.count==expected.count,raw.compactMap(strictInteger)==expected,
                  object["variant"] as? String==mapping.expectedVariant,
                  object["mode"] as? String==mapping.expectedMode,
                  let rows=object[mapping.completedKey] as? [[String:Any]],rows.count<=expected.count else {throw Failure.metadata}
            var seen=Set<Int>()
            for row in rows {
                guard let frame=row[mapping.frameKey].flatMap(strictInteger),unique.contains(frame),seen.insert(frame).inserted,
                      let seconds=row[mapping.secondsKey] as? NSNumber,CFGetTypeID(seconds) != CFBooleanGetTypeID(),
                      seconds.doubleValue.isFinite,seconds.doubleValue>0,seconds.doubleValue<86_400,
                      let bytes=row["bytes"] as? NSNumber,CFGetTypeID(bytes) != CFBooleanGetTypeID(),
                      !["f","d"].contains(String(cString:bytes.objCType)),bytes.doubleValue.isFinite,bytes.doubleValue>0,bytes.doubleValue.rounded(.towardZero)==bytes.doubleValue else {throw Failure.metadata}
            }
        }

        if let key = mapping.totalKey {
            guard let rawTotal = object[key], integer(rawTotal) == planned.count else { throw Failure.metadata }
        }
        var seconds: [Int: Double] = [:]
        var hints = Set<Int>()
        if let rows = object[mapping.completedKey] as? [Any] {
            guard rows.count <= 10_000 else { throw Failure.limit }
            for row in rows {
                guard let row = row as? [String: Any], let frame = row[mapping.frameKey].flatMap(integer), unique.contains(frame) else { continue }
                hints.insert(frame)
                if let number = row[mapping.secondsKey] as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID() {
                    let duration = number.doubleValue
                    if duration.isFinite && duration > 0 && duration <= 86_400 { seconds[frame] = duration }
                }
            }
        }
        return (planned, seconds, hints.count)
    }

    /// Must run inside the converged RenderBoundedIO worker/lifetime, never on the main actor.
    /// Pass permit.check as check. Each OS boundary checks the same lifetime/deadline.
    /// O_NONBLOCK/O_NOFOLLOW and fstat reject pipes/devices/symlinks without waiting on them.
    /// Kernel/network IO cannot be hard-interrupted; the outer bounded worker retains its slot.
    static func read(mapping: Mapping, current: Binding, now: Date, previous: Sample?,
                     check: () throws -> Void) throws -> Sample {
        try check()
        guard current == mapping.binding, current.pid > 0, current.birthSeconds > 0,
              current.birthMicroseconds < 1_000_000, current.bornAt <= now.addingTimeInterval(2),
              cleanAbsolute(current.executable), cleanAbsolute(current.scene) else { throw Failure.identity }
        guard cleanAbsolute(mapping.metadataPath), cleanAbsolute(mapping.outputRoot),
              !["/", "/Users", "/Volumes", "/tmp", "/private/tmp"].contains(mapping.outputRoot),
              [mapping.plannedKey, mapping.completedKey, mapping.frameKey, mapping.secondsKey].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              filename(frame: 1, pattern: mapping.filenamePattern) != nil,
              (1...(256 * 1024)).contains(mapping.maximumBytes) else { throw Failure.mapping }
        let metadataFD = try descriptor(mapping.metadataPath, flags: O_RDONLY, check: check)
        defer { close(metadataFD) }
        let before = try fingerprint(metadataFD, check: check)
        if let expected=mapping.expectedMetadata,expected != before {throw Failure.unstable}
        guard before.bytes >= 0, before.bytes <= mapping.maximumBytes else { throw Failure.limit }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try check()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(metadataFD, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw Failure.metadata }
            guard data.count + count <= mapping.maximumBytes else { throw Failure.limit }
            data.append(contentsOf: buffer.prefix(count))
        }
        let after = try fingerprint(metadataFD, check: check)
        guard before == after, data.count == Int(after.bytes) else { throw Failure.unstable }
        let decoded = try decode(data, mapping: mapping)
        let rootFD = try descriptor(mapping.outputRoot, flags: O_RDONLY | O_DIRECTORY, check: check)
        defer { close(rootFD) }
        var files: [Int: Fingerprint] = [:]
        var pngDimensions:[UInt32]?
        for frame in decoded.planned {
            try check()
            guard let name = filename(frame: frame, pattern: mapping.filenamePattern) else { throw Failure.mapping }
            let fd = openat(rootFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { continue } // Missing/inaccessible output cannot enter the numerator.
            defer { close(fd) }
            if let value = try? fingerprint(fd, check: check), value.bytes > 0 {
                if mapping.requirePNGEnvelope {
                    guard let dimensions=pngEnvelope(fd:fd,bytes:value.bytes),let after=try? fingerprint(fd,check:check),after==value else{continue}
                    if let expected=pngDimensions,expected != dimensions{throw Failure.fileType}
                    pngDimensions=dimensions
                }
                files[frame] = value
            }
            try check() // Do not swallow cancellation while omitting unreadable outputs.
        }
        try check()
        return evaluate(mapping: mapping, planned: decoded.planned, files: files,
                        metadataModified: after.modified, seconds: decoded.seconds, hints: decoded.hints,
                        now: now, previous: previous)
    }

    /// Pure comparison: existing SKIP outputs count even when omitted from completed[].
    static func evaluate(mapping: Mapping, planned: [Int], files: [Int: Fingerprint],
                         metadataModified: Date, seconds: [Int: Double], hints: Int,
                         now: Date, previous: Sample?) -> Sample {
        let prior = previous.flatMap { $0.mapping == mapping && $0.planned == planned && now.timeIntervalSince($0.observedAt) >= 1 ? $0 : nil }
        let stable = planned.filter { frame in
            guard let file = files[frame], file.bytes > 0, file.modified <= now.addingTimeInterval(-2),
                  let old = prior?.files[frame], old == file else { return false }
            return true
        }
        let freshMetadata = now.timeIntervalSince(metadataModified) >= -2 && now.timeIntervalSince(metadataModified) <= 60
        let durations = freshMetadata ? stable.compactMap { seconds[$0] }.filter { $0.isFinite && $0 > 0 }.sorted() : []
        let median: Double? = durations.isEmpty ? nil : (durations[(durations.count - 1) / 2] + durations[durations.count / 2]) / 2
        let advanced = mapping.exclusiveOutputScope && prior != nil && planned.contains { frame in
            guard let file = files[frame], file.modified >= mapping.binding.bornAt,
                  now.timeIntervalSince(file.modified) >= 0, now.timeIntervalSince(file.modified) <= 20 else { return false }
            guard let old = prior?.files[frame] else { return true } // New exact expected output appeared after prior poll.
            return file.inode == old.inode && (file.bytes > old.bytes || file.modified > old.modified)
        }
        return Sample(mapping: mapping, planned: planned, files: files, observedAt: now,
                      metadataModified: metadataModified, payloadCompletedHints: hints,
                      completed: prior == nil ? nil : stable.count, historicalMedianSeconds: median,
                      outputAdvanced: advanced)
    }

    // Source proof uses one nonblocking regular descriptor, exact byte cap and unchanged fingerprint.
    static func readSource(_ path:String,permit:RenderIOPermit) throws -> (Data,Fingerprint) {
        try permit.check()
        var direct=stat()
        guard lstat(path,&direct)==0,(direct.st_mode&S_IFMT)==S_IFREG else{throw Failure.fileType}
        guard let resolved=realpath(path,nil) else{throw Failure.fileType}
        defer{free(resolved)}
        let physical=String(cString:resolved)
        let fd=try descriptor(physical,flags:O_RDONLY,check:{try permit.check()});defer{close(fd)}
        let before=try fingerprint(fd,check:{try permit.check()})
        guard before.bytes>=0,before.bytes<=32768 else{throw Failure.limit}
        var data=Data();var buffer=[UInt8](repeating:0,count:8192)
        while true {
            try permit.check()
            let count=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count)}
            if count==0{break};if count<0{if errno==EINTR{continue};throw Failure.fileType}
            guard data.count+count<=32768 else{throw Failure.limit};data.append(contentsOf:buffer.prefix(count))
        }
        let after=try fingerprint(fd,check:{try permit.check()})
        guard before==after,data.count==Int(after.bytes) else{throw Failure.unstable}
        return (data,after)
    }

    // Bounded container checks only; never assert full pixel decoding or artistic validity.
    static func pngEnvelope(fd:Int32,bytes:Int64)->[UInt32]? {
        guard bytes>=57 else{return nil}
        var header=[UInt8](repeating:0,count:33);var footer=[UInt8](repeating:0,count:12)
        guard pread(fd,&header,33,0)==33,pread(fd,&footer,12,off_t(bytes-12))==12,
              Array(header.prefix(16))==[137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82],
              footer==[0,0,0,0,73,69,78,68,174,66,96,130] else{return nil}
        func number(_ start:Int)->UInt32 {header[start..<start+4].reduce(UInt32(0)){($0<<8)|UInt32($1)}}
        var crc=UInt32.max
        for byte in header[12..<29] {crc ^= UInt32(byte);for _ in 0..<8 {crc=(crc>>1)^((crc&1)==0 ? 0 : 0xedb88320)}}
        let width=number(16),height=number(20)
        guard ~crc==number(29),width>0,height>0,width<=100_000,height<=100_000 else{return nil}
        return [width,height]
    }

    private static func strictInteger(_ value:Any)->Int? {
        guard let number=value as? NSNumber,!["f","d"].contains(String(cString:number.objCType)) else{return nil}
        return integer(value)
    }
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let n = number.doubleValue
        guard n.isFinite, n >= 0, n <= 1_000_000, n.rounded(.towardZero) == n else { return nil }
        return Int(n)
    }

    private static func cleanAbsolute(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.contains("://")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func descriptor(_ path: String, flags: Int32, check: () throws -> Void) throws -> Int32 {
        try check()
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= 128 else { throw Failure.mapping }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.fileType }
        defer { close(parent) }
        for component in components.dropLast() {
            try check()
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.fileType }
            close(parent); parent = next
        }
        try check()
        let fd = openat(parent, components.last!, flags | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.fileType }
        return fd
    }

    private static func fingerprint(_ fd: Int32, check: () throws -> Void) throws -> Fingerprint {
        try check()
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.fileType }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Fingerprint(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), bytes: info.st_size, modified: modified)
    }
}
