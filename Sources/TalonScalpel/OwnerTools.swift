import Foundation

/// Runs other tools: owner cleanup commands (only on explicit request) and the read-only
/// listings the detectors use (`simctl list`, `tmutil listlocalsnapshots`, `git log`).
public enum Shell {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Resolves a bare command name on PATH (plus Homebrew's prefixes, which GUI apps don't inherit).
    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs `argv` to completion (or `timeout`), capturing output. Nil when the tool isn't installed.
    public static func run(_ argv: [String], timeout: TimeInterval = 60, environment: [String: String]? = nil) -> Output? {
        guard let first = argv.first, let exe = which(first) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Drain both pipes while it runs so a chatty tool can't block on a full pipe.
        let outData = Locked(Data()), errData = Locked(Data())
        let group = DispatchGroup()
        for (pipe, sink) in [(out, outData), (err, errData)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                sink.set(d)
                group.leave()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        group.wait()
        return Output(status: p.terminationStatus, stdout: String(decoding: outData.get(), as: UTF8.self),
                      stderr: String(decoding: errData.get(), as: UTF8.self))
    }
}

extension Shell {
    /// Runs `argv` on the user's own terminal, so a tool's confirmation prompt (`docker system prune`)
    /// reaches them. Returns the exit status, or nil when the tool isn't installed.
    public static func runAttached(_ argv: [String]) -> Int32? {
        guard let first = argv.first, let exe = which(first) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

extension OwnerTool {
    /// Whether the tool is installed.
    public var available: Bool { command.first.flatMap(Shell.which) != nil }

    /// Runs the cleanup command. Only ever called on an explicit request. Captured, output comes back
    /// verbatim; attached, the tool talks to the terminal directly so its own confirmations work.
    public func run(attached: Bool = false, timeout: TimeInterval = 600) -> Shell.Output? {
        if attached { return Shell.runAttached(command).map { Shell.Output(status: $0, stdout: "", stderr: "") } }
        return Shell.run(command, timeout: timeout)
    }

    // The catalogue: one place for every command scalpel may suggest.
    public static let brew = OwnerTool(name: "Homebrew", command: ["brew", "cleanup", "--prune=all"],
                                       note: "Removes old downloads and outdated versions; installed formulae stay.")
    public static let npm = OwnerTool(name: "npm", command: ["npm", "cache", "clean", "--force"],
                                      note: "Empties npm's download cache; packages re-download on next install.")
    public static let pnpm = OwnerTool(name: "pnpm", command: ["pnpm", "store", "prune"],
                                       note: "Removes packages no project references any more.")
    public static let yarn = OwnerTool(name: "Yarn", command: ["yarn", "cache", "clean"], note: "Empties Yarn's cache.")
    public static let bun = OwnerTool(name: "Bun", command: ["bun", "pm", "cache", "rm"], note: "Empties Bun's install cache.")
    public static let pip = OwnerTool(name: "pip", command: ["pip3", "cache", "purge"], note: "Empties pip's wheel and HTTP cache.")
    public static let uv = OwnerTool(name: "uv", command: ["uv", "cache", "prune"], note: "Removes unused entries from uv's cache.")
    public static let conda = OwnerTool(name: "conda", command: ["conda", "clean", "--all", "--yes"],
                                        note: "Removes unused packages and tarballs.")
    public static let pods = OwnerTool(name: "CocoaPods", command: ["pod", "cache", "clean", "--all"], note: "Empties the pod cache.")
    public static let simctl = OwnerTool(name: "Simulator", command: ["xcrun", "simctl", "delete", "unavailable"],
                                         note: "Deletes simulators whose runtime is no longer installed.")
    public static let docker = OwnerTool(name: "Docker", command: ["docker", "system", "prune"],
                                         note: "Lists what it will remove (stopped containers, dangling images, build cache) and asks first. `docker system df` shows usage.")

    public static func ollamaRemove(_ model: String) -> OwnerTool {
        OwnerTool(name: "Ollama", command: ["ollama", "rm", model], note: "Removes the model; blobs other models share stay.")
    }

    public static func deleteSnapshot(_ date: String) -> OwnerTool {
        OwnerTool(name: "Time Machine", command: ["tmutil", "deletelocalsnapshots", date],
                  note: "Deletes one local snapshot; space it alone held comes back.")
    }
}
