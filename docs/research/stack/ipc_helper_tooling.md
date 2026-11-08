# IPC, Privileged-Helper Packaging, Project Structure and Build Tooling for Talon (macOS 27, personal, no paid account)

Research date: 2026-11-08. About 18 tool calls. Primary sources are Apple docs and Apple Developer Forums threads by Quinn "The Eskimo!" (DTS), dated Sep 2025 to Feb 2026, plus CVE records for 2025–2026 helper vulnerabilities. Many points specific to macOS 27 / Xcode 27 could not be confirmed. Every such point is flagged.

## IPC: NSXPCConnection vs Swift XPC API (XPCSession/XPCListener/XPCPeerRequirement) vs sockets/HTTP

### Takeaway
Use XPC over a launchd `MachServices` name. The Swift XPC API is now the natural fit for a Swift 6 codebase. `XPCSession(machService:options:)` has been available since macOS 14 and sends and receives `Codable` values directly. On macOS 26+, `XPCListener(service:requirement:)` lets the daemon drop peers that fail a code-signing requirement before any handler runs. NSXPCConnection, which the phase-0 spike used, still works, but it needs `@objc` protocols and NSSecureCoding. A Unix-socket design (batt's model) is a valid fallback that does not depend on signing. With a socket, though, you build your own peer authentication with `getpeereid`/`LOCAL_PEERTOKEN`, and you give up launchd on-demand launch.

### Cited Findings
- `XPCSession.init(machService:targetQueue:options:cancellationHandler:)` "Establishes a connection to a launch agent or launch daemon". It is available on **macOS 14.0+** and annotated `@preconcurrency`, with a `@Sendable` cancellation handler. The service name "must exist in the Mach bootstrap accessible to the process and advertised in a `launchd.plist`". — [Apple: XPCSession init(machService:…)](https://developer.apple.com/documentation/xpc/xpcsession/init(machservice:targetqueue:options:cancellationhandler:).md)
- `XPCListener.init(service:targetQueue:options:requirement:incomingSessionHandler:)` is available on **macOS 26.0+**. It takes an `XPCPeerRequirement`, and "For a listener, requests that do not satisfy the requirement are dropped." The handler is `@Sendable`. — [Apple: XPCListener init(service:…requirement:…)](https://developer.apple.com/documentation/xpc/xpclistener/init(service:targetqueue:options:requirement:incomingsessionhandler:).md)
- `XPCSession.setPeerRequirement(_:)` is listed as macOS 26.0+. — [Apple docs via search: setPeerRequirement](https://developer.apple.com/documentation/xpc/xpcsession/setpeerrequirement(_:).md)
- Apple's "Creating XPC services" article shows the Codable pattern. The listener uses `request.accept { message in … }`, decodes with `message.decode(as: CalculationRequest.self)`, and returns an `Encodable?` reply. The client calls `session.sendSync(request)` and then `reply.decode(as:)`. The listener rejects with `request.reject(reason:)`. — [Apple: Creating XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services.md)
- On the forums, a developer moving from NSXPCConnection to XPCSession (Feb 2026, macOS 26) found that `XPCPeerRequirement.isFromSameTeam()` worked. Passing a classic SecRequirement string to `hasEntitlement(_:)` failed with "Peer forbidden". Quinn's accepted answer: entitlements and code requirements are different things. Use `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)` for one identifier. For several, build a Lightweight Code Requirement: `ProcessCodeRequirement.allOf { TeamIdentifier("…"); SigningIdentifier.in("a","b") }` wrapped with `XPCPeerRequirement.codeRequirement(lwcr)`. — [Apple Forums thread 815147](https://developer.apple.com/forums/thread/815147)
- Codable `send()` fails when the payload contains an `XPCEndpoint`. The accepted workaround is to wrap message types in one Codable enum. — [Apple Forums thread 798938 (via search snippet)](https://developer.apple.com/forums/thread/798938)
- Quinn's known-good SMAppService project still uses `NSXPCConnection(machServiceName:options: [.privileged])` on the client, with the plist `MachServices` key matching `NSXPCListener(machServiceName:)`. — [Apple Forums thread 799910](https://developer.apple.com/forums/thread/799910)
- batt, an open-source root battery daemon with a CLI and menu bar GUI, is structured like docker: "It has a daemon that runs in the background, and a client (CLI or GUI) that communicates with the daemon… through unix domain socket as a way of IPC." — [GitHub: charlie0129/batt](https://github.com/charlie0129/batt)

### Inferences
- **Recommendation: Swift XPC API on macOS 27.** On the daemon, use `XPCListener(service: "dev.kanishk.talon.daemon", requirement: …)`. On the app, CLI and widget side, use `XPCSession(machService:options:)`. Define one `Codable` enum `TalonRequest` and one `TalonReply`, following the "single Codable enum" advice from thread 798938. Put them in a shared `TalonIPC` module so all four targets compile against the same schema. This removes the `@objc` protocol / NSSecureCoding layer that NSXPCConnection needs. It also fits Swift 6 strict concurrency better, since the handlers are `@Sendable` and the types are value types.
- **Bring-up order.** `.privileged` is how the phase-0 spike reached a daemon from a user process. The phase-0 NSXPCConnection path works today, so the migration can go one step at a time: port the message schema first, then swap the transport.
- **Streaming 1–4 Hz metrics.** XPC is message-oriented and has no built-in stream type. There are two workable options.
  - (a) **Client polls** with an async `send` every 250–1000 ms. This is trivial, and at this rate it is cheap for local XPC.
  - (b) **Daemon pushes** messages back on the accepted server-side session. The client registers an incoming-message handler and receives them.
  I could not confirm the exact Swift API signature for server-to-client push on `XPCSession` (an `incomingMessageHandler` parameter on the client initializer). Verify it in the macOS 27 SDK. With NSXPCConnection, push works through `exportedObject` on the client connection, the classic bidirectional pattern. Either way, wrap it in an `AsyncStream<Metrics>` on the client.
- **Why not gRPC or HTTP on localhost.** Any local process can reach TCP localhost, so you would need your own auth tokens. gRPC adds a large dependency and code generation. Neither offers on-demand launch through launchd. A Unix domain socket at a root-owned path with group permissions is the most signing-independent option, and batt proves the model. Its cost is that you write your own framing and peer checks. Keep it as plan B in case code-signing requirements prove unworkable with ad-hoc signing.
- **Widget caveat.** The widget extension is sandboxed. A sandboxed process generally cannot look up an arbitrary global Mach service without a `mach-lookup` temporary-exception entitlement. So the widget should probably not talk XPC to talond directly (see the WidgetKit section).

### Gaps
- Exact availability on macOS 26/27 of `XPCPeerRequirement` factory methods (`isFromSameTeam`, `codeRequirement`, `hasEntitlement`, `isPlatformCode`). The doc page returned no body when fetched.
- Whether `XPCSession(machService:)` with `.privileged` behaves identically to NSXPCConnection `.privileged` for a root daemon. Not documented in what I found.
- No macOS 27 / WWDC 2026 XPC changes were found.

## Peer code-signing requirements with ad-hoc or Personal Team signing

### Takeaway
Ad-hoc signatures have no Team ID and no Apple anchor. `isFromSameTeam`, `TeamIdentifier(...)` and `anchor apple generic` requirements therefore cannot match an ad-hoc client. A free Personal Team "Apple Development" certificate does carry a Team ID, so team-based requirements should work with it. That is an inference I did not test. For a pure ad-hoc setup, the only strong binding is a cdhash requirement, which changes on every build. Otherwise fall back to uid/audit-token checks.

### Cited Findings
- Quinn recommends signing "both your embedded helper and your app with the same Apple-issued code-signing identity. If, for example, you are using ad hoc signing (Sign to Run Locally in Xcode parlance) then you will see problems like this." (Sep 2025, about SMAppService failures.) — [Apple Forums thread 799910](https://developer.apple.com/forums/thread/799910)
- In that thread, the user on a free developer profile had an Apple Development certificate with a `TeamIdentifier` present in `codesign` output. — [Apple Forums thread 799910](https://developer.apple.com/forums/thread/799910)
- A developer using Developer ID for both sides still could not connect after adding `anchor apple generic and certificate leaf[subject.OU] = <TeamID>`. Quinn pointed to TN3127 and to testing with `codesign -R`. — [Apple Forums (search snippet), thread 742305](https://developer.apple.com/forums/thread/742305)
- Quinn shows that code requirements can be checked with `codesign --verify -R '<requirement>' -v <path>`. — [Apple Forums thread 815147](https://developer.apple.com/forums/thread/815147)
- A Havus project issue says an ad-hoc-signed helper is unsuitable for production because its code-signing requirement cannot be tied to a Developer ID. — [GitHub XNyetok/Havus #19](https://github.com/XNyetok/Havus/issues/19)

### Inferences
- **Recommended tiered requirement for Talon.**
  - **Personal Team signing works in Xcode 27 (preferred).** Sign app, CLI and daemon with the same Apple Development identity. Use `ProcessCodeRequirement.allOf { TeamIdentifier("<personal team id>"); SigningIdentifier.in("dev.kanishk.talon", "dev.kanishk.talon.cli", "dev.kanishk.talon.widget") }` on the listener.
    - Personal Team certificates expire. Free provisioning has historically been short-lived, around 7 days for iOS profiles. Mac development certificates last longer, but expect re-signing churn.
  - **Pure ad-hoc.** Do not rely on a signing-identifier-only requirement. Anyone can ad-hoc sign a binary with any identifier, so that requirement is spoofable. Rely on the runtime checks in the security section. Optionally pin the cdhash, regenerated at `make install` time and written into the daemon's config.
- Verify every requirement string with `codesign -R` against the real built binaries before wiring it into the listener.

### Gaps
- No source directly confirmed whether `XPCPeerRequirement` / LWCR matching works against a free Personal Team Team ID. It is very likely, since the Team ID is in the leaf cert, but it was not tested.
- No source on how an ad-hoc client behaves against `isFromSameTeam` on a listener that is itself ad-hoc. Presumably both have an empty Team ID and it fails closed. Unverified.

## Helper install and lifecycle: SMAppService.daemon vs manual launchd plist vs SMJobBless

### Takeaway
SMAppService.daemon (macOS 13+) is Apple's supported path. It embeds the plist in `Contents/Library/LaunchDaemons` with `BundleProgram`, and the user approves through a "Background Items Added" notification and authenticates. It needs correct, consistent Apple-issued signing, and reports with ad-hoc signing are unreliable or failing. For a personal, no-paid-account project, keep the phase-0 approach: a `sudo make install` that copies the binary and plist into `/Library/PrivilegedHelperTools` and `/Library/LaunchDaemons` and runs `launchctl bootstrap system`. Optionally try SMAppService later if Personal Team signing works. SMJobBless is deprecated and needs Developer-ID-style SMAuthorizedClients/SMPrivilegedExecutables requirements.

### Cited Findings
- SMAppService is macOS 13.0+. For LaunchDaemons, `register()`/`unregister()` "provide a replacement for installing property lists in `/Library/LaunchDaemons`". Its API also includes `status`, a `Status` enum, `openSystemSettingsLoginItems()` and `statusForLegacyPlist(at:)`. — [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice.md)
- Quinn's "Getting Started with SMAppService" (Sep 2025, Xcode 26 / macOS 15.6.1) covers the layout and approval flow.
  - **Layout.** The daemon executable goes in `Contents/MacOS/` through a Copy Files phase with Code Sign on Copy. The plist goes in `Contents/Library/LaunchDaemons/`, with `Label` and `BundleProgram` (`Contents/MacOS/<daemon>`, relative to the bundle). The plist name must match `SMAppService.daemon(plistName:)`.
  - **Approval.** The first `register()` fails with `SMAppServiceErrorDomain / 1` until the user approves the "Background Items Added… Do you want to allow this?" notification and authenticates.
  - **Unregister.** `unregister()` removes the job, but approval is remembered. Reset it with `sfltool resetbtm`.
  - **Debugging.** Use `sudo launchctl list <label>`; without sudo "you won't find any launchd daemons there". Use `sudo launchctl start <label>`, and filter Console by subsystem.
  - **Sandbox.** A non-sandboxed daemon cannot be installed from a sandboxed app on macOS 14.2+.
  - **Restricted entitlements.** If the job uses restricted entitlements, it needs an app-like wrapper to hold a provisioning profile.
  - **Upgrades.** The guide does not cover upgrades.
  — [Apple Forums thread 802443](https://developer.apple.com/forums/thread/802443)
- In "SMAppService Sample Code seems broken" (Sep 2025), a user on a free developer profile got `SMAppServiceErrorDomain Code=1 "Operation not permitted"`. The item appeared in System Settings and vanished when enabled, and `status` = `notFound`. Later register "eventually" succeeded "after changing literally nothing".
  - The agent variant worked, but the daemon variant caused "all the trouble".
  - launchd status 78 = `EX_CONFIG`, "usually… the path to the executable is incorrect" (Quinn).
  - `sfltool dumpbtm` showed the daemon `(pending authorization)`.
  - Quinn: Apple's own daemons don't use SMAppService. "I don't know of one that uses `SMAppService`." The OP said he would stay on SMJobBless.
  — [Apple Forums thread 799910](https://developer.apple.com/forums/thread/799910)
- A DTS answer (search snippet) says Developer ID is required for direct distribution and that SMAppService adds no further constraints, unlike SMJobBless's code-signing-requirements process. SMAuthorizedClients is relevant only to SMJobBless. — [Apple Forums search results incl. thread 751439](https://developer.apple.com/forums/thread/751439)
- Ad-hoc evidence on GitHub is mostly unverified planning notes. neuraOS notes that with ad-hoc signing "an update may require renewed OS approval". — [GitHub oaktics/neuraOS PR #66](https://github.com/oaktics/neuraOS/pull/66); [GitHub llimllib/spireweb #74](https://github.com/llimllib/spireweb/issues/74); [GitHub AshuLab/carrier #117](https://github.com/AshuLab/carrier/issues/117)

### Inferences
- **Recommended dev and install flow (manual launchd, proven in phase 0).**
  - Build, sign ad-hoc or with Personal Team, then `sudo make install`. The install target:
    - `launchctl bootout system/dev.kanishk.talond` (ignore errors);
    - `install -o root -g wheel -m 755 talond /Library/PrivilegedHelperTools/`;
    - `install -o root -g wheel -m 644 dev.kanishk.talond.plist /Library/LaunchDaemons/`;
    - `launchctl bootstrap system /Library/LaunchDaemons/dev.kanishk.talond.plist`;
    - `launchctl kickstart -k system/dev.kanishk.talond`.
  - `make uninstall` reverses these steps.
  - The binary must be root-owned and not user-writable. If the user can write the helper binary, any user-level malware can replace it and get root.
  - The CLI can be symlinked into `/usr/local/bin`.
  - macOS 13+ still shows a Background Items notification for plists dropped into `/Library/LaunchDaemons`, and lists them in Login Items & Extensions. That is expected and harmless.
  - Upgrades are just re-running `make install`. The bootout/bootstrap pair ensures the new binary is loaded.
- **SMAppService is optional polish for later.** It is worth it only if the Personal Team-signed app plus daemon registers reliably. Its benefits are a one-click Login Items toggle and the binary living inside the app bundle. Its drawbacks for a dev loop:
  - every rebuild changes the bundle;
  - BTM state is sticky and needs `sfltool resetbtm`;
  - ad-hoc reports are flaky.
- **Never use SMJobBless.** It is deprecated and its requirement checks are built around Developer ID.

### Gaps
- No primary source definitively states whether SMAppService.daemon works with (a) pure ad-hoc or (b) free Personal Team signing on macOS 26/27. Evidence is mixed and anecdotal. This should be a 10-minute spike on the actual machine.
- No source on SMAppService upgrade semantics (replacing the app bundle while the daemon is registered) for 2025–2026.
- No macOS 27-specific BTM / Login Items changes were found.

## Security for a root helper on a single-user Mac

### Takeaway
The realistic threat is any local process, including malware running as the user or a compromised npm/pip package, connecting to talond and asking it to kill, freeze or cap arbitrary processes, or abusing a generic "run command" method. Real 2025–2026 CVEs in popular open-source Mac helpers came from exactly this: Stats and Pearcleaner both accepted any XPC client. Mitigations:
- Accept only clients that pass a code requirement (where signing allows it).
- Identify peers by **audit token, never PID**.
- Check the peer's euid against the console user.
- Restrict targets to PIDs owned by that uid, re-validated at action time.
- Expose only narrow typed verbs, never "exec this string".
- Keep the daemon binary and plist root-owned.

### Cited Findings
- **Stats CVE-2025-21606.** The privileged helper `eu.exelban.Stats.SMC.Helper` (fan control, `powermetrics`) had `shouldAcceptNewConnection` that "unconditionally returns YES… allowing any XPC client to connect… without any form of verification". Fixed in Stats 2.11.21 (published Jan 17 2025). — [cvefeed CVE-2025-21606](https://cvefeed.io/vuln/detail/CVE-2025-21606); [secalerts](https://secalerts.co/vulnerability/CVE-2025-21606)
- **Pearcleaner CVE-2025-54595.** In versions 4.4.0 to before 4.5.2, PearcleanerHelper "accepts unauthenticated connections from any local process" and exposes a method that runs caller-supplied shell commands, giving local privilege escalation to root. CVSS 7.3, CWE-78/CWE-269, published Aug 1 2025, fixed in 4.5.2. — [CIRCL CVE-2025-54595](https://cve.circl.lu/vuln/cve-2025-54595)
- **2026 helper CVEs from PID reuse.** CVE-2026-24071 (Native Access, CVSS 7.8), CVE-2026-24067 (Slate Digital Connect) and Waves Central were all affected. Their helpers validated the code signature of a PID, and PIDs can be recycled. The recommended fix is audit-token validation with `xpc_connection_get_audit_token` plus `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`. Apple's fbahelperd CVE-2019-8565 was the same bug class (older). — [NVD CVE-2026-24071](https://nvd.nist.gov/vuln/detail/CVE-2026-24071); [SentinelOne CVE-2026-24067 (search snippet)](https://www.sentinelone.com/vulnerability-database/cve-2026-24067/)
- **Audit tokens alone are not airtight.** Computest's Objective by the Sea talk, "Don't Talk All at Once! Elevating Privileges on macOS by Audit Token Spoofing" (CVE-2023-32405, older), showed checks using the audit token of the wrong process when multiple senders share one connection. — [infocondb: OBTS v6 talk](https://infocondb.org/con/objective-by-the-sea/objective-by-the-sea-version-60/dont-talk-all-at-once-elevating-privileges-on-macos-by-audit-token-spoofing)
- `XPCListener(…requirement:)` drops non-matching peers before the handler (macOS 26+). — [Apple: XPCListener init](https://developer.apple.com/documentation/xpc/xpclistener/init(service:targetqueue:options:requirement:incomingsessionhandler:).md)

### Inferences
- **Concrete Talon hardening checklist.**
  1. Put the code requirement on the listener when signing permits (see the code-signing section).
  2. In the accept handler, read the peer audit token and get euid/pid from it. NSXPCConnection exposes `auditToken` only through SPI or KVC; the Swift API may expose it differently. Verify. Reject unless euid equals the console user's uid (from `SCDynamicStoreCopyConsoleUser`) or 0.
  3. For every kill, cap or freeze request, resolve the target with `proc_pidinfo` and require the target's uid to equal the caller's uid. Refuse PID ≤ 1, launchd, WindowServer, any root-owned process, and talond itself. Re-check right before acting, to narrow the PID-reuse TOCTOU window. Prefer acting on process groups or jobs that talond launched itself (`talon run`), where it holds the child handle.
  4. The protocol exposes typed verbs only (`setMemoryCap(pid:bytes:)`, `status()`). No shell or exec passthrough. Pearcleaner shows what happens otherwise.
  5. Keep the binary and plist `root:wheel 755/644` in `/Library/PrivilegedHelperTools`. Never load the daemon from a user-writable path such as DerivedData.
  6. Log every privileged action with `os.Logger`, subsystem `dev.kanishk.talon`, including caller pid/uid.
  7. On a single-user personal Mac, the residual risk after steps 2–5 is a same-uid attacker capping or killing that user's own processes. They could do that anyway with `kill`, so the helper adds no privilege escalation. That is the right bar.
- **`talon run` is special.** If talond itself spawns the child (`talon run -- python train.py`), it must spawn as the caller's uid/gid, never as root. Use `posix_spawn` after `setuid`, or have the CLI spawn the child and only register the PID with talond. The latter is simpler and safer.

### Gaps
- No specific Objective-See (Patrick Wardle) 2024–2026 blog post on XPC helper vulnerabilities was retrieved.
- Apple's own guidance doc on validating XPC peers (e.g. "Validating the identity of XPC peers") was not fetched.
- I did not confirm whether the Swift `XPCSession`/`IncomingSessionRequest` exposes the audit token publicly.

## WidgetKit + App Groups with free/ad-hoc signing

### Takeaway
With ad-hoc signing, a macOS widget extension does not register reliably, and its App Group container reads are denied on macOS 15+. App Group membership must be authorized by a provisioning profile with a Team ID. Personal Team signing may work, but that is unconfirmed. Treat the widget as the last and least reliable component. WidgetKit cannot show 1–4 Hz live data anyway; its timeline reloads are budgeted.

### Cited Findings
- From the CodexSatellites v0.3.0 release notes (date shown only as "09 Sep"; year likely 2025):
  - "The widget extension needs a code-signed build to be registered by macOS."
  - "On macOS 15+, App Group containers are protected and membership must be authorized by the code-signing/provisioning model."
  - An ad-hoc build lacks a provisioning profile and Team ID for the group, so TCC denies the widget's group-container read.
  - Their workaround: the app writes the snapshot into the widget extension's own sandbox container, described as a development workaround.
  — [GitHub NTLx/CodexSatellites v0.3.0](https://github.com/NTLx/CodexSatellites/releases/tag/v0.3.0)
- Apple DevRel (forum, via search snippet): App Group IDs on macOS can use the `<TeamID>.` prefix instead of `group.`. "This is a system feature that you need to change your configuration to adapt." A macOS-style container can be used during development. — [Apple Forums thread 767581 (via search)](https://developer.apple.com/forums/thread/767581)
- A Tauri widget plugin guide lists "Apple Development" signing as working with `appGroup` for local use. It does not say whether a free Personal Team suffices. — [docs.rs tauri-plugin-widgets macOS guide](https://docs.rs/crate/tauri-plugin-widgets/0.4.1/source/docs/guide/setup/macos.md)

### Inferences
- **Recommended order.**
  1. Ship the menu bar extra first. It updates at 1–4 Hz via XPC and has no signing gymnastics.
  2. Build the widget only after confirming Personal Team signing produces a registered widget. Use a `<TeamID>.dev.kanishk.talon` macOS-style App Group, where the app writes a small JSON or plist snapshot and calls `WidgetCenter.shared.reloadAllTimelines()` sparingly.
  3. If Personal Team fails, fall back to the CodexSatellites trick: the app writes into `~/Library/Containers/<widget-bundle-id>/Data/…`.
  4. Or drop the widget. The menu bar extra covers the same need better for live metrics.
- The widget should not hold an XPC connection to talond. It is sandboxed, short-lived and budgeted, so it should read a snapshot.

### Gaps
- No definitive 2025–2026 source on whether a free Personal Team can provision App Groups or register macOS widget extensions on macOS 26/27. Needs a hands-on spike.
- WidgetKit refresh budget numbers for macOS were not retrieved.

## Project structure and build tooling

### Takeaway
SwiftPM alone can build the daemon, the CLI and even a script-assembled menu bar `.app`. It cannot produce app extensions, so it cannot build a WidgetKit extension. Recommended layout:
- One local Swift package (`TalonKit`) holding the shared modules: `TalonIPC` (Codable message enums plus the Mach service name), `TalonCore` (sampling and policy logic), and `TalonLogging`.
- Thin executable targets for `talond` and `talon` (swift-argument-parser) in that package.
- An Xcode project for the app and widget only, generated by XcodeGen (simple YAML, fast) or Tuist (Swift manifests, heavier). Or just a hand-maintained `.xcodeproj` for a one-person project.
- A Makefile drives everything: `make build`, `make test` (`swift test` with Swift Testing), `sudo make install`.

### Cited Findings
- Community "macos-spm-app-packaging" workflows build a macOS app from a plain SwiftPM package. A script builds binaries, creates the `.app` bundle, copies resources and signs. A menu bar app needs `LSUIElement`. Icon generation still needs Xcode. These pages do not cover app extensions. — [Smithery: macos-spm-app-packaging](https://smithery.ai/skills/dimillian/macos-spm-app-packaging)
- XcodeGen generates the Xcode project from folder structure plus a YAML/JSON spec. Tuist uses Swift manifests and adds caching. A third-party comparison says Tuist generation is much slower than XcodeGen and its conventions can get in the way. — [Medium: Tuist and XcodeGen](https://medium.com/@mobile_44538/tuist-and-xcodegen-7a35e02c278a) (2023, older)
- Tuist's 2024 retrospective describes moving toward being "an integrated extension of Apple's toolchain" (caching, previews, and so on), beyond a project generator. — [Tuist: 2024 Wrapped](https://tuist.dev/blog/2024/12/21/2024-wrapped)
- For SMAppService, Quinn sets the daemon target's Enable Debug Dylib Support to No (set Yes, then No) and recommends logging through a subsystem for Console filtering. — [Apple Forums thread 802443](https://developer.apple.com/forums/thread/802443)

### Inferences
- **Suggested repo layout.**
  ```
  talon/
    Package.swift            # TalonKit: libs + talond + talon executables
    Sources/TalonIPC/        # Codable TalonRequest/TalonReply, service name, protocol version
    Sources/TalonCore/       # sampling, policy, process filtering (pure, unit-testable)
    Sources/TalonDaemon/     # talond main: XPCListener, launchd lifecycle
    Sources/TalonCLI/        # talon: swift-argument-parser (run/status/…)
    Tests/TalonCoreTests/    # Swift Testing (@Test, #expect)
    App/project.yml          # XcodeGen: TalonApp (SwiftUI MenuBarExtra+Window) + TalonWidget, depends on local package
    launchd/dev.kanishk.talond.plist
    Makefile                 # build, test, sign, install, uninstall, logs
  ```
- **Keep the daemon and CLI out of Xcode** and build them with `swift build -c release`. This sidesteps Xcode's debug-dylib stub issue for command-line tools. Each binary carries an embedded Info.plist through the `-sectcreate __TEXT __info_plist` linker flag if a bundle ID is needed for signing identifiers.
- **Pick XcodeGen over Tuist** for a two-target app plus extension with a local package. It needs no extra runtime, regenerates in under a second, and can be dropped at any time by committing the generated project.
- **Logging.** `os.Logger(subsystem: "dev.kanishk.talon", category: "daemon"|"xpc"|"policy")`. Add `make logs` = `log stream --predicate 'subsystem == "dev.kanishk.talon"' --level debug`.
- **Testing.** Swift Testing for TalonCore and IPC Codable round-trips. Test the policy layer, especially "is this PID allowed?", as pure functions over injected process tables, so no root is needed in tests.
- **Signing in the Makefile.** Use `codesign -s - --force --options runtime -i dev.kanishk.talond talond` for ad-hoc, or `-s "Apple Development: …"` when a Personal Team identity exists. Then run a `codesign -R` check target that validates the XPC requirement string against the built binaries.

### Gaps
- No 2025–2026 primary source on whether SwiftPM in Swift 6.x / Xcode 27 gained app-bundle or extension products. I found no evidence it did.
- No current (2025–2026) XcodeGen release notes or a Tuist widget-extension example were retrieved.
- The swift-argument-parser and Swift Testing docs were not fetched in this pass. Both are standard and well established, but there are no citations here.

## Reference implementations and lessons

### Takeaway
The most instructive open-source references are cautionary. Stats (2025) and Pearcleaner (2025) shipped root XPC helpers that accepted any client and were assigned CVEs. batt shows a clean root-daemon plus CLI plus menu bar GUI split over a Unix socket. Quinn's SMAppService guide (Sep 2025) is the canonical bring-up reference.

### Cited Findings
- **Stats.** Root SMC helper `eu.exelban.Stats.SMC.Helper`, with unconditional `shouldAcceptNewConnection`. CVE-2025-21606, fixed in 2.11.21. — [cvefeed](https://cvefeed.io/vuln/detail/CVE-2025-21606)
- **Pearcleaner.** XPC helper (`com.alienator88.Pearcleaner.PearcleanerHelper`) installed as a LaunchDaemon after user approval. It exposed shell execution to any local client: CVE-2025-54595, fixed in 4.5.2 (fix commit 69afadfa, advisory GHSA-gr2j-65fh-8pvc). The original repo reportedly paused development at the end of 2025. — [CIRCL](https://cve.circl.lu/vuln/cve-2025-54595); [GitHub alienator88/Pearcleaner (via search)](https://github.com/alienator88/Pearcleaner)
- **batt.** A root daemon controls charging through SMC/firmware/native backends. The CLI and GUI talk to it over a Unix domain socket. It installs via Homebrew services, an install script, or the GUI. Users are told to `xattr -r -d com.apple.quarantine` the app, which implies it is not notarized. — [GitHub charlie0129/batt](https://github.com/charlie0129/batt)
- **Quinn's SMAppService guide and working project config.** `BundleProgram`, `MachServices`, `.privileged`. — [thread 802443](https://developer.apple.com/forums/thread/802443); [thread 799910](https://developer.apple.com/forums/thread/799910)
- **2026 audio-vendor helpers.** Native Access, Slate, Waves: PID-based validation leading to LPE; fix with audit tokens. — [NVD CVE-2026-24071](https://nvd.nist.gov/vuln/detail/CVE-2026-24071)

### Inferences
- Lessons for Talon:
  1. The single most common real-world bug is "accept every connection". Make peer validation the first thing written in talond, not a TODO.
  2. Never expose generic exec.
  3. Use audit tokens, not PIDs.
  4. A socket-based design (batt) is a credible plan B if XPC signing requirements fight ad-hoc signing.
  5. The menu bar extra gets data far more reliably than a widget.

### Gaps
- Not examined, because of the tool-call budget: AlDente, Ice, Mos, the current Stats source (whether it moved to SMAppService and what peer check it added), and the actual fix diffs for Stats and Pearcleaner.
