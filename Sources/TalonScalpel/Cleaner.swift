import Foundation

/// Carries out findings: each one by its own removal method, each through the cut checks.
public struct Cleaner: Sendable {
    public var holding: HoldingArea
    /// Owner tools run only when this is set — a cut never quietly runs someone else's command.
    public var runOwnerTools = false
    /// Give owner tools the terminal (their own prompts work) instead of capturing their output.
    public var attachOwnerTools = false

    public init(holding: HoldingArea = HoldingArea(), runOwnerTools: Bool = false, attachOwnerTools: Bool = false) {
        self.holding = holding
        self.runOwnerTools = runOwnerTools
        self.attachOwnerTools = attachOwnerTools
    }

    public enum Outcome: Sendable {
        case held(CutManifest)
        case trashed([String])
        case cloned(freed: UInt64, count: Int, failures: [String])
        case ran(OwnerTool, Shell.Output)
        case skipped(String)
        case refused(String)
    }

    public struct Result: Sendable {
        public var finding: Finding
        public var outcome: Outcome
    }

    public func apply(_ f: Finding) -> Result {
        Result(finding: f, outcome: outcome(f))
    }

    private func outcome(_ f: Finding) -> Outcome {
        if f.tier == .protected { return .refused("protected — never cleaned") }
        switch f.removal {
        case .never:
            return .refused("never cleaned")
        case .holdingArea:
            do {
                let req = f.paths.map { HoldingArea.Request(path: $0, tier: f.tier, ownerBundleID: f.ownerBundleID, ownerName: f.owner,
                                                            sizes: f.paths.count == 1 ? f.sizes : nil) }
                return .held(try holding.cut(req, category: f.category, findingID: f.id, title: f.title))
            } catch {
                return .refused("\(error)")
            }
        case .trash:
            do {
                for p in f.paths { try holding.guardrails.check(p, tier: f.tier, ownerBundleID: f.ownerBundleID, ownerName: f.owner) }
                var done: [String] = []
                for p in f.paths {
                    var out: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out)
                    done.append(out?.path ?? p)
                }
                return .trashed(done)
            } catch {
                return .refused("\(error)")
            }
        case .cloneReplace:
            guard let keep = f.paths.first else { return .skipped("nothing to keep") }
            var freed: UInt64 = 0, count = 0
            var failures: [String] = []
            for dup in f.paths.dropFirst() {
                do {
                    try holding.guardrails.check(dup, tier: f.tier)
                    freed += try Duplicates.replaceWithClone(original: keep, duplicate: dup)
                    count += 1
                } catch {
                    failures.append("\(error)")
                }
            }
            return .cloned(freed: freed, count: count, failures: failures)
        case .ownerTool(let tool):
            guard runOwnerTools else { return .skipped("owner tool — run with --run-tools, or yourself: \(tool.display)") }
            guard tool.available else { return .skipped("\(tool.command.first ?? tool.name) isn't installed") }
            if let id = f.ownerBundleID, holding.guardrails.checkRunningApps, RunningApps.bundleIDs().contains(id.lowercased()) {
                return .refused("\(f.owner ?? id) is running — quit it first")
            }
            guard let out = tool.run(attached: attachOwnerTools) else { return .refused("couldn't start \(tool.display)") }
            return .ran(tool, out)
        }
    }
}
