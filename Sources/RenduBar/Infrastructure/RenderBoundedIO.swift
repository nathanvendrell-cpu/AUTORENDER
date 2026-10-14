import Foundation
import Darwin

// Invalidation never waits on filesystem IO. It rejects every new persistence stage.
final class RenderTaskLifetime: @unchecked Sendable {
    private let lock=NSLock()
    private var open=true
    func invalidate() { lock.lock();open=false;lock.unlock() }
    var isOpen: Bool { lock.lock();defer { lock.unlock() };return open }
    func check() throws { if !isOpen { throw CancellationError() } }
}

final class RenderIOPermit: @unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    private let deadline: UInt64
    private let lifetime: RenderTaskLifetime?
    init(seconds: Double, lifetime: RenderTaskLifetime? = nil) {
        self.lifetime=lifetime
        deadline=DispatchTime.now().uptimeNanoseconds + UInt64(max(0,seconds)*1_000_000_000)
    }
    func cancel() { lock.lock();cancelled=true;lock.unlock() }
    func check() throws {
        lock.lock();let stopped=cancelled;lock.unlock()
        guard !stopped,DispatchTime.now().uptimeNanoseconds<deadline else { throw CancellationError() }
        try lifetime?.check()
    }
}

private final class RenderIOPromise<Value>: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Value,Error>?
    private var result: Result<Value,Error>?
    private var timer: DispatchSourceTimer?
    func install(_ value: CheckedContinuation<Value,Error>) {
        lock.lock();let ready=result
        if ready==nil { continuation=value }
        lock.unlock()
        if let ready { value.resume(with:ready) }
    }
    func attach(_ value: DispatchSourceTimer) {
        lock.lock();let done=result != nil;if !done { timer=value };lock.unlock()
        if done { value.cancel() }
    }
    func finish(_ value: Result<Value,Error>) {
        lock.lock()
        guard result==nil else { lock.unlock();return }
        result=value;let target=continuation;continuation=nil;let timer=self.timer;self.timer=nil
        lock.unlock();timer?.cancel();target?.resume(with:value)
    }
}

enum RenderIOFailure: Error { case occupied, deadline }

// At most one OS operation remains in flight, even if the OS ignores its timeout/cancellation.
// The async caller resumes at deadline; the worker keeps its slot until the OS call returns.
final class RenderBoundedIO: @unchecked Sendable {
    private let lock=NSLock()
    private var occupied=false
    private let completionObserver:(() -> Void)?
    init(completionObserver:(() -> Void)?=nil) { self.completionObserver=completionObserver }
    private let queue=DispatchQueue(label:"AUTORENDER.bounded-local-io",qos:.utility)
    func run<Value>(seconds: Double = 2, lifetime: RenderTaskLifetime? = nil,
                    _ body: @escaping (RenderIOPermit) throws -> Value) async throws -> Value {
        try Task.checkCancellation();try lifetime?.check()
        guard acquire() else { throw RenderIOFailure.occupied }
        let permit=RenderIOPermit(seconds:seconds,lifetime:lifetime)
        let promise=RenderIOPromise<Value>()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                promise.install(continuation)
                let timer=DispatchSource.makeTimerSource(queue:.global(qos:.utility))
                timer.schedule(deadline:.now()+seconds)
                timer.setEventHandler { permit.cancel();promise.finish(.failure(RenderIOFailure.deadline)) }
                timer.resume();promise.attach(timer)
                queue.async {
                    let result:Result<Value,Error>
                    do { try permit.check();let value=try body(permit);try permit.check();result = .success(value) }
                    catch { result = .failure(error) }
                    self.lock.lock();self.occupied=false;self.lock.unlock()
                    promise.finish(result)
                    self.completionObserver?()
                }
            }
        },onCancel:{ permit.cancel();promise.finish(.failure(CancellationError())) })
    }
    private func acquire() -> Bool { lock.lock();defer { lock.unlock() };guard !occupied else { return false };occupied=true;return true }
    var isOccupied: Bool { lock.lock();defer { lock.unlock() };return occupied }

    // No structured task group: a group would await a suspended child when its scope exits.
    static func wait(seconds: Double, _ body: @escaping () async -> Void) async -> Bool {
        let promise=RenderIOPromise<Bool>()
        return (try? await withCheckedThrowingContinuation { continuation in
            promise.install(continuation)
            let timer=DispatchSource.makeTimerSource(queue:.global(qos:.utility))
            timer.schedule(deadline:.now()+seconds);timer.setEventHandler { promise.finish(.success(false)) }
            timer.resume();promise.attach(timer)
            Task { await body();promise.finish(.success(true)) }
        }) ?? false
    }
}

enum RenderRegularFile {
    static func read(_ file: URL, maximumBytes: Int, permit: RenderIOPermit? = nil,
                     allowSymlink: Bool = true) throws -> Data {
        try permit?.check();try Task.checkCancellation()
        let flags=O_RDONLY|O_NONBLOCK|O_CLOEXEC|(allowSymlink ? 0 : O_NOFOLLOW)
        let descriptor=open(file.path,flags)
        guard descriptor>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { close(descriptor) }
        var info=stat()
        guard fstat(descriptor,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,
              lseek(descriptor,0,SEEK_CUR)>=0 else { throw POSIXError(.EINVAL) }
        guard info.st_size>=0,info.st_size<=maximumBytes else { throw POSIXError(.EFBIG) }
        try permit?.check();try Task.checkCancellation()
        var data=Data();var buffer=[UInt8](repeating:0,count:16*1024)
        while true {
            try permit?.check();try Task.checkCancellation()
            let count=buffer.withUnsafeMutableBytes { Darwin.read(descriptor,$0.baseAddress,$0.count) }
            if count==0 { return data }
            if count<0 {
                if errno==EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
            }
            guard data.count+count<=maximumBytes else { throw POSIXError(.EFBIG) }
            data.append(contentsOf:buffer.prefix(count))
        }
    }
}
