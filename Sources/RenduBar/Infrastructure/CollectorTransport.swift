import CryptoKit
import Darwin
import Foundation

enum CollectorProcess {
    private static let lock = NSLock()
    private static let transportGate=NSLock()
    private static var running: [UUID: Process] = [:]
    private static var cancelled = Set<UUID>()

    private static var remoteEnabled=true
    static var remoteAccessEnabled:Bool {lock.lock();defer{lock.unlock()};return remoteEnabled}
    static func setRemoteAccessEnabled(_ enabled:Bool) {
        lock.lock();remoteEnabled=enabled
        let processes=enabled ? []:Array(running.values)
        if !enabled {cancelled.formUnion(running.keys)}
        lock.unlock()
        // Only Python/SSH helpers registered by this app, never a renderer or user process.
        for process in processes where process.isRunning {process.terminate()}
    }

    static func cancel(_ token: UUID) {
        lock.lock(); cancelled.insert(token); let process=running[token]; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    static func asyncRun(arguments: [String], timeout: TimeInterval,fixtureHelperURL:URL? = nil) async -> Data? {
        let token=UUID()
        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority:.utility) { run(arguments:arguments,timeout:timeout,token:token,fixtureHelperURL:fixtureHelperURL) }.value
        }, onCancel: { cancel(token) })
    }

    static func requestCancelAll() {
        lock.lock();let processes=Array(running.values);lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }
    static func waitForExit() {
        lock.lock();let processes=Array(running.values);lock.unlock()
        let deadline=Date().addingTimeInterval(5)
        while processes.contains(where:{$0.isRunning}) && Date()<deadline { usleep(100_000) }
        for process in processes where process.isRunning { kill(process.processIdentifier,SIGKILL) }
        for process in processes { process.waitUntilExit() }
    }

    static func run(arguments: [String], timeout: TimeInterval, token: UUID,fixtureHelperURL:URL? = nil) -> Data? {
        lock.lock(); let alreadyCancelled=cancelled.remove(token) != nil || !remoteEnabled; lock.unlock()
        guard !alreadyCancelled else { return nil }
        defer { lock.lock(); cancelled.remove(token); lock.unlock() }
        // A single one-shot SSH helper at a time; waiting requests remain cancellable.
        let gateDeadline=Date().addingTimeInterval(timeout)
        while !transportGate.try() {
            lock.lock();let aborted=cancelled.contains(token) || !remoteEnabled;lock.unlock()
            if aborted || Date()>=gateDeadline {return nil}
            usleep(10_000)
        }
        defer {transportGate.unlock()}
        lock.lock();let aborted=cancelled.contains(token) || !remoteEnabled;lock.unlock()
        guard !aborted,Date()<gateDeadline else{return nil}

        guard let script=fixtureHelperURL ?? Bundle.main.url(forResource:"shadow_collector",withExtension:"py"),
              FileManager.default.fileExists(atPath:script.path) else { return nil }
        let python = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
            ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendubar-collector-" + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdout = temporary.appendingPathComponent("stdout")
        let stderr = temporary.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdout.path, contents: nil,attributes:[.posixPermissions:0o600]),
              FileManager.default.createFile(atPath: stderr.path, contents: nil,attributes:[.posixPermissions:0o600]),
              let outHandle = try? FileHandle(forWritingTo: stdout),
              let errHandle = try? FileHandle(forWritingTo: stderr) else { return nil }
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        lock.lock()
        guard remoteEnabled,!cancelled.contains(token) else{lock.unlock();return nil}
        do {try process.run()} catch {lock.unlock();return nil}
        running[token] = process
        let cancelAfterLaunch=cancelled.contains(token)
        lock.unlock()
        if cancelAfterLaunch && process.isRunning { process.terminate() }
        defer {
            lock.lock()
            running.removeValue(forKey: token)
            cancelled.remove(token)
            lock.unlock()
        }
        if done.wait(timeout: .now() + max(0,gateDeadline.timeIntervalSinceNow)) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        guard !process.isRunning, process.terminationStatus == 0 else { return nil }
        guard let size=try? stdout.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=2*1024*1024 else{return nil}
        try? outHandle.synchronize()
        return try? Data(contentsOf: stdout)
    }
}

