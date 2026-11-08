# UI Framework and Charting Approach for Talon (Apple-premium macOS app, macOS 27 / Xcode 27 / Swift 6.4)

Research date: 2026-11-08. Sources are dated where known. Items marked "(from prior knowledge, unverified)" weren't confirmed by a fetched source this session. The report writer should treat them as leads, not facts.

## Q1. How well does each UI option deliver Liquid Glass, MenuBarExtra, WidgetKit, haptics, notifications, and system-consistent behaviour? Which are impossible or hacky from web, Flutter, or Compose shells?

### Takeaway
Only a Swift stack (SwiftUI plus AppKit) gets every required capability first-class. Each web, Flutter, or Compose shell needs third-party bridges to native APIs: a separate Xcode-built widget extension, and private-API or platform-view hacks for glass. Desktop widgets must be SwiftUI in any case, because WidgetKit extensions are SwiftUI-only. A non-Swift UI therefore means maintaining two UI stacks.

### Cited Findings
**Tauri**
- Liquid Glass comes from the `window-vibrancy` crate. Its `apply_liquid_glass` works only on macOS 26+ (`apply_vibrancy` covers 10.10+) — [window-vibrancy docs.rs](https://docs.rs/crate/window-vibrancy/latest/source/src/macos/mod.rs)
- The community `tauri-plugin-liquid-glass` falls back to plain vibrancy on older macOS — [docs.rs tauri-plugin-liquid-glass](https://docs.rs/crate/tauri-plugin-liquid-glass/latest)
- Vibrancy on macOS needs `"macOSPrivateApi": true`, a transparent window, and the `macos-private-api` feature. That makes it a private-API dependency — [window-vibrancy README](https://docs.rs/crate/window-vibrancy/0.5.1/source/README.md); [DEV: Tauri v2 menu bar guide](https://dev.to/hiyoyok/complete-guide-to-building-a-macos-menu-bar-app-with-tauri-v2-aji)
- Tauri doesn't generate an `.xcodeproj` for macOS. A widget extension has to be built as a separate Xcode project, then its `.appex` copied into `Contents/PlugIns/` and re-signed. The plugin docs also say local ad-hoc signing has no shared App Group container, so a different transport is needed — [tauri-plugin-widgets macOS setup](https://docs.rs/crate/tauri-plugin-widgets/0.4.3/source/docs/guide/setup/macos.md)
- One Tauri widget project uses a LaunchAgent as its main refresh path, because "macOS may delay or throttle widget updates" — [tauri-plugin-widgets transport.rs](https://docs.rs/crate/tauri-plugin-widgets/latest/source/src/transport.rs)
- Haptics need a third-party crate, `tauri-plugin-macos-haptics`, which wraps NSHapticFeedbackManager patterns — [lib.rs](https://lib.rs/crates/tauri-plugin-macos-haptics)

**Electron**
- Liquid Glass needs the third-party `electron-liquid-glass` package, which uses NSGlassEffectView and requires macOS 26+. It needs `transparent: true`, and its README warns against also setting `vibrancy`, which would "override and look blurry" — [electron-liquid-glass GitHub](https://github.com/Meridius-Labs/electron-liquid-glass)
- Electron had to ship a fix for a macOS 26 Tahoe WindowServer GPU-load spike caused by overriding the private `cornerMask` API (PR #48399/#48400). This is the kind of OS-update fragility that web shells carry — [Electron commit mirror](https://ayakael.net/mirrors/electron/commit/c15d8a4a37310636dfbbbeb83118bc6e00b81e7a)
- An older issue reports BrowserView content wiped when vibrancy is set on Electron 30+ (April 2024, flagged as older) — [electron/electron#24471 area](https://github.com/electron/electron/issues/24471)

**Flutter macOS**
- Glass is available only through community packages. `real_liquid_glass` hosts NSGlassEffectView in a *platform view* (macOS 26+, Xcode 26+), and `macos_glass` uses NSVisualEffectView vibrancy behind a tint — [pub.dev real_liquid_glass](https://pub.dev/documentation/real_liquid_glass/0.3.0/); [pub.dev macos_glass](https://pub.dev/documentation/macos_glass/latest/)
- An older `flutter_acrylic` issue reports that making the window transparent made "everything" transparent (older, flagged) — [flutter_acrylic #22](https://github.com/alexmercerind/flutter_acrylic/issues/22)
- The Flutter widget plugin `flow_widget_macos` needs macOS 11+, has no Live Activities, and can't list installed widgets. The widget UI itself is native — [pub.dev flow_widget_macos](https://pub.dev/documentation/flow_widget_macos/latest/)

**Raycast 2 (2026), a real-world data point on web UI inside a native shell**
- Raycast 2 renders its macOS UI in WKWebView (React/TypeScript) inside a Swift/AppKit host that handles windows, hotkeys, and the menu bar: "We're a native app that uses web for its UI." Memory rose from about 200–300 MB (v1, AppKit) to about 350–450 MB (v2). WebKit needed native-side workarounds for throttling and flicker on frequently shown and hidden windows. The reasons for the rewrite were cross-platform reach (Windows) and hiring — [Raycast blog, May 14 2026](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)
- MacGeneration (Aug 2026) reports that the hybrid web architecture drew criticism from native purists — [MacG](https://www.macg.co/logiciels/2026/08/raycast-2-une-mise-jour-majeure-qui-fait-le-plein-dia-et-fache-les-puristes-310469)
- Conflicting source: an aggregator summary claims Raycast's React tree is rendered by native AppKit views. That describes the v1 *extension* API, not the v2 app UI — [Raycast API blog (v1)](https://raycast.com/blog/how-raycast-api-extensions-work)

**Native haptics**
- NSHapticFeedbackManager (AppKit, macOS 10.11+) exposes `defaultPerformer` and `perform(_:performanceTime:)`. The system may suppress feedback, for example when the user isn't touching the Force Touch trackpad. Apple says to use it only for user-initiated actions and to pair it with a visual cue such as an alignment guide — [Apple docs: NSHapticFeedbackManager](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager); [perform(_:performanceTime:)](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer/perform(_:performancetime:))
- Apple's ForceTouchCatalog sample fires `.alignment` when a slider crosses a snap value. It advises using haptics sparingly and filtering by drag velocity. The sample dates from 2016 (flagged older), but the API is unchanged — [ForceTouchCatalog](https://developer.apple.com/library/archive/samplecode/ForceTouchCatalog/Listings/ForceTouchCatalog_MasterViewController_swift.html)

### Inferences
- Capability matrix for Talon:

| Capability | SwiftUI + AppKit | AppKit-first | Tauri / Electron | Flutter | Compose MP |
|---|---|---|---|---|---|
| Liquid Glass | first-class (`glassEffect`, system controls adopt automatically) | NSGlassEffectView, first-class | 3rd-party plugin, private API, transparent window | platform-view plugin | no source found, likely JNI/hack |
| Menu bar extra + glass panel | MenuBarExtra or NSStatusItem+NSPanel | NSStatusItem+NSPanel | tray API plus vibrancy hack | plugin | tray only |
| WidgetKit | same project, shared Swift models | needs a SwiftUI target anyway | separate Xcode project, re-sign, data bridge | separate native target | separate native target |
| Trackpad haptics | direct | direct | plugin | plugin/channel | JNI |
| Native notifications (UNUserNotificationCenter) | direct | direct | plugin | plugin | plugin |
| SF Symbols, `.monospacedDigit()`, springs, system typography | native | native (springs via CA) | approximations | approximations | approximations |

- Every non-Swift option still needs Swift for widgets (WidgetKit is SwiftUI-only), so it never removes Swift from the project. It only adds a second UI stack. That is a poor fit for a single-developer, Mac-only personal project.
- Raycast's move shows that web UI is chosen for cross-platform and hiring reasons, not for native polish, and it cost about 150 MB of RAM. Talon has neither motivation, and a memory-monitor app using 400 MB would undercut its own purpose.

### Gaps
- No source was found for Compose Multiplatform on macOS (Liquid Glass, menu bar, widgets). The matrix entries for it are inference.
- Not verified whether Tauri or Electron tray windows render Liquid Glass correctly when anchored to the transparent macOS 26/27 menu bar.

## Q2. SwiftUI-on-macOS pain points in 2025–2026, and where AppKit should be used instead

### Takeaway
SwiftUI is good enough for the shell, sidebar, settings, detail panes, and widget views, and the community consensus is still to drop to AppKit for big live tables and advanced menu-bar panels. For Talon, that means an NSTableView or NSOutlineView (wrapped in NSViewRepresentable) for the ~700-row Processes list at 1 Hz, and NSStatusItem plus a non-activating NSPanel (with SwiftUI content) if MenuBarExtra's behaviour falls short. macOS 27 brought layout and container improvements but no architectural fix.

### Cited Findings
**List/Table performance**
- WWDC25 (session 256) claimed about 6x faster loading and 16x faster updating for List/Table on macOS 26. Michael Tsai doubts this reaches NSTableView parity, because the gains came from "improved scheduling and lazy loading" rather than architecture — [mjtsai, June 18 2025](https://mjtsai.com/blog/2025/06/18/swiftui-at-wwdc-2025/); [WWDC25 #256](https://developer.apple.com/videos/play/wwdc2025/256/)
- Sarah Reichelt (2025): "SwiftUI lists have improved a lot in macOS this year," but she still hesitates to recommend them over AppKit for thousands of entries — [troz.net 2025](https://troz.net/post/2025/swiftui-mac-2025/)
- Earlier, Reichelt found SwiftUI lists unusable at 10k rows and moved to NSTableView (2024, flagged older) — [troz.net 2024](https://troz.net/post/2024/swiftui_lists/)
- Gwendal Roué (Aug 2025) replaced SwiftUI Table with a UIKit collection layout for 20k+ items: "Bye-bye, SwiftUI Table, you're unfinished." He also says fixed-height rows need an API change — [via mjtsai](https://mjtsai.com/blog/2025/06/18/)
- An Apple forum thread reports a 13-second hang selecting a row in a roughly 1,200-row SwiftUI Table. The cause was an `if` inside `ForEach`, and the fix was pre-filtering — [Apple Dev Forums 739849](https://developer.apple.com/forums/thread/739849)
- A tuning blog (Feb 2026, single unverified source) recommends fixed or bounded column widths, precomputed display strings, and reference-type row models — [coldfusion-example blog](https://coldfusion-example.blogspot.com/2026/02/optimizing-swiftui-table-performance.html)
- macOS 27 / WWDC26: session 321 covers lazy-stack size estimation and prefetching. Fatbobman sees "noticeable performance improvements in some scenarios" but notes there are still no custom lazy containers. Harshil Shah (Sep 2026) says UIKit "still remains streets ahead" for large collections. Isaiah Carew (Oct 2026) found a SwiftUI rebuild "unusably slow and clunky" — [mjtsai, SwiftUI in appleOS 27 (June 19 2026, updated)](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/)
- Tony Arnold (Jul 2026) reports Instruments showing "Trace file had no SwiftUI data" in Xcode 26 and 27. Profiling SwiftUI may itself be unreliable — [mjtsai appleOS 27](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/)

**MenuBarExtra**
- Peter Steinberger (2025): `SettingsLink` "doesn't work reliably in MenuBarExtra." The `openSettings` action works on macOS 15 but not on Tahoe 26, and it needs an existing SwiftUI render tree — [steipete.me](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- NSViewRepresentable-wrapped AppKit views reportedly don't display inside MenuBarExtra, in either the label or the content — [zenn.dev/kyome](https://zenn.dev/kyome/articles/9f0f1969b5553c)
- FluidMenuBarExtra's README says the built-in API "doesn't animate" and doesn't close the pop-up correctly. A related project says smooth resize animations are not possible without a lot of work — [FluidMenuBarExtra](https://swiftpackageregistry.com/wadetregaskis/FluidMenuBarExtra)
- Common guidance (2026) is to start with `MenuBarExtra(.window)` and move to NSStatusItem + NSPanel "when you hit a wall." NSStatusItem gives multiple click targets, dynamic width, and popovers — [malukenho, Apr 2026](https://malukenho.github.io/post/2026/04/04/swift-macos-menu-bar-apps.html); [multi.app: pushing the limits of NSStatusItem](https://multi.app/blog/pushing-the-limits-nsstatusitem)
- A borderless, non-activating NSPanel stays anchored even when Ice or Bartender hides the status icon — [MenuBarKit](https://github.com/gabriarceus/MenuBarKit)

**Windows, popovers, menus (macOS 27)**
- Ivan Pavlov (Aug 2026): on macOS 27, a view that shows a popover more than once crashes the app. Rosyna Keller: SwiftUI can't build submenus dynamically, and the App menu is computed once with no AppKit reference available. Siracusa (Sep 2026) on fitting a window to SwiftUI content: "one of the hardest problems in computer science." Marc Palmer: presentation state is "a leaky abstraction." Luc Vandal: `reorderable()` crashes with `if #available` in the body — [mjtsai appleOS 27](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/)
- New in macOS 27: `@State` is now a macro (avoids repeated evaluation), toolbar `visibilityPriority`, `reorderable()`/`reorderContainer`, swipe actions outside List, and automatic inactive-window styling — [Apple WWDC26 SwiftUI guide](https://developer.apple.com/wwdc26/guides/swiftui/); [macOS 27 release notes via mjtsai](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/)

**Observation**
- Automatic Observation tracking in AppKit `layout()`/`viewWillLayout()` has been available since macOS 15 behind the `NSObservationTrackingEnabled` Info.plist key. This lets an NSTableView cell view re-render from `@Observable` models without manual KVO. Tsai notes it only handles a fixed set of observed objects — [steipete.me](https://steipete.me/posts/2025/automatic-observation-tracking-uikit-appkit); [mjtsai](https://mjtsai.com/blog/2025/06/18/automatic-observation-tracking-in-uikit-and-appkit/)
- WWDC26 session 272 covers Observation-driven updates and incremental SwiftUI adoption in AppKit apps — [WWDC26 #272](https://developer.apple.com/videos/play/wwdc2026/272/)
- Jacob Bartlett measured about 92 MB (UIKit) vs 248 MB (SwiftUI) memory in a scroll-view test. That was on iOS, so it is indicative only — [via mjtsai](https://mjtsai.com/blog/2025/06/18/)

### Inferences
- The Processes view (~700 rows, grouped by app, sortable, 1 Hz) is the classic NSOutlineView case. With fixed row heights, diffing by PID, and `reloadData(forRowIndexes:columnIndexes:)` on changed cells only, the per-tick work stays small and selection and scroll stay stable. SwiftUI `Table` with `DisclosureTableRow` might cope at 700 rows on an M5, but the reported selection hangs, scroll jumps, and lack of fixed-height control make it the riskier choice.
- Use one `@Observable` store per process row, so a tick only invalidates changed rows and the whole array is never re-published. This applies whether SwiftUI or AppKit renders the rows (via `NSObservationTrackingEnabled`).
- Menu bar: prototype with `MenuBarExtra(.window)`. Expect to move to NSStatusItem + NSPanel hosting SwiftUI (NSHostingView) for live ring gauges, controlled show and hide animation, opening the main window or settings, and the macOS 26/27 `openSettings` bug.
- Use the SwiftUI app lifecycle with an `NSApplicationDelegateAdaptor` for status-item and panel management. This is the hybrid most polished indie Mac apps use.

### Gaps
- No measured 2026 benchmark exists for SwiftUI Table vs NSTableView at ~700 rows updating at 1 Hz on macOS 27. A spike test on the M5 is recommended.
- Whether the macOS 27 popover-crash bug (Pavlov) has been fixed in 27.1 or 27.2 wasn't verified.

## Q3. Swift Charts performance with large time series, live updates, drag gestures, and vectorized APIs. When do people drop to Canvas or Metal?

### Takeaway
Swift Charts is right for Talon's charts if you *downsample first*: render about 500–2,000 points per series per range (LTTB or min/max buckets), never raw 500k. Use the vectorized `LinePlot`/`AreaPlot` (macOS 15+) for the dense series, and Mark APIs (`RuleMark`, `PointMark`) for the ceiling line and event markers. The ceiling drag works through `chartOverlay`/`chartGesture` + `ChartProxy`, with NSHapticFeedbackManager ticks. No new 2D large-dataset API shipped in WWDC25 (which added 3D) or WWDC26, as far as I could find. Canvas or Metal is only warranted if you insist on drawing more than about 20–100k raw points.

### Cited Findings
- WWDC24 session 10155, "Swift Charts: Vectorized and function plots," introduced `LinePlot`, `AreaPlot`, `PointPlot`, `RectanglePlot`, and `BarPlot` taking whole collections plus key paths. Apple advises using them for large datasets with uniform styling, grouping data by style to reduce style switches, skipping styling that isn't visible at density, and making computed properties stored. Mark APIs are for small, individually styled data (2024, still the current API) — [WWDC Notes 10155](https://wwdcnotes.com/documentation/wwdc24-10155-swift-charts-vectorized-and-function-plots/); [Apple video](https://developer.apple.com/videos/play/wwdc2024/10155/)
- WWDC25 session 313 added `Chart3D` and `SurfacePlot`, plus z-values for Point/Rule/RectangleMark (macOS 26). Nothing in it targets 2D large-dataset performance — [WWDC25 #313](https://developer.apple.com/videos/play/wwdc2025/313/)
- For WWDC26/macOS 27, the only Charts item found is a type-check slowdown with deeply branching chart content when the deployment target is below 27, fixed by extracting branches into `@ChartContentBuilder` functions. No new Charts APIs were found — [onmyway133, What's new in SwiftUI iOS 27](https://github.com/onmyway133/blog/issues/1048)
- Apple forum (Swift Charts with many points): from about 20k points, chart setup is slow and window resizing lags. At about 100k, "you can barely resize the window." PointPlot vs PointMark helped only modestly. The poster ended up doing LTTB downsampling off the main thread. Another poster: CoreGraphics custom drawing handles about 10k points "with reasonable UX" — [Apple Dev Forums 740314](https://developer.apple.com/forums/thread/740314)
- Christian Beer (2025): a SwiftUI BarChart with 99,384 items "brings SwiftUI BarChart to its knees" and uses a lot of memory. He criticises the lack of a data-source/delegate model — [via mjtsai](https://mjtsai.com/blog/2025/06/18/)
- Interaction: a `ChartProxy` comes from `chartOverlay`/`chartBackground` and converts between data values and screen positions (`value(at:as:)`, `position(forY:)`). `chartGesture` (iOS 17/macOS 14+) gives a proxy-aware custom DragGesture, and `chartXSelection`/`chartYSelection` give one-line selection — [Apple ChartProxy docs](https://developer.apple.com/documentation/charts/chartproxy); [Swift with Majid: selection](https://swiftwithmajid.com/2023/07/18/mastering-charts-in-swiftui-selection/); [Swift with Majid: interactions (2023, older)](https://swiftwithmajid.com/2023/02/06/mastering-charts-in-swiftui-interactions/)
- Known bug: a DragGesture sequenced after a LongPressGesture reports no value until the pointer moves — [Swift Charts forums tag](https://developer.apple.com/forums/tags/swift-charts?page=2)
- Vendor benchmark (SciChart, 2019, marketing, flagged old): their Metal-backed iOS chart stays above 35 FPS at 100k points with 1k appended per tick, and the other libraries struggled much earlier — [SciChart](https://www.scichart.com/ios-chart-performance-comparison/)

### Inferences
- Data budget: 1 h at 1 Hz is 3,600 points (fine raw). 24 h is 86,400 points and should be downsampled to about 1–2k. For 7 d, 30 d, and 1 y, store pre-aggregated rollups (1-min, 15-min, 1-h, 1-day min/avg/max) in the persistence layer and plot avg with a min–max `AreaPlot` band. With this design the chart never sees more than about 2k points, and the 500k worry disappears.
- Live updates at 1 Hz: append to a ring buffer and republish a new downsampled array. Animate x-domain shifts with `.animation(.smooth, value: domain)`, or avoid animating every tick to prevent jitter. For range switches (1 h to 24 h), crossfade or animate the domain. Chart transitions between datasets with different point counts don't interpolate line paths well, so consider a matching-count resample for smooth morphs (inference, unverified).
- Ceiling drag: draw `RuleMark(y: ceiling)` with a custom handle annotation. Use `chartOverlay { proxy in ... }` with a `DragGesture` that maps `location.y` to a value via `proxy.value(atY:)`, snaps to round values (for example every 0.5 GB or 5%), and calls `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` on each snap crossing. Use `.levelChange` for crossing significant thresholds (that pattern exists in AppKit's `FeedbackPattern`; from prior knowledge, unverified). Throttle so ticks fire only when the snapped value changes.
- Event markers: `RuleMark(x:)` plus `.annotation` with SF Symbols, or `PointMark` with symbol overlays. These are few in number, so Mark APIs are fine.
- Drop to `Canvas` or Metal only for a high-density sparkline grid (for example 700 per-process sparklines) or raw-point scrubbing. Even then, `Canvas` with a prebuilt `Path` from downsampled data is enough, and Metal isn't justified for this workload. DGCharts (the Charts port of MPAndroidChart, UIKit/AppKit) adds no Liquid Glass or SwiftUI-native animation benefits and looks un-Apple-like by default (inference; no 2025–2026 source fetched).
- Menu bar ring gauges: these are not charts. Use `Circle().trim(from:to:)` with `.stroke` and `AngularGradient`, plus `.contentTransition(.numericText())` and `.monospacedDigit()` for labels. If many gauges animate continuously, use `TimelineView(.animation)` sparingly, since CPU cost matters for a monitoring app.

### Gaps
- No measured 2025–2026 numbers for vectorized `LinePlot` at 10k–500k points on Apple silicon were found. A micro-benchmark on the M5 is recommended (LinePlot at 2k, 20k, and 100k points, with frame time on resize and on 1 Hz append).
- Not verified whether SwiftUI's `.sensoryFeedback` on macOS maps to trackpad haptics as reliably as calling NSHapticFeedbackManager directly. Prior knowledge says macOS supports `.alignment`, `.levelChange`, and generic feedback, but this is unverified. Call AppKit directly to be safe.
- No WWDC26 Swift Charts session was located. If one exists, it should be checked for new scrolling or large-data APIs.

## Q4. Liquid Glass adoption APIs and design guidance for macOS 26/27

### Takeaway
Rebuild with the macOS 26/27 SDK and standard controls (NavigationSplitView sidebar, toolbars, sheets, menus) pick up Liquid Glass automatically. Use `glassEffect` plus `GlassEffectContainer` only for custom floating chrome, such as the menu-bar panel's control clusters and the chart's floating range picker. Never use glass for content like charts or tables.

### Cited Findings
- `glassEffect(_:in:)` applies glass clipped to a shape (capsule by default). The `Glass` variants are `.regular`, `.clear`, `.tint(_:)`, and `.interactive()`. `GlassEffectContainer(spacing:)` groups elements for shared sampling and morphing. Also available: `glassEffectID(_:in:)` for morph transitions, `glassEffectUnion`, `glassEffectTransition`, and `.buttonStyle(.glass)`/`.glassProminent` — [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views). The page body couldn't be extracted, so these API names come from the fetch tool's general knowledge plus community guides: [blakecrosley.com](https://blakecrosley.com/blog/liquid-glass-swiftui-patterns); [steipete swiftui-liquid-glass skill](https://skills.cat/skills/steipete/agent-scripts/swiftui-liquid-glass)
- A GlassEffectContainer reduced the CABackdropLayer count from 2 to 1 in one developer's inspection. That article also lists hit-testing issues with glass buttons and a rotation bug on padded text (iOS 26.1) — [Juniper Photon: Adopting Liquid Glass](https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences)
- Community guidance: nearby glass elements should share a container. Apply `.glassEffect` after layout modifiers. Avoid nesting glass on glass. Morph only on real hierarchy changes, honour Reduce Motion, and remember that glass on a flat background reads flat — [skills.sh/haider-nawaz](https://skills.sh/haider-nawaz); [blakecrosley.com](https://blakecrosley.com/blog/liquid-glass-swiftui-patterns)
- AppKit equivalent: `NSGlassEffectView` (macOS 26+), which Electron and Flutter wrappers bridge to — [electron-liquid-glass](https://github.com/Meridius-Labs/electron-liquid-glass); [real_liquid_glass](https://pub.dev/documentation/real_liquid_glass/0.3.0/)
- On Tahoe the menu bar is transparent by default, and legibility over light wallpapers is a known complaint. Users can revert to an opaque bar — [MacMost](https://macmost.com/how-to-tame-liquid-glass-on-your-mac.html); [TidBITS](https://tidbits.com/?p=71909)
- macOS 27 SwiftUI automatically adjusts visuals for inactive windows, with new environment values to customise it — [Apple WWDC26 SwiftUI guide](https://developer.apple.com/wwdc26/guides/swiftui/)
- Widget-style glass may hurt readability over busy wallpapers (third-party, general caution) — [macos-tahoe.com widgets guide](https://macos-tahoe.com/blog/macos-tahoe-widgets-customization-complete-guide-2025/)

### Inferences
- In the menu-bar panel, use an NSPanel or MenuBarExtra window with system glass as the background, rings on top, and `GlassEffectContainer` around grouped buttons. Ensure gauge colours keep contrast in both the `.clear` and "Reduce Transparency" modes.
- In the main window, the sidebar gets glass for free. Keep chart and table backgrounds opaque or standard material for legibility, and put glass only on floating controls such as the range segmented picker and the "Set ceiling" pill.
- Test with Accessibility → Reduce Transparency and Increase Contrast, plus the user's opaque-menu-bar setting.

### Gaps
- Apple HIG Liquid Glass text and macOS 27-specific changes to glass APIs (if any) couldn't be fetched or verified this session.

## Q5. WidgetKit on macOS: requirements, App Groups, signing (free personal team / ad-hoc), interactive widgets

### Takeaway
Widgets need a sandboxed widget extension embedded in the app, shared data through an App Group, and real code signing. Ad-hoc ("Sign to Run Locally") builds commonly fail to show widgets or lack a shared container. Whether a free Personal Team is enough is unconfirmed. The pragmatic advice is to budget for the $99 Apple Developer Program, or at least test early with a Personal Team.

### Cited Findings
- Since macOS Sequoia, Mac App Group IDs must be prefixed with the Team ID (`$(TeamIdentifierPrefix)`), while iOS uses the `group.` prefix. Multiplatform templates break this, and one fix was separate macOS and other-platform targets — [Apple Dev Forums 758478](https://developer.apple.com/forums/thread/758478); [Apple Dev Forums 765020](https://developer.apple.com/forums/thread/765020)
- WidgetKit discovers widgets from the *installed* app bundle. Running from DerivedData can hide widgets, so install to /Applications. "Failed to load widget" / WidgetKit Simulator error 4 indicates App Group or signing misconfiguration — [Apple Dev Forums 751747](https://developer.apple.com/forums/thread/751747); [751176](https://developer.apple.com/forums/thread/751176)
- Ad-hoc signed builds have no shared App Group container, according to tauri-plugin-widgets docs — [tauri-plugin-widgets macOS setup](https://docs.rs/crate/tauri-plugin-widgets/0.4.3/source/docs/guide/setup/macos.md)
- Widget extensions are always sandboxed. App Groups must be enabled in both the app and the widget target — [tauri-plugin-widgets macOS setup](https://docs.rs/crate/tauri-plugin-widgets/0.4.3/source/docs/guide/setup/macos.md)
- macOS may delay or throttle widget timeline refreshes — [tauri-plugin-widgets transport.rs](https://docs.rs/crate/tauri-plugin-widgets/latest/source/src/transport.rs)
- Apple's capability table distinguishes ADP, Developer ID, and free "Apple Developer" accounts. Row-level checkmarks couldn't be extracted — [Apple: Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
- Stats (exelban) ships macOS desktop widgets, and its FAQ covers "Desktop widgets not showing the data." It requires enabling a "macOS widgets" setting, which shows widget data-sharing is a known friction point even for a mature app — [exelban/stats README](https://github.com/exelban/stats)

### Inferences
- Interactive widgets (Button/Toggle with AppIntents, macOS 14+) suit Talon's "Care" actions, such as a one-tap "free memory" or "pause process" intent. The intent runs in the widget or app process, so privileged actions need the main app or a helper (prior knowledge, unverified).
- Widget refresh is budgeted, so widgets will show at best minute-level freshness, not 1 Hz. Design them as summaries, and call `WidgetCenter.shared.reloadTimelines` from the app when thresholds cross.
- Signing plan: develop with an Apple ID Personal Team first. If widgets don't appear or App Group containers fail, the $99 ADP membership resolves it and also gives Developer ID notarisation.

### Gaps
- Not confirmed whether a free Personal Team can provision team-prefixed App Groups plus a widget extension on macOS 26/27. The Apple capability table's checkmarks didn't render. Prior knowledge suggests macOS allows team-prefixed app groups without explicit registration, but Sequoia+ may prompt about access to other apps' data. Unverified.
- Whether a non-sandboxed host app (likely needed for process inspection and `task_info` on other PIDs) plus a sandboxed widget sharing an App Group works without prompts on macOS 27 wasn't verified.

## Q6. Examples of beautiful native Mac utility apps and their stacks

### Takeaway
The admired Mac utilities are Swift and AppKit at the core, with SwiftUI used selectively. The one high-profile 2026 move away from that, Raycast 2 to WebView, was driven by Windows support and cost about 150 MB of RAM. Source verification for most apps' internal stacks was thin.

### Cited Findings
- Raycast v1: native Swift on AppKit with custom components. The team chose *not* to use SwiftUI, citing crash-rate and performance confidence. Extensions render through a custom React reconciler into AppKit views — [Raycast: How the API and extensions work](https://raycast.com/blog/how-raycast-api-extensions-work)
- Raycast v2 (2026): a Swift/AppKit host with a React UI in WKWebView. SwiftUI "never quite cleared our bar for performance and control." Memory is about 350–450 MB vs 200–300 MB for v1 — [Raycast blog, May 2026](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)
- Stats (exelban): an open-source Swift/Xcode project (`Stats.xcodeproj`), MIT, macOS 12+, with menu bar modules and desktop widgets. Its FAQ says disabling the Sensors and Bluetooth modules can cut its CPU and power use by up to 50%, so sampling cost is a real concern for monitor apps — [exelban/stats](https://github.com/exelban/stats)

### Inferences
- Stats is widely understood to be AppKit with custom NSView/CoreGraphics-drawn mini charts, not Swift Charts (prior knowledge, unverified, since the README doesn't state it). Ice (jordanbaird) is understood to be SwiftUI plus AppKit (prior knowledge, unverified). The original iStat Menus (Bjango), CleanMyMac (MacPaw), AlDente, and Sensei are understood to be native Swift/Objective-C and AppKit-centric apps (unverified).
- Pattern to emulate: an AppKit "spine" (status item, panels, big tables) with SwiftUI for most views and widgets, plus custom lightweight drawing for tiny sparklines.

### Gaps
- No primary sources were fetched confirming the UI frameworks of iStat Menus 7, CleanMyMac (2024+ redesign), Ice, AlDente, or Sensei. A follow-up researcher could check Ice's GitHub repo and Bjango's blog.

## Q7. Recommendation and known pitfalls

### Takeaway
Use a SwiftUI-first app with an AppKit spine, on the macOS 26/27 SDK and Swift 6.4. The UI uses SwiftUI's App lifecycle, NavigationSplitView, standard toolbars, and Liquid Glass. Use AppKit for an NSStatusItem + NSPanel (SwiftUI-hosted) menu bar panel, an NSOutlineView Processes list, and NSHapticFeedbackManager. Charts use Swift Charts' vectorized LinePlot/AreaPlot over pre-aggregated, downsampled data, with Mark overlays and a `chartOverlay` drag for the ceiling. Use Canvas only for dense sparkline grids, and no Metal. Widgets use WidgetKit (SwiftUI) sharing an App Group. Reject Tauri, Electron, Flutter, and Compose.

### Cited Findings
- SwiftUI Table/List is still behind NSTableView for large live lists despite WWDC25's 6x/16x claims — [mjtsai 2025](https://mjtsai.com/blog/2025/06/18/swiftui-at-wwdc-2025/); [mjtsai appleOS 27](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/)
- MenuBarExtra has settings, animation, and AppKit-hosting limitations on macOS 26 — [steipete.me](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items); [FluidMenuBarExtra](https://swiftpackageregistry.com/wadetregaskis/FluidMenuBarExtra)
- Swift Charts degrades from about 20k points, and the standard workaround is LTTB downsampling — [Apple Dev Forums 740314](https://developer.apple.com/forums/thread/740314)
- Web and Flutter shells need private-API or platform-view hacks for glass and separate Xcode projects for widgets — [window-vibrancy](https://docs.rs/crate/window-vibrancy/latest/source/src/macos/mod.rs); [tauri-plugin-widgets](https://docs.rs/crate/tauri-plugin-widgets/0.4.3/source/docs/guide/setup/macos.md); [real_liquid_glass](https://pub.dev/documentation/real_liquid_glass/0.3.0/)

### Inferences
Known pitfalls checklist for the report:
1. **The Processes table at 1 Hz.** Don't republish a 700-element array each tick. Use per-row `@Observable` objects or NSOutlineView with targeted reloads, stable identity (PID plus start time), and fixed row heights. Preserve selection and scroll position across ticks, and pause sorting while the user hovers or drags.
2. **The monitor's own footprint.** A system monitor must be cheap. Sample once on a background actor and fan out. Stop chart and UI updates when windows are hidden or occluded (`NSWindow.occlusionState`) and when the panel is closed. Avoid `TimelineView(.animation)` running permanently in the menu bar.
3. **MenuBarExtra.** The `openSettings`/`SettingsLink` bug on 26+, no NSViewRepresentable inside it, and weak animation control. Plan the NSPanel escape hatch from day one.
4. **macOS 27 SwiftUI bugs.** A repeated-popover crash and `reorderable()` crashes have been reported. Pin to 27.2 and test.
5. **Charts.** Never feed raw 24 h/7 d/1 y data. Keep the point count constant across range switches for smooth transitions. Use `@ChartContentBuilder` helpers to avoid type-check slowdowns. Keep the drag gesture's minimum distance at 0, and beware the LongPress→Drag sequencing bug.
6. **Haptics.** These only fire when the user's finger is on a Force Touch trackpad and for user-initiated actions. Fire on snapped-value changes only, and filter by velocity as Apple suggests.
7. **Liquid Glass.** Keep content layers opaque, group glass in containers, test Reduce Transparency, Increase Contrast, and the opaque menu bar, and avoid glass on glass.
8. **Widgets and signing.** Use a team-prefixed App Group on macOS. Install to /Applications to test. Ad-hoc signing likely breaks the shared container, so budget for ADP if a Personal Team fails. Refresh is throttled, so widgets show summaries, not live data.
9. **Profiling.** Instruments' SwiftUI template has been reported to show "no SwiftUI data" in Xcode 26/27, so also use Time Profiler and `os_signpost`.

### Gaps
- The recommendation's performance thresholds (700 rows, 2k chart points) are reasoned from reports, not measured on M5 / macOS 27. Two quick spikes (a Table vs NSOutlineView tick test and a LinePlot point-count sweep) would confirm them.
