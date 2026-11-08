# Core language for Talon (talond daemon + `talon` CLI + shared model)

Research date: 2026-11-08. Scope: Swift 6 alone vs Swift + C/ObjC shims vs Rust core + SwiftUI (UniFFI / swift-bridge) vs Zig/C vs Go. Phase-0 feasibility of each private API from Swift/C is already established and is not re-verified here.

**Bottom line (for the report writer):** Use **Swift 6.4 plus a small C/ObjC shim target** (one SwiftPM package: `TalonCShims` C target, `TalonCore` Swift library, `talond` and `talon` executables, app and widget depending on `TalonCore`). Rust is the only serious alternative. It is a good fit for the sampler (macmon proves it), but for one person it adds a second toolchain, a code-generated FFI layer whose Swift 6 async support is still incomplete, and no way to share model types natively with SwiftUI or WidgetKit. Go and Zig/C lose on XPC/CF ergonomics and on code sharing with the SwiftUI app.

---

## Q1. How easy is it to call private C APIs, CoreFoundation, IOKit CFPlugIns, IOReport and XPC from each language?

### Takeaway
Swift (with a module map or a C shim target) is the only candidate where CF, IOKit, NSXPCConnection and private C symbols all work natively in one language. Rust is a close second for C/CF/IOKit, thanks to the auto-generated `objc2-*` crates, but NSXPCConnection, `@objc` protocols and secure coding are clumsy there. Go needs cgo for everything. Zig's `@cImport` handles C well but has nothing for ObjC or XPC.

