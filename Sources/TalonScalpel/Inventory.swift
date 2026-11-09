import AppKit
import CoreServices
import Foundation

/// Every app this Mac can still run, by bundle id — the "installed" side of the leftovers match.
/// A false "not installed" means deleting a live app's data, so this errs wide: main apps, their
/// nested helpers, login items, extensions and XPC services, running processes, and finally
/// LaunchServices, which knows apps in places no folder walk would look.
public struct AppInventory: Sendable {
    /// Lowercased.
    public var bundleIDs: Set<String>
    /// Ask LaunchServices about an id the folder walk didn't see. Swapped out in tests.
    public var launchServicesKnows: @Sendable (String) -> Bool

    public init(bundleIDs: Set<String>, launchServicesKnows: @escaping @Sendable (String) -> Bool = AppInventory.launchServices) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.launchServicesKnows = launchServicesKnows
    }

    /// LaunchServices, then Spotlight: between them they know apps in places no folder walk would look.
    public static let launchServices: @Sendable (String) -> Bool = { id in
        if !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).isEmpty { return true }
        guard AppInventory.bundleID(fromEntryName: id) == id else { return false }  // safe to quote: [A-Za-z0-9._-] only
        let query = "kMDItemCFBundleIdentifier == '\(id)'c" as CFString
        guard let q = MDQueryCreate(kCFAllocatorDefault, query, nil, nil),
              MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return false }
        return MDQueryGetResultCount(q) > 0
    }

    /// The folders apps install into: /Applications (including Setapp and Utilities), ~/Applications,
    /// Apple's own, Homebrew's Caskroom, and the vendor helpers under /Library.
    public static func searchRoots(home: String) -> [(path: String, depth: Int)] {
        [("/Applications", 3), (home + "/Applications", 3), ("/System/Applications", 2), ("/System/Library/CoreServices", 2),
         ("/opt/homebrew/Caskroom", 4), ("/usr/local/Caskroom", 4), ("/Library/Application Support", 4),
         (home + "/Library/Application Support/Setapp", 3)]
    }

    public static func discover(home: String = NSHomeDirectory()) -> AppInventory {
        var ids = RunningApps.bundleIDs()
        for (root, depth) in searchRoots(home: home) { collect(in: root, depth: depth, into: &ids) }
        return AppInventory(bundleIDs: ids)
    }

    static let bundleExtensions: Set<String> = ["app", "appex", "xpc", "bundle", "plugin", "prefPane", "saver", "systemextension"]

    /// Walks `root` for bundles, recording each bundle's id and every bundle nested inside it.
    static func collect(in root: String, depth: Int, into ids: inout Set<String>) {
        guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names {
            let path = root + "/" + name
            let ext = (name as NSString).pathExtension
            if bundleExtensions.contains(ext) {
                if let id = bundleID(ofBundleAt: path) { ids.insert(id.lowercased()) }
                if ext == "app" || ext == "systemextension" { collectNested(in: path + "/Contents", into: &ids) }
            } else if !name.hasPrefix("."), isDirectory(path) {
                collect(in: path, depth: depth - 1, into: &ids)
            }
        }
    }

    static func collectNested(in contents: String, into ids: inout Set<String>) {
        for sub in ["Library/LoginItems", "Library/LaunchServices", "Helpers", "XPCServices", "PlugIns", "Frameworks",
                    "Library/SystemExtensions", "Extensions", "MacOS"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: contents + "/" + sub) else { continue }
            for name in names where bundleExtensions.contains((name as NSString).pathExtension) {
                let path = contents + "/" + sub + "/" + name
                if let id = bundleID(ofBundleAt: path) { ids.insert(id.lowercased()) }
                if name.hasSuffix(".app") { collectNested(in: path + "/Contents", into: &ids) }
            }
        }
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Reads CFBundleIdentifier straight from Info.plist (cheaper than `Bundle`, and never cached stale).
    public static func bundleID(ofBundleAt path: String) -> String? {
        for plist in [path + "/Contents/Info.plist", path + "/Info.plist"] {
            guard let data = FileManager.default.contents(atPath: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            return dict["CFBundleIdentifier"] as? String
        }
        return nil
    }

    // MARK: - Matching

    /// Folders and files named by bundle id that an app leaves behind in the user's Library.
    public static let leftoverLocations = ["Library/Application Support", "Library/Containers", "Library/Caches", "Library/Preferences",
                                           "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs"]

    /// The bundle id a Library entry is named after, if it's named after one at all.
    public static func bundleID(fromEntryName name: String) -> String? {
        var n = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)) }
        let parts = n.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              n.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }),
              parts[0].unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
        else { return nil }
        return n
    }

    /// Apple's own ids are never leftovers: they ship with macOS, come back on their own, and some
    /// belong to services with no app bundle at all.
    public static func isApple(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.hasPrefix("com.apple.") || l.hasPrefix("group.com.apple.") || l.hasPrefix("systemgroup.com.apple.")
    }

    /// Ids that system components and embedded SDKs write under their *own* name from inside other
    /// apps — so "no app has this id" proves nothing. Found by spot-checking a real ~/Library: macOS's
    /// printing (org.cups.PrintingPrefs) and ChatGPT's analytics SDK (com.segment.storage.oai).
    public static let notApps = ["org.cups.", "org.webkit.", "org.chromium.", "com.github.electron", "org.python.",
                                 "org.sparkle-project.", "com.segment.", "io.sentry", "com.crashlytics", "com.mixpanel",
                                 "com.amplitude", "com.google.keystone", "com.google.googleupdater", "com.openssh",
                                 "org.openssh", "org.swift.", "org.gnu."]

    public static func isLibraryOrSystem(_ id: String) -> Bool {
        let l = id.lowercased()
        return notApps.contains { l.hasPrefix($0) }
    }

    /// Why `id` still counts as installed, or nil when nothing claims it. Deliberately generous:
    /// any related id (a helper, the parent app, the same vendor) keeps an item off the list.
    public func claim(_ id: String) -> String? {
        let l = id.lowercased()
        if AppInventory.isApple(l) { return "an Apple id" }
        if AppInventory.isLibraryOrSystem(l) { return "written by a system component or an SDK inside other apps" }
        if bundleIDs.contains(l) { return "installed" }
        for b in bundleIDs {
            if l.hasPrefix(b + ".") { return "belongs to installed \(b)" }
            if b.hasPrefix(l + ".") { return "shared by installed \(b)" }
        }
        let vendor = l.split(separator: ".").prefix(2).joined(separator: ".")
        if let sibling = bundleIDs.first(where: { $0.hasPrefix(vendor + ".") }) {
            return "same vendor as installed \(sibling) — vendors share data between apps"
        }
        if launchServicesKnows(id) { return "LaunchServices or Spotlight knows an app with this id" }
        return nil
    }
}
