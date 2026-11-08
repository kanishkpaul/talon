// Spike 5b — client: talk to talond over XPC and have it hard-cap a running process.
// Usage: helper-client <path-to-memcap>

import Foundation

@main
struct Client {
    static func main() {
        guard CommandLine.arguments.count > 1 else { print("usage: helper-client <path-to-memcap>"); exit(64) }
        let memcap = CommandLine.arguments[1]

        let conn = NSXPCConnection(machServiceName: helperMachName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        let done = DispatchSemaphore(value: 0)
        var failed = false
        let helper = conn.remoteObjectProxyWithErrorHandler { err in
            print("  ❌ XPC error: \(err.localizedDescription)"); failed = true; done.signal()
        } as! HelperProtocol

        // 1. Reachability + privileges
        helper.status { print("  ✅ \($0)"); done.signal() }
        done.wait()
        if failed { exit(1) }

        // 2. Safety rule: must refuse to touch a system process (launchd, pid 1)
        helper.capMemory(pid: 1, megabytes: 300) { rc, msg in
            print(rc == EPERM ? "  ✅ safety rule held — \(msg)" : "  ❌ safety rule FAILED — \(msg)"); done.signal()
        }
        done.wait()

        // 3. Hard-cap an already-running process
        let hog = Process()
        hog.executableURL = URL(fileURLWithPath: memcap)
        hog.arguments = ["hog"]
        let pipe = Pipe()
        hog.standardOutput = pipe
        try! hog.run()
        helper.capMemory(pid: hog.processIdentifier, megabytes: 300) { _, msg in print("  → \(msg)"); done.signal() }
        done.wait()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        hog.waitUntilExit()
        let last = out.split(separator: "\n").last.map(String.init) ?? "0"
        if hog.terminationReason == .uncaughtSignal {
            print("  ✅ running process KILLED (signal \(hog.terminationStatus)) at \(last) MB — hard cap via helper WORKS")
        } else {
            print("  ❌ running process NOT capped — reached \(last) MB")
        }
        conn.invalidate()
    }
}