### Cited Findings
- macmon, a sudoless Apple Silicon monitor written in Rust, reads CPU/GPU/ANE power, temperatures and memory "through a private macOS API" (IOReport and the AppleCLPC driver). The library is published on crates.io, so private IOReport access from Rust clearly works in production. — [vladkens/macmon](https://github.com/vladkens/macmon); [docs.rs macmon readme](https://docs.rs/crate/macmon/latest/source/readme.md)
- `objc2-io-kit` (0.3.x) provides generated bindings to IOKit, built on `objc2-core-foundation` types (`CFDictionary`, `CFRetained`). lib.rs still describes the crate as unstable, and 0.3.1 dates from April 2025. The older `IOKit-sys` crate is hand-maintained raw declarations with no abstractions. — [docs.rs objc2-io-kit](https://docs.rs/crate/objc2-io-kit/latest/source/src/lib.rs); [lib.rs objc2-io-kit](https://lib.rs/crates/objc2-io-kit); [IOKit-sys README](https://rust-digger.code-maven.com/src/IOKit-sys-0.1.5/README.md)
- Go: `charlie0129/gosmc`, the SMC library behind the battery limiter `batt`, says "The low-level SMC calls use CGO and IOKit" and lists "macOS with CGO enabled" as a requirement. Key lookup, caching and encoding are in Go. It was derived from smcFanControl's C code. — [gosmc](https://github.com/charlie0129/gosmc); [batt](https://github.com/charlie0129/batt)
- `batt`'s daemon and its CLI/GUI clients talk over a **Unix domain socket**, not XPC. This is consistent with Go having no practical NSXPCConnection path. — [batt](https://github.com/charlie0129/batt)
- Swift 6.3 (24 March 2026) added `@c`, which exposes Swift functions and enums to C with a generated header declaration and an optional custom C name. Combined with `@implementation`, it lets Swift implement a function declared in a C header, with the signature checked. This makes it easy to write C callbacks (signal handlers, CF callbacks, IOKit notification callbacks) in Swift while keeping a C header as the contract. — [Swift 6.3 Released](https://swift.org/blog/swift-6.3-released/)
- Swift 6.3 also added module selectors (`ModuleA::getValue()`), which are useful when a private-API shim and an SDK module declare clashing names. — [Swift 6.3 Released](https://swift.org/blog/swift-6.3-released/)
- Swift 6.4 / Xcode 27: the dependency scanner "now requires every Clang module reachable from one scan to have a unique name". A hand-written module map for private headers (for example an `IOReport` module) must not collide with any SDK module name. Xcode 27 beta 2 also adds Swift-native `stat`/`lstat`/`fstat`/`fstatat` APIs (`FilePath.stat()`). — [Michael Tsai, Swift 6.4 (2026-06-24)](https://mjtsai.com/blog/2026/06/24/swift-6-4/)

### Inferences
- From general knowledge, not re-verified this session:
  - Swift can declare private symbols three ways:
    1. A C header in a SwiftPM C target or module map (preferred: `IOReportCopyChannelsInGroup`, `memorystatus_control`, `responsibility_get_pid_responsible_for_pid`).
    2. `@_silgen_name` (fragile: Swift calling convention, underscored attribute).
    3. `dlsym` plus `unsafeBitCast` to a `@convention(c)` function type (already used in phase 0).
  - The C-target route is the most robust and works with Swift Testing.
  - IOKit CFPlugIn COM-style vtables (IONVMeSMART) are the ugliest part in every language. A 30–80 line C/ObjC shim that returns a plain struct is easier to keep correct than vtable walking in Swift or Rust.
- NSXPCConnection with `@objc` protocols and `NSSecureCoding` is natural in Swift. In Rust it would need `objc2-foundation` plus manual protocol declaration. In Go or Zig it would need an ObjC shim, which defeats the point. Choosing anything other than Swift for talond therefore pushes IPC to a Unix socket, raw `xpc_connection_t` (C API), or an ObjC shim.
- Zig's `@cImport` would parse libproc/IOKit C headers well. CF works as plain C, but there is no ObjC or blocks story, so XPC and IOKit notification blocks need C shims. I found no notable Zig macOS monitoring tool.

### Gaps
- No first-hand 2026 benchmark or write-up comparing NSXPCConnection usage from Rust (objc2) and from Swift.
- I did not inspect macmon's source to see whether it uses `objc2-core-foundation`, the `core-foundation` crate, or hand-written `extern` blocks for IOReport.

---

## Q2. What do real open-source macOS monitoring and limiting tools use, and why?

### Takeaway
The ecosystem is split: GUI apps (Stats) are Swift with C helpers; CLI/TUI samplers are Rust (macmon), C++ (btop) or Python wrapping `powermetrics` (asitop); battery limiters with root daemons are Go (batt). None publishes a language-choice rationale. The lessons are about private API drift and sampling cost, not language.

### Cited Findings
- **Stats (exelban/stats)**, the most popular menu-bar monitor, is an Xcode project with `Kit`, `Modules`, `SMC`, `Widgets` and `LaunchAtLogin` folders and an "SMC helper" that must be removed on uninstall. Its README says sensors and Bluetooth are the most expensive modules, and disabling them can reduce CPU usage by "up to 50% in some cases". Apple changes SMC sensor keys with each SoC, and Apple Silicon "sensors" are thermal zones, not cores. Widget data is off by default because of high load on `chronod`. — [exelban/stats](https://github.com/exelban/stats)
- **macmon** (Rust) runs sudoless and offers a TUI, a JSON pipe, a Prometheus exporter and a library crate. **Lesson relevant to Talon:** on macOS 27, the IOReport "Energy Model" counters it used for CPU/ANE power stopped updating. They now require a private entitlement that only Apple-signed `powermetrics` has. macmon switched to hidden AppleCLPC driver energy reports with opaque IDs and undocumented, per-chip mappings, and warns that zero CPU/ANE readings can mean "counters unavailable". The README lists M5 and M5 Pro/Max tiers. — [vladkens/macmon](https://github.com/vladkens/macmon)
- **asitop** is Python. It shells out to `powermetrics`, so it "requires `sudo`", and hardcodes values such as TDP and ANE max power. — [tlkh/asitop](https://github.com/tlkh/asitop)
- **btop** is C++23 and needs GCC 14 or Clang 19 on macOS. GPU monitoring is supported on Apple Silicon. A macOS setuid option removes the need for `sudo` to see other users' processes. — [aristocratos/btop](https://github.com/aristocratos/btop)
- **batt** is Go, with a root daemon, a CLI client, a menu-bar GUI and a Unix-socket IPC. It chooses among legacy, firmware, native (PowerUIAgent upper target) and adapter backends based on available SMC keys. A note dated 17 February 2026 covers macOS 26.4 native charge limiting. — [charlie0129/batt](https://github.com/charlie0129/batt)

### Inferences
- batt has the same shape as Talon: a root daemon, a CLI client and a menu-bar GUI. In Go it ended up with cgo for IOKit, a Unix socket instead of XPC, and (presumably) a separate GUI codebase. Talon already has NSXPCConnection working, which Swift handles natively.
- macmon shows a Rust sampler can track Apple's private-API changes quickly. The macOS 27 breakage is a platform risk that applies to any language, so it is not an argument for Rust. **Flag for the wider report:** if Talon relies on IOReport Energy Model channels for CPU/ANE power, re-check them on macOS 27. Phase 0 proved IOReport access in general, but macmon reports this specific group is now entitlement-gated.
- Objective-See tools and cpulimit were not fetched. From general knowledge, Objective-See tools are mostly ObjC with newer Swift components, and cpulimit is plain C using SIGSTOP/SIGCONT duty cycling, the same technique Talon plans.

### Gaps
- No language-choice rationale is published by any of these projects.
- I could not see the Stats language percentage breakdown (the GitHub sidebar was not captured), its latest release date, or macmon's `docs/clpc-discovery.md`.
- Objective-See tools, cpulimit, AlDente and iStat Menus were not verified this session.

---

## Q3. Runtime overhead and memory footprint of a long-running daemon

### Takeaway
I found no credible published measurement comparing the idle footprint of Swift and Rust daemons on macOS. For a 1 Hz sampler the difference is likely to be a few MB of RSS and negligible CPU. Phase 0 already measured 0.35% CPU for the Swift sweep, which settles the CPU question.

### Cited Findings
- No direct Swift-vs-Rust idle-RSS comparison turned up. The suggested method is to compare `footprint`/`leaks` with `ps` RSS for equivalent daemons and an empty hello-world in each language. — (search result synthesis; no primary benchmark found)
- A Swift Forums thread notes that RSS can greatly exceed live heap in Swift processes, and recommends macOS heap tools (`heap`, `leaks`, `footprint`) to tell allocated-but-unused memory from live memory. — [Swift Forums: Swift RSS much greater than heap](https://forums.swift.org/t/swift-rss-memory-consumption-is-much-greater-than-heap-memory/58837) (older thread, about 2022; possibly outdated)
- A Go issue reports Go idle RSS staying high on macOS, and a commenter suggests macOS measures RSS differently than Linux. — [golang/go#24892](https://golang.org/issue/24892) (2018, outdated, but illustrates GC-runtime retention)
- A Substack benchmark found Swift about 2x slower than Rust on a matrix-multiply test on Apple Silicon. This is a throughput benchmark, not relevant to an I/O- and syscall-bound 1 Hz sampler. — [erelo.substack.com](https://erelo.substack.com/p/benchmarking-swift-vs-rust-on-apple)
- Swift 6.2 added `InlineArray` (fixed-size, no heap) and `Span` (compile-time-checked, zero-overhead contiguous access). These let a Swift sampler keep per-tick buffers (pid arrays, `rusage_info_v6` arrays) allocation-free. — [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
- Swift 6.4 adds a safer `withUnsafeTemporaryAllocation` (raw and typed variants) and new borrowed/mutable reference types generalizing `inout`/`Span`. — [Michael Tsai, Swift 6.4](https://mjtsai.com/blog/2026/06/24/swift-6-4/)

### Inferences
- The Swift runtime and stdlib ship in the macOS dyld shared cache, so a Swift daemon pays little private memory for them. Importing Foundation adds a few MB of mostly shared/clean pages.
- A Rust daemon would probably have a slightly smaller private footprint (no ARC traffic, no ObjC runtime unless objc2 is used), but on a 16 GB machine this is immaterial for one daemon.
- Go's GC and its goroutine scheduler threads add baseline RSS. Go also controls signal handling (`os/signal`), which complicates direct `SIGSTOP`/`SIGCONT` to children and `posix_spawn` with jetsam attributes. Go's `syscall`/`os/exec` does not expose `posix_spawnattr_setjetsam_ext`, so cgo would be required.
- The real overhead risk is ARC retain/release in hot loops over ~700 pids. Mitigations: keep sampler loops over value types and `InlineArray`/`Span`, avoid `NSDictionary` bridging per tick, and reuse buffers. This is a design discipline, not a language-switch reason.

### Gaps
- No measured idle `footprint` numbers for Swift vs Rust vs Go daemons on macOS 26 or 27. If it matters, Talon should measure its own `talond` with `footprint -p` (a cheap phase-0 addition).

---

## Q4. Swift 6 strict-concurrency friction for low-level, signal-heavy, C-pointer-heavy code

### Takeaway
The friction is real but manageable, and it has improved steadily: 6.2 approachable concurrency, the 6.0 Synchronization module, and 6.4's `~Sendable`, cancellation shields and `@diagnose`. The winning pattern is to keep the C-pointer and signal code synchronous inside one owner (an actor or a `Mutex`-guarded struct on a dedicated `DispatchQueue`/thread), and expose only `Sendable` value snapshots to the rest of the code.

### Cited Findings
- **Synchronization module**: `Mutex` (SE-0433) wraps `os_unfair_lock` on Apple platforms and protects user-defined state. `Atomic` is also there. Both require macOS 15 or later, which is fine for macOS 27. — [SE-0433](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md); [Apple Synchronization docs](https://developer.apple.com/documentation/synchronization.md); [Swift Forums: Mutex restricted to iOS 18](https://forums.swift.org/t/sychronization-mutex-t-in-standard-library-but-restricted-to-ios-18/74803)
- SE-0331 removed `Sendable` from unsafe pointer types. SE-0412 introduced `nonisolated(unsafe)` for globals and storage. Raw `UnsafeMutablePointer`/`CFTypeRef` cannot cross isolation boundaries without explicit unsafe opt-outs. — [Apple Developer Forums thread listing evolution proposals](https://developer.apple.com/forums/thread/768776)
- Swift 6.2 (15 September 2025) added "approachable concurrency":
  - Opt-in default `MainActor` isolation (aimed at scripts, UI and executable targets).
  - `nonisolated async` functions run in the caller's context instead of hopping to the global executor.
  - `@concurrent` for explicitly parallel work.
  - Opt-in strict memory safety.
  — [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/); [InfoQ](https://www.infoq.com/news/2025/08/swift62-approachable-concurrency)
- A Swift Forums thread on migrating a 60K-line app describes approachable concurrency as removing "many headaches", while acknowledging the migration will still be frustrating. — [Swift Forums: Questions about Swift 6 Concurrency](https://forums.swift.org/t/questions-about-swift-6-concurrency/82045)
- Swift 6.4 (WWDC26, Xcode 27) adds:
  - SE-0493: `async` calls in `defer`.
  - SE-0518: `~Sendable`, to mark types explicitly non-Sendable.
  - SE-0520: warns when a throwing `Task` handle is discarded.
  - SE-0530: async `Result`.
  - `withTaskCancellationShield`.
  - `@diagnose`, to audit unsafe code per region.
  Commenters complain that `Sendable` complexity and compile times keep growing; Michael Tsai measured only a 0.3% faster build on Xcode 27 beta 3. — [Michael Tsai, Swift 6.4](https://mjtsai.com/blog/2026/06/24/swift-6-4/); [Kodeco: What's new in Swift 6.4](https://www.kodeco.com/53754585-what-s-new-in-swift-6-4)
- Third-party write-ups say 6.4 brings no new language mode, and that new concurrency diagnostics arrive as warnings rather than errors. This is not verified against swift.org. — [search synthesis of Kodeco / blog coverage](https://www.kodeco.com/53754585-what-s-new-in-swift-6-4)

### Inferences
Concrete patterns for talond. These are inferences from the features above plus general knowledge.
- **Signals:** do not install POSIX signal handlers that touch Swift state. Use `DispatchSource.makeSignalSource` (after `signal(SIGTERM, SIG_IGN)`) for the daemon's own SIGTERM/SIGHUP. Sending signals (`kill(pid, SIGSTOP)`) is a plain syscall with no concurrency issue.
- **Duty-cycling SIGSTOP/SIGCONT** needs precise timing. Run it on a dedicated serial `DispatchQueue` or a thread with a `DispatchSourceTimer`, not cooperative-pool `Task.sleep`. Keep its state in a `Mutex<...>` or confine it to that queue. A crash must never leave a process stopped, so add a SIGCONT-all sweep in the termination path and on daemon start.
- **C pointers / CF objects:**
  - Wrap each private-API resource (IOReport subscription, `IOHIDEventSystemClient`, the NVMe plugin interface) in a `final class` that owns it.
  - Mark that class `@unchecked Sendable` only if it is internally locked, or better, keep it non-Sendable (6.4 `~Sendable`) and confined to the sampler actor.
  - Return `Sendable` structs (`ProcessSample`, `ThermalSample`).
- **Default MainActor isolation** should be on for the app target but off for `talond`/`TalonCore`. Daemon code should be nonisolated by default with explicit actors.
- Remaining friction to expect: `nonisolated(unsafe)` for a few global function pointers resolved via `dlsym`; `@Sendable` closure requirements on XPC reply handlers; NSXPCConnection's ObjC-era API needing `@preconcurrency import Foundation` or careful wrapping.

### Gaps
- I did not retrieve official swift.org Swift 6.4 release notes; the 6.4 details come from Michael Tsai's roundup and Kodeco. Release status: some sources say 6.4 shipped with Xcode 27 in September 2026, but no primary confirmation was found.
- I found no specific forum thread on signal-handling patterns under Swift 6 strict concurrency.

---

## Q5. Rust core with a SwiftUI shell in 2026: FFI cost and complexity, and is it worth it for one person?

### Takeaway
It works and is well trodden, but for a personal macOS-only project it is mostly cost:
- UniFFI's Swift 6 support is still officially "partial", and async is not `Sendable`.
- SwiftUI observation needs hand-written wrapper classes.
- Xcode integration (static lib or xcframework, module map, a build-phase script) is a recurring source of trouble.

Rust's main benefits, cross-platform reach and memory safety, matter little here, and Swift 6 now offers `Span` and opt-in strict memory safety.

### Cited Findings
- UniFFI Swift docs (identical wording in the 0.29–0.32 and `latest` versions):
  - Swift 6 support is "partial". Most generated code conforms to `Sendable`, but "async code will not", tracked in issue #2448.
  - Foreign-trait implementations must be `Sendable`.
  - Rust panics in non-throwing Swift functions become uncatchable fatal errors.
  - Generation produces a C header, a modulemap and a Swift source file per crate.
  — [UniFFI Swift overview (latest)](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html); [0.32](https://mozilla.github.io/uniffi-rs/0.32/swift/overview.html)
- UniFFI issue #2046 (2024): generated code failed under Swift 6 strict concurrency because callback plumbing used static mutable state. — [uniffi-rs#2046](https://redirect.github.com/mozilla/uniffi-rs/issues/2046)
- UniFFI issue #2145: no built-in support for updating SwiftUI views when UniFFI objects change. The suggested approach is a Swift wrapper class with SwiftUI property wrappers, because UniFFI does not support Swift property wrappers. — [uniffi-rs#2145](https://github.com/mozilla/uniffi-rs/issues/2145)
- A 2025 blog post on SwiftUI with UniFFI is "mostly focused on the troubleshooting aspect". It reports build problems with Xcode 26 and Swift 6, including linking the static library. — [Integrating Rust with SwiftUI using UniFFI](https://artmis-blog.netlify.app/posts/integrating-rust-with-swiftui)
- UniFFI describes itself as developed alongside its initial consumers, "changing rapidly", with "a number of sharp edges". — [uniffi-rs (mirror)](https://github.com/toursslivers/uniffi-rs)
- **swift-bridge** (0.1.59) declares a bridge module via macro and generates Swift and C glue at build time. It claims to be safer and more ergonomic than hand-written FFI, but I found no 2025–2026 hands-on SwiftUI report, and it is still pre-1.0. — [swift-bridge docs.rs](https://docs.rs/crate/swift-bridge/latest/source/SwiftRustIntegrationTestRunner/SwiftRustIntegrationTestRunnerSwiftRustIntegrationTestRunner.swift)
- Ockam Portals (SwiftUI + Rust on macOS) found no off-the-shelf bridge suitable at the time and statically linked the Rust lib. They valued SwiftUI's constructs enough to accept the cost. — [HackerNoon: Encrypted Portals](https://sia.hackernoon.com/encrypted-portals-how-we-created-a-swift-app-that-uses-rust) (likely 2023, possibly outdated)
- The "Ghost" postmortem needed a separate Swift daemon anyway, because NSWorkspace and Accessibility require a native macOS process. Its Rust side talked to the daemon over WebSocket rather than FFI. — [futurecraft-pro postmortem](https://futurecraft-pro.pages.dev/blog/ambient-ai-mac-tauri-swift-ollama-postmortem)
- LY Corporation used UniFFI to avoid hand-written boilerplate, for a cross-platform (iOS and Android) goal. — [LY Corp tech blog (Oct 2024)](https://techblog.lycorp.co.jp/en/20241002a)

### Inferences
- Talon's process boundary already runs through XPC (daemon to app). A Rust talond would not need UniFFI for the app at all; it would need an IPC protocol. That means either an ObjC/Swift XPC shim inside a Rust daemon (awkward) or a Unix socket plus a serialization format (JSON/CBOR/protobuf) defined twice, once in Rust and once in Swift. The UniFFI question then only arises for sharing model and formatting code with the app or widget.
- Debugging across Rust and Swift in LLDB works but is a worse experience: two symbol styles, panics crossing FFI become aborts, and Swift Testing cannot test Rust internals directly, so two test suites are needed.
- Build: `cargo` invoked from an Xcode Run Script or a SwiftPM binary target (xcframework), plus per-arch builds. This is manageable but becomes a standing maintenance cost with each Xcode release; Xcode 26 broke at least one documented setup (above).
- Verdict: a two-language setup is not worth it for this project. The exception is if the developer wants to learn Rust for fun, in which case a narrowly scoped Rust **CLI-only** tool (like macmon) is a cleaner experiment than splitting the core.

### Gaps
- I could not confirm whether UniFFI issue #2448 (async `Sendable`) was resolved by late 2026; the docs still say no. The latest UniFFI version number was not visible on the docs page (the docs list 0.32).
- No 2025–2026 swift-bridge SwiftUI production report was found.

---

## Q6. Swift C++ interop and Swift Testing maturity (2025–2026)

### Takeaway
Swift Testing is mature enough to be the default for Talon. Exit tests, which arrived in 6.2, suit testing a CLI or crash paths, and 6.3 added warnings, cancellation and attachments. C++ interop is stable and improving but irrelevant here, because none of the private APIs Talon uses are C++.

### Cited Findings
- Swift 6.2 Testing: exit tests (verify code terminates under conditions such as a failed precondition, run in a separate process), attachments (logs/JSON in reports), and raw-identifier test names. — [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
- Swift 6.3 Testing: warning-severity issues (`Issue.record(..., severity:)`), `try Test.cancel()` for skipping individual parameterized arguments, and image attachments. Swift 6.3 also previews Swift Build integrated into SwiftPM. — [Swift 6.3 Released](https://swift.org/blog/swift-6.3-released/)
- Swift 6.3.2 warns when `@Test` gets unsupported generic type parameters, and on Linux C++ interop can import headers using C++23 features such as `<expected>`. — [Announcing Swift 6.3.2](https://forums.swift.org/t/announcing-swift-6-3-2/86698)
- Swift 6.2 C++ interop: `Span` can be used with C++ APIs through header annotations. — [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
- The Swift 6.4 coverage I found does not mention Testing or C++ interop changes. — [Michael Tsai, Swift 6.4](https://mjtsai.com/blog/2026/06/24/swift-6-4/)

### Inferences
- Exit tests can cover "jetsam cap kills child" and "SIGSTOP'd child is resumed when talon run is killed" style tests without crashing the test runner.
- Parameterized tests suit parsers such as `--mem 6G` and policy tables.
- C++ interop matters only if Talon adopts a C++ library. btop's collectors could be referenced but not linked (Apache-2.0, C++23), so it is not a factor.

### Gaps
- No primary 6.4 Testing notes were found.

---

## Q7. Code sharing between daemon, CLI, app and widget extension

### Takeaway
Only all-Swift gives one source of truth for model types (samples, policies, limits) across all four targets with no codegen. Rust can share the core with the app only through UniFFI-generated wrappers, which need Swift wrapper classes for SwiftUI and probably duplicated `Codable` widget/timeline types. Go and Zig share nothing with the app.

### Cited Findings
- WidgetKit and menu-bar widgets run as separate processes. Stats turns widget data off by default because widget refreshes load `chronod`. This argues for keeping widget payloads small `Codable` snapshots shared via App Group, not live FFI objects. — [exelban/stats](https://github.com/exelban/stats)
- UniFFI objects need hand-written Swift wrapper classes to drive SwiftUI updates. — [uniffi-rs#2145](https://github.com/mozilla/uniffi-rs/issues/2145)
- batt (Go) ships daemon, CLI and GUI as separate binaries over a Unix socket, with feature detection exposed to both clients. — [charlie0129/batt](https://github.com/charlie0129/batt)

### Inferences
Recommended package layout, all Swift. This is inference and design, not sourced.
- `TalonCShims` (C target): module map or headers for:
  - `proc_*` and `memorystatus_control`
  - `posix_spawnattr_setjetsam_ext`
  - the IOReport/IOHIDEventSystem private declarations
  - a small C or ObjC file for the IONVMeSMART CFPlugIn vtable dance
- `TalonModel` (pure Swift, `Sendable`/`Codable` structs, no Foundation-heavy dependencies), linked by all four targets:
  - `ProcessSample`, `ThermalSample`, `Policy`, `MemLimit`, `TalonXPCProtocol`
- `TalonCore` (sampler, enforcer, policy engine; depends on CShims and Model), linked by talond and the CLI.
- Executables: `talond` and `talon` (via swift-argument-parser).
- Xcode app and widget extension: depend only on `TalonModel` plus a thin XPC client.
- `talon run --mem 6G -- cmd` can call `posix_spawn` with the jetsam attribute directly when run as root, or ask talond over XPC. Either way, the same `TalonCore` code is used.

Comparison summary:

| Criterion | Swift + C shims | Swift only | Rust core + SwiftUI | Go | Zig/C |
|---|---|---|---|---|---|
| Private C / CF / IOKit | Excellent (C target) | Good (`@_silgen_name` / dlsym; fragile) | Good (`objc2-*`, bindgen; macmon proves it) | Poor (cgo for everything) | Good for C; no ObjC |
| NSXPCConnection | Native | Native | Awkward (objc2 or socket instead) | No (socket) | No (socket or C XPC) |
| Signals / posix_spawn / jetsam | Direct syscalls; DispatchSource | Same | Direct (libc crate) | Runtime owns signals; cgo for jetsam | Direct |
| Concurrency safety | Swift 6 strict; some unsafe opt-outs | Same | Borrow checker; best in class | GC + goroutines; data races possible | None |
| Daemon footprint | Small (runtime in OS) | Same | Smallest | Larger (GC runtime) | Smallest |
| Sharing with SwiftUI and widget | Native, one model | Native | UniFFI codegen + wrappers | None | None |
| Toolchains / build | 1 (Xcode/SwiftPM) | 1 | 2 (cargo + Xcode) | 2 | 2 |
| Testing | Swift Testing (exit tests) | Same | cargo test + Swift Testing | go test | zig test |
| Fun / learning | Medium | Medium | High | Low–medium | High but tedious |

### Gaps
- I did not verify current WidgetKit constraints on macOS 27 (App Group sharing, extension memory limits); another researcher may cover them.

---

## Recommendation (synthesis)

1. **Primary choice: Swift 6.4 plus a minimal C/ObjC shim target.**
   - Strict concurrency is on in `TalonCore` and `talond`, with default MainActor isolation only in the app.
   - Sampler and enforcer state are confined to one actor or a dedicated serial queue with `Mutex`.
   - Hot loops use `InlineArray`/`Span`, and only `Sendable` snapshots cross boundaries.
   - Private declarations go in C headers (not `@_silgen_name`), and the CFPlugIn vtable work goes in C/ObjC.
   - Watch for the Xcode 27 unique-Clang-module-name rule.
   - Tests use Swift Testing, including exit tests.
2. **Viable alternative: Rust** for `talond` and the CLI, only if learning Rust is itself a goal. Expect a Unix-socket or C-XPC IPC instead of NSXPCConnection, duplicated model types (or UniFFI with partial Swift 6 async support), and two toolchains.
3. **Not recommended:** Go (cgo for every macOS call, no XPC, its runtime owns signals) and Zig/C (no ObjC/XPC; tedious for a GUI-coupled model).
4. **Cross-cutting risk:** private-API drift. macmon reports that macOS 27 gated the IOReport Energy Model counters behind an Apple-only entitlement. This risk is the same in every language; keep each private API behind a small, testable shim so breakage stays contained.
