# MacBook Air M5 battery: health, ageing and longevity (for the Talon health app)

Scope note: research done 2026-11-08. Machine context from the user: MacBook Air Mac17,3 (M5), macOS 27.0.1, CycleCount 97, DesignCapacity 4629 mAh, NominalChargeCapacity 4315 mAh, FullChargeCapacity 4188 mAh, Qmax ~4524–4535 mAh per cell, System Information "Maximum Capacity 97 %", pack ~11.2 V (3 cells in series).

## 1. Battery specs for the M5 MacBook Air (Wh, chemistry, configuration, rated cycles)

### Takeaway
The 13-inch M5 MacBook Air (Mac17,3, released 11 March 2026) has a ~53.8 Wh lithium-polymer pack (15-inch: ~66.5 Wh). Apple officially rates every Apple silicon MacBook Air, including both M5 sizes, at 1000 cycles to retain up to 80 % of original capacity under ideal conditions.

### Cited Findings
- Mac17,3 is the 13-inch MacBook Air with M5; announced 3 March 2026, released 11 March 2026; battery listed at 53.8 Wh; Apple claims up to 15 h wireless web and up to 18 h video playback — [The Apple Wiki: MacBook Air (13-inch, M5)](https://theapplewiki.com/wiki/Mac17,3) (via search snippet; page returned 403 on direct fetch)
- A retailer listing also gives 53.8 Wh for the 13-inch; a 15-inch M5 listing gives 66.5 Wh — [Connection.com 13-inch](https://www.connection.com/product/apple-macbook-air-13-m5-chip-w-10c-cpu-and-10c-gpu-16gb-1tb-ssd-starlight/mdhc4ll-a/42114533); [Connection.com 15-inch](https://www.connection.com/product/apple-macbook-air-15-m5-chip-w-10c-cpu-and-10c-gpu-16gb-1tb-ssd-starlight/mdve4ll-a/42114545)
- Conflict: an iFixit-derived spec sheet lists 52.6 Wh lithium-polymer for the 13-inch M5 — [iFixit mirror: MacBook Air 13" 2026 (M5)](https://portalidea.wiki/ifixit_pt_all_2026-03/Device/MacBook_Air_13%22_2026_%28M5%29). Unresolved; 53.8 Wh is the majority figure and matches the user's measured design capacity (see Inferences).
- Apple's cycle-count table lists the MacBook Air 13-inch M5 and 15-inch M5 (and M4, M3, M2, M1 Airs) at a maximum cycle count of 1000 — [Apple Support 102888: Determine battery cycle count for Mac laptops](https://support.apple.com/en-us/102888)
- Apple: "Your battery is designed to retain up to 80% of its original charge capacity at its maximum cycle count"; footnote says testing was under ideal conditions and real results vary with use, configuration and charging behaviour — [Apple Support 102888](https://support.apple.com/en-us/102888)
- Apple: a charge cycle is counted when you have used 100 % of the battery's capacity cumulatively, not necessarily in one discharge (e.g. two 50 % discharges = one cycle) — [Apple Support 102888](https://support.apple.com/en-us/102888)
- Apple recommends replacing the battery when it reaches its maximum cycle count "for best performance" — [Apple Support HT201585](https://support.apple.com/en-us/ht201585)
- Apple's newest laptop (MacBook Neo) is also listed at 1000 cycles — [MacRumors, 11 Mar 2026](https://www.macrumors.com/2026/03/11/macbook-neo-battery-cycle-count-listed/)

### Inferences
- The user's DesignCapacity 4629 mAh × ~11.62 V nominal (3S Li-ion/Li-polymer, ~3.87 V per cell) ≈ 53.8 Wh, which corroborates the 53.8 Wh figure and a 3-series-cell pack. The measured ~11.2 V is an instantaneous pack voltage, below nominal at mid-SoC/under load, which is normal. Qmax is reported per cell (three values), consistent with three series cells.
- Exact cathode chemistry is not published by Apple. Laptop pouch cells are typically graphite-anode with a cobalt- or nickel-rich layered-oxide cathode (LCO/NMC family). Treat Battery University "NMC/Li-ion" figures as the closest proxy, not M5-specific data.
- 97 cycles = ~9.7 % of the rated 1000-cycle life. A simple linear interpolation of Apple's spec (100 % → 80 % over 1000 cycles) gives ~2 % capacity loss per 100 cycles, so a ~2–3 % drop by now would be "on spec". Real fade is front-loaded (see section 3), so early numbers a bit worse than linear are not alarming.

### Gaps
- No Apple primary source found for the M5 Air's exact Wh in this session (apple.com tech-specs page not fetched; Apple Wiki 403). 52.6 vs 53.8 Wh discrepancy unresolved.
- Cell supplier, cathode chemistry, charge cut-off voltage per cell, and maximum charge rate (C-rate) for the M5 Air pack: no reliable public source found.
- Apple's fast-charge spec for the M5 Air (adapter wattage, % in 30 min) not confirmed in this session.

## 2. How Apple computes "Maximum Capacity" vs raw ioreg values; which value to trend

### Takeaway
Apple does not document its formula. Community and tool authors mostly use AppleRawMaxCapacity (≈ FullChargeCapacity) ÷ DesignCapacity, but on the user's machine that gives ~90 % and NominalChargeCapacity ÷ Design gives 93.2 %, while System Information shows 97 % — closest to Qmax ÷ Design (~97.8 %). Talon should store all raw values, display Apple's figure as the "official" number, and trend NominalChargeCapacity (or Qmax) against DesignCapacity, smoothed over weeks.

### Cited Findings
- batt maintainer (charlie0129, 2 Mar 2026) gives health = AppleRawMaxCapacity / DesignCapacity; sample on a different Mac: 5772 / 6249 ≈ 92.4 %. Same dump: NominalChargeCapacity 5924 (≈94.8 %), Qmax (6380, 6385, 6372) i.e. >100 % of design, FccComp1 = FccComp2 = 5772, MaxCapacity = 100, CycleCount 173 — [batt issue #124](https://github.com/charlie0129/batt/issues/124)
- Apple Community users report that doing the maths on raw values leaves macOS's displayed figure off by 2–5 %, implying Apple adjusts the data — [Apple Community thread 256021109](https://discussions.apple.com/thread/256021109)
- Maximum Capacity is not guaranteed to equal any single raw value ÷ design value, and macOS can smooth the displayed result; recommends `system_profiler SPPowerDataType` or the Battery settings pane for decisions and treating ioreg as diagnostic — [Mole blog: how to check MacBook battery health](https://mole.tw93.fun/blog/how-to-check-macbook-battery-health)
- Field names differ by hardware and macOS release (AppleRawMaxCapacity, MaximumFCC, etc.) — [MacRumors forum thread](https://forums.macrumors.com/threads/wich-values-to-calculate-battery-health.2430580)
- On Apple silicon `MaxCapacity` and `CurrentCapacity` in ioreg are percentages (MaxCapacity = 100), not mAh; raw mAh are in AppleRaw* fields — [batt issue #124](https://github.com/charlie0129/batt/issues/124)
- ioreg/AppleSmartBattery key names are undocumented and could change if Apple changes the driver — [Der Flounder, 26 Dec 2022](https://derflounder.wordpress.com/2022/12/26/identifying-mac-laptops-and-desktops-from-the-command-line-by-checking-for-a-built-in-battery/)
- In TI Impedance Track gauges (the gauge family Apple's fields resemble), Qmax is the cell's maximum chemical (no-load) capacity, updated when two open-circuit-voltage readings are taken at rest; it is not the usable capacity at a given moment — [TI E2E forum, bq40z50 Qmax](https://e2echina.ti.com/support/power-management/f/power-management-forum/118504/bq40z50-qmax) (forum answer, not official TI doc)
- TI's bq40z50-R2 Technical Reference Manual has dedicated sections for QMax update conditions, Ra table, FullChargeCapacity, State of Health, and "QMax Imbalance" and "Impedance" permanent-fail conditions — [TI SLUUCH2 TRM](https://www.ti.com/document-viewer/lit/html/SLUUCH2/GUID-A0069FA6-57AB-4B26-A31A-F74DCFF7B23B) (only the table of contents was retrievable)

### Inferences
- User's machine: FCC 4188/4629 = 90.5 %; NominalChargeCapacity 4315/4629 = 93.2 %; mean Qmax ~4530/4629 = 97.9 %; Apple shows 97 %. The Apple figure lines up best with Qmax/Design (rounded down), or with a smoothed/clamped value, rather than with FCC or NCC. This is an inference from one data point; it does not match batt's formula, so Apple's formula likely differs by generation/macOS version.
- Why they differ: Qmax is chemical capacity at no load. FullChargeCapacity is the usable capacity the gauge predicts down to the cut-off voltage under the present load and temperature, so it is lower and swings with load, temperature and internal resistance (Ra). NominalChargeCapacity appears to be a less load-dependent version of FCC. Gauge learning (Qmax update) only happens after suitable rests, so values move in steps.
- Best value to trend: NominalChargeCapacity ÷ DesignCapacity (or Qmax mean ÷ DesignCapacity) as the "raw health" line, a 7-day median to filter noise, plus Apple's Maximum Capacity as the user-facing number. Avoid trending FullChargeCapacity day-to-day: it is the most load- and temperature-sensitive.
- macOS 27 note from the user: top-level `DesignCapacity` and `Temperature` keys read 0; read DesignCapacity from `BatteryData` and temperature from elsewhere (e.g. BatteryData/`VirtualTemperature` or SMC), and build Talon to fall back gracefully when a key is 0 or absent.

### Gaps
- No Apple primary documentation of the Maximum Capacity formula exists that I could find.
- TI TRM body text on QMax update conditions, Ra units and SOH formula could not be retrieved (only TOC). Whether Apple's gauge is TI Impedance Track on M5 is not confirmed.

## 3. Li-ion ageing science (high SoC, heat, depth of discharge, fast charging, calendar vs cycle ageing)

### Takeaway
Two mechanisms: calendar ageing (time spent at high state of charge and temperature, mostly SEI growth on the graphite anode) and cycle ageing (depth of discharge, charge rate, temperature during charge). For a laptop that sits plugged in, the biggest controllable factors are time spent at 100 % and heat; shallow cycles in the middle of the SoC range are far gentler than full 0–100 % cycles.

### Cited Findings
- Battery University cycle life to 70 % capacity vs depth of discharge, NMC: 100 % DoD ~300 cycles; 80 % ~400; 60 % ~600; 40 % ~1,000; 20 % ~2,000; 10 % ~6,000 — [Battery University BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- Battery University capacity retained after 1 year of storage: 0 °C 98 % (40 % SoC) vs 94 % (100 %); 25 °C 96 % vs 80 %; 40 °C 85 % vs 65 %; 60 °C 75 % (1 yr, 40 % SoC) vs 60 % after only 3 months at 100 % — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- Charge voltage per cell vs cycles: 4.30 V 150–250 cycles; 4.20 V 300–500 (100 % energy); 4.13 V 400–700 (90 %); 4.06 V 600–1,000 (81 %); 4.00 V 850–1,500 (73 %); 3.92 V 1,200–2,000 (65 %). Rule of thumb: each 0.10 V below 4.20 V roughly doubles cycle life; each 70 mV drop costs ~10 % capacity. Note: BU's text and table disagree on 4.10/4.00 V values — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- BU: above 30 °C is "elevated"; above 4.10 V/cell is "high voltage"; a cell held fully charged at elevated temperature is the worst case and can be more damaging than cycling — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- BU partial-cycling windows: 75–25 % SoC ≈ 3,000 cycles to 90 % capacity; 85–25 % ≈ 2,000 cycles; 100–25 % gives long runtime but short life — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- BU: charge energy cells at 1C or less; avoid ultra-fast charging (<1 h to full), which shortens life — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- BU cites a Chalmers study: keeping 50 % SoC extended EV Li-ion life by 44–130 % — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- Keil et al. 2016 (J. Electrochem. Soc. 163(9) A1872) tested NCA, NMC and LFP 18650 cells at 16 SoCs from 0–100 % and several temperatures: calendar fade is not a smooth function of SoC; there are plateaus spanning 20–30 % of SoC with similar fade; main driver is low graphite-anode potential (high SoC) promoting SEI growth, i.e. loss of lithium inventory. For the NCA cells a storage SoC below ~55–70 % was needed to avoid the high-fade plateau — [TUM mediatum PDF](https://mediatum.ub.tum.de/doc/1651485/document.pdf); [ECS abstract](https://ecs.confex.com/ecs/imlb2016/webprogram/Paper76672.html)
- A dataset of 232 commercial cells tracked up to 13 years: calendar ageing of NMC cells follows a t^0.5 (square-root of time) law with Arrhenius temperature dependence — [OSTI 2536694](https://www.osti.gov/servlets/purl/2536694) (via search summary)
- KIT study: storage at 100 % SoC has a large impact on ageing; below 80 % the SoC influence is small — [KIT publication](https://publikationen.bibliothek.kit.edu/1000133836/117458694) (via search summary)
- 2026 model paper (P2D electrochemical-thermal-degradation, NMC) shows fade can be sub-linear, linear or accelerating ("knee") depending on temperature (10/25/40 °C), C-rate (0.1–1C) and rest SoC (10/60/100 %) — [arXiv 2604.09217](https://arxiv.org/pdf/2604.09217)
- Apple: battery chemical age depends on "temperature history and charging pattern" — [Apple Support 102338](https://support.apple.com/en-us/102338)
- Apple: MacBook works best at 10–35 °C ambient; storage −20 to 45 °C; ambient above 35 °C can permanently damage battery capacity; for long-term storage charge to ~50 % (full discharge risks deep-discharge failure, full charge loses capacity) and recharge to 50 % every six months — [Apple: Maximizing Battery Life and Lifespan](https://www.apple.com/za/batteries/maximizing-performance/)

### Inferences
- Because calendar fade follows ~√t, a new pack loses capacity fastest in its first months, which plausibly explains some of the user's early drop (NCC 93.2 % after ~8 months / 97 cycles).
- The 80 % vs 100 % distinction matters more than 80 % vs 60 % (KIT; Keil plateaus): an 80 % cap captures most of the calendar-ageing benefit for a plugged-in laptop.
- BU numbers come from generic cells and lab conditions; use them for direction and rough magnitude in Talon copy, not as predictions for this pack.

### Gaps
- No M5-Air-specific ageing data (Apple or third-party long-term tests) found.
- Keil 2016 NMC-specific numbers and exact temperature coefficients not read in full text.
- No quantitative data found on the impact of USB-C/MagSafe "fast charge" on MacBook packs specifically.

## 4. What macOS offers (2025–2026): Optimized Battery Charging, Charge Limit, Low Power Mode

### Takeaway
Yes, Macs now have a built-in charge limit: macOS Tahoe 26.4 (spring 2026) added "Charge Limit" for Apple silicon Macs, adjustable 80–100 % (in 5 % steps per press reports), alongside Optimized Battery Charging (ML-based hold at 80 %). Both occasionally charge to 100 % for gauge calibration, and on macOS 27 that calibration has been reported to get stuck and override limits.

### Cited Findings
- Charge Limit requires macOS Tahoe 26.4 or later and Apple silicon; settable 80–100 %; Mac charges "to within a few percentage points" of the limit then stops and shows "Charged to [%] Limit"; if charge drops more than 5 % while plugged in, charging resumes; "Charge to Full Now" overrides — [Apple Support 102338](https://support.apple.com/en-us/102338)
- Optimized Battery Charging (macOS Big Sur 11+): on-device machine learning learns your routine and delays charging past 80 % when it predicts long plug-in, aiming to be full when you need it; menu shows "Charging On Hold"; on Ventura+ it can be turned off until tomorrow — [Apple Support 102338](https://support.apple.com/en-us/102338)
- With either feature on, the Mac occasionally charges to 100 % to keep state-of-charge estimates accurate — [Apple Support 102338](https://support.apple.com/en-us/102338)
- Setting path: System Settings > Battery > info (i) button next to Charging — [Apple Support 102338](https://support.apple.com/en-us/102338)
- Press coverage: Charge Limit announced with macOS Tahoe 26.4 (Feb 2026 beta); steps 80/85/90/95/100 %; separate from Optimized Battery Charging, which can still bring the Mac to 100 % — [MacRumors, 16 Feb 2026](https://www.macrumors.com/2026/02/16/mac-charge-limit-macos-tahoe-26-4/); [iDownloadBlog, 26 Mar 2026](https://www.idownloadblog.com/2026/03/26/battery-charge-limit-macbook/)
- Intel Macs do not get Charge Limit — [TurtleBar guide](https://www.turtlebar.app/guides/macbook-charge-limit-80-percent)
- An Apple Community user reports an M5 MacBook Air's 80 % limit not being adhered to after a Tahoe update; reply in thread said it would not be treated as a bug (single anecdotal report) — [Apple Community thread 256286525](https://discussions.apple.com/thread/256286525)
- macOS 27.0.1: Apple's battery-gauging mitigation (`ChargingUpForGauging`, hourly `GaugingMitigationActions` job) charges to 100 % to recalibrate the fuel gauge; in reported cases it never finished and ignored both AlDente's and macOS's native 85 % limit (logs: battery mitigations in place, limit will be ignored). Affected: M1 Pro/Max MacBook Pros and an M3 MacBook, several with third-party replacement batteries; suspected cause Qmax/DOD0 never updating. Workaround (unsupported): move `/Library/Preferences/com.apple.powerd.batterygauging.plist` and reboot — [AlDente issue #1842](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1842)
- Follow-up on macOS 27.2: calibration overrides limit; resetting the gauging file reportedly no longer helps; AlDente workaround setting "After macOS Calibration → Discharge to Charge Limit" — [AlDente issue #1846](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1846)
- Apple's 2020 explanation of "Not Charging" while plugged in (battery health management on Intel/Catalina era) — [MacRumors, 3 Aug 2020](https://www.macrumors.com/2020/08/03/apple-mac-battery-health-not-charging) (older, Intel-era context)

### Inferences
- For Talon: the primary recommendation for the user (M5, macOS 27) should be the built-in Charge Limit at 80 % if they are mostly plugged in, since it is supported and survives sleep, versus third-party tools that now depend on private paths.
- Talon should detect and explain "calibration" top-ups to 100 % (expected occasionally), and alert only if the Mac is held at ~100 % for multiple days despite a limit (possible stuck gauging mitigation).
- Low Power Mode reduces power draw (and so heat and cycle usage on battery) but is not a battery-longevity feature per se.

### Gaps
- No Apple documentation of how often the "occasional 100 %" calibration happens, or of the gauging mitigation.
- No source found on whether macOS 27 changed Charge Limit's range (it remains 80–100 % per Apple's page). batt README claims a macOS 27 Beta 4+ "native" path supports 10–99 % via private APIs, not an Apple UI.
- Low Power Mode on Mac and any "manage battery longevity" setting were not documented in sources fetched.

## 5. Third-party charge limiting on Apple Silicon (AlDente, batt, bclm)

### Takeaway
Tools historically wrote SMC keys (CH0B/CH0C on M1–M3, CHTE on newer firmware; CH0I/CHIE for force-discharge/adapter). macOS 27 removed or locked most of these: legacy keys reportedly read empty, newer keys (bfD0/bfE0/bfF0) are not writable even as root, and control moved into powerd's private "SOC limit" path. AlDente 1.39.x and batt now work on macOS 27 mainly by driving Apple's own native limit (via PowerUIAgent preferences) or by toggling adapter power while awake. All need root/a privileged helper and can break with any update.

### Cited Findings
- batt architecture: background daemon (root) with CLI/GUI client over a unix socket; backends chosen by available SMC keys/services: Legacy (polls % and toggles charging), Firmware (writes lower/upper limits enforced by Apple firmware), Native (keeps PowerUIAgent's upper target in sync), Adapter mode (opt-in, toggles wall power). Control needs root, e.g. `sudo batt limit 80` / `sudo brew services start batt` — [charlie0129/batt README](https://github.com/charlie0129/batt)
- batt compatibility table: macOS 15 and 26 fully supported; macOS 27 Beta 1–3 used firmware-managed limits (active in sleep); Beta 4+ uses native limits 10–99 %, upper-only, and macOS may drain toward the limit while plugged in; adapter mode adds 10–100 % with a lower bound but only works while batt is awake and disables Force Discharge and auto-calibration — [batt README](https://github.com/charlie0129/batt)
- batt README: macOS 26.4+ native limit (80–100 %) may make batt unnecessary; batt still useful below 80 % and on older releases; turn off Optimized Battery Charging; disable built-in limit when using direct SMC control — [batt README](https://github.com/charlie0129/batt)
- Key sets per an open-source AlDente alternative: M1/M2/M3 use CH0B, CH0C to gate charging and CH0I to force discharge; newer chips (~2023+, Sequoia/Tahoe) use CHTE, CHIE; tested only on an M4 with Tahoe — [OpenDente](https://github.com/killerk3emstar/OpenDente)
- macOS 27 summary (30 Sep 2026): CHTE, CH0B, CH0C, CH0I, CH0J reported missing/empty; only CHIE responded (battery PR 478); Battery Toolkit fork says CHIE and ACLC remain readable; bfD0/bfE0/bfF0 return IOKit "not privileged" (0xe00002c1) even as root; one reporter (batt issue 152) says control moved to a private powerd "SOC limit" subsystem needing entitlement `com.apple.private.iokit.soc-limit` (unconfirmed); Battery Toolkit fork writes `mclLimitValue` in `com.apple.smartcharging.topoffprotection` which PowerUIAgent passes to powerd; batt adapter mode (PR 154) merged 24 Sep 2026; Battery Toolkit upstream archived 21 Mar 2026 — [macos-tahoe.com blog, 30 Sep 2026](https://macos-tahoe.com/blog/macos-27-battery-charge-limit-apps-broken-aldente-batt-charging-to-100-fix-2026/) (secondary aggregator of GitHub reports)
- AlDente: 1.38 was incompatible with macOS 27 developer betas, users needed 1.39 beta — [AlDente issue #1785](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1785); maintainer says AlDente 1.39.4 on macOS 27 holds limits below 80 % — [AlDente issue #1802](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1802); conflicting user reports of over-charging on 27.0/27.0.1 with 1.39.4 (issues 1840/1841) — [macos-tahoe.com blog](https://macos-tahoe.com/blog/macos-27-battery-charge-limit-apps-broken-aldente-batt-charging-to-100-fix-2026/)
- AlDente on macOS 27 RC with 1.39.1: charge limit not working correctly — [AlDente issue #1817](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1817)
- AlDente's sailing mode is a Pro feature and is "not intended to actively discharge" the battery (it lets the battery drift down within a range rather than micro-cycling at the limit) — [AlDente FAQ](https://apphousekitchen.com/faqnew/) (via search summary)
- Tahoe-beta (2025) reports that AlDente and similar apps stopped working, with a commenter attributing it to SMC firmware updated with the OS — [PTT MAC forum](https://www.ptt.cc/bbs/MAC/M.1749596087.A.84D.html)
- A debloat script disabling services broke both the macOS 27 built-in limiter and AlDente on an M2 Air (unresolved) — [mac-os-debloat issue #21](https://github.com/OleksandrKrupko/mac-os-debloat/issues/21)
- Hardware alternative (inline charge limiter) compared with macOS 26.4 Charge Limit — [Chargie](https://chargie.org/macos-26-4-charge-limit-vs-chargie/) (vendor source)

### Inferences
- bclm (the older single-key CLI) is effectively obsolete on Apple silicon; no source found showing it works on M-series with modern firmware.
- For an M5 on macOS 27.0.1, no source explicitly confirms AlDente or batt on M5 hardware; risk is "works via native path or not at all", rather than damage. The main risks are: conflicting with Apple's own limit/optimised charging (tools say disable them), sleep-time overcharge in adapter mode, and the stuck-calibration bug.
- Talon should not write SMC keys itself. It can read status (which tool is installed, whether the native limit is set, whether NotChargingReason indicates a hold) and recommend the native Charge Limit first, third-party only for limits below 80 % or sailing behaviour.
- Heat protection (pausing charge when hot) is a feature of AlDente Pro per its marketing; not verified in this session.

### Gaps
- No primary Apple statement on removing SMC charge keys in macOS 27.
- No confirmation of any tool tested on M5 specifically.
- batt issue #152 (powerd SOC-limit entitlement) not read directly.
- AlDente's current release notes for 1.39.x not fetched; latest version unknown.

## 6. ioreg battery fields useful for a dashboard

### Takeaway
Useful fields exist but are undocumented; meanings below come from tool authors, TI gauge terminology and inference. Key ones: CycleCount; DesignCapacity (in BatteryData on macOS 27); NominalChargeCapacity, AppleRawMaxCapacity/FullChargeCapacity; Qmax (per-cell chemical capacity); Ra/WeightedRa (internal resistance, rising with age); DailyMinSoc/DailyMaxSoc (SoC range used per day); PermanentFailureStatus (non-zero = gauge-declared fault); NotChargingReason (bitfield, undocumented).

### Cited Findings
- `ioreg -rn AppleSmartBattery` output includes a BatteryData dictionary containing WeightedRa, DailyMaxSoc, ChemID and many other keys — [batt issue #124](https://github.com/charlie0129/batt/issues/124)
- BatteryData also includes Qmax and ChemID (osquery dump via `ioreg -b -w 0 -f -r -c AppleSmartBattery`) — [osquery issue #8266](https://github.com/osquery/osquery/issues/8266)
- TI gauges: Ra is the cell's impedance (resistance) table, updated after a full learning cycle; Qmax is maximum chemical capacity updated from two rested OCV readings — [TI E2E forum](https://e2echina.ti.com/support/power-management/f/power-management-forum/118504/bq40z50-qmax) (forum, not official)
- TI bq40z50 GaugeStatus3 returns per-cell QMax, DOD0 saved for the next QMax update, passed charge since last save, and time since last save; DOD0 valid only when VOK = 1 — [TI SLUUCH2 TRM](https://www.ti.com/document-viewer/lit/html/SLUUCH2/GUID-A0069FA6-57AB-4B26-A31A-F74DCFF7B23B)
- TI gauges define "QMax Imbalance" and "Impedance Imbalance" permanent-fail conditions (cell-to-cell mismatch) — [TI SLUUCH2 TRM TOC](https://www.ti.com/document-viewer/lit/html/SLUUCH2/GUID-A0069FA6-57AB-4B26-A31A-F74DCFF7B23B)
- Stuck gauge calibration on macOS 27 was linked by reporters to Qmax and DOD0 values never updating — [AlDente issue #1842](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1842)
- ioreg output repeats keys and order can vary, so parse as a plist (`ioreg -a`) rather than grep — [Apple Community thread 255613997](https://discussions.apple.com/thread/255613997)

### Inferences
- Dashboard-ready derived metrics:
  - Health (raw) = NominalChargeCapacity / DesignCapacity; Qmax health = mean(Qmax) / DesignCapacity; show Apple "Maximum Capacity" separately.
  - Cell balance = max(Qmax) − min(Qmax); user's ~11 mAh spread (~0.2 %) is healthy. A growing spread (several %) is an early warning (TI "QMax imbalance" is a permanent-fail condition).
  - Internal resistance trend = WeightedRa (and per-cell Ra tables); resistance growth precedes capacity "knee" and causes voltage sag and shutdowns under load. Trend relative to the first reading, not absolute.
  - Usage window = DailyMinSoc/DailyMaxSoc; long runs of DailyMaxSoc = 100 with DailyMinSoc ≥ 95 indicate "parked at full" (worst calendar case).
  - CycleCount pace = cycles per month and projected date to 1000 cycles.
  - PermanentFailureStatus ≠ 0 → urgent "service battery" alert.
  - Power: PowerTelemetryData SystemLoad (mW) and SystemPowerIn give real-time draw and charger input; ChargerData NotChargingReason/SlowChargingReason/TimeChargingThermallyLimited explain holds and thermal throttling of charging. Non-zero TimeChargingThermallyLimited growth is a direct heat signal.
- NotChargingReason is a bitfield; zero normally means "charging/not restricted". Talon should log raw values together with the active state (Charge Limit hold, optimised hold, full, thermal) and learn the mapping empirically on the user's machine.

### Gaps
- No public documentation found for NotChargingReason or SlowChargingReason bit meanings, DailyMinSoc/DailyMaxSoc reset timing, WeightedRa units, or PermanentFailureStatus codes. These are inferences; mark them as such in Talon and validate empirically.
- Where battery temperature lives on macOS 27 (top-level Temperature reads 0) was not resolved; candidates are BatteryData fields or SMC temperature keys.

## 7. Recommended thresholds and alerts for a health app

### Takeaway
Base alerts on Apple's stated ranges (10–35 °C ambient, 80 % at 1000 cycles, 50 % storage) and ageing science (time at 100 %, heat >30–35 °C). Recommended defaults below are Talon design proposals derived from these sources, not vendor-published thresholds.

### Cited Findings
- Ambient operating 10–35 °C; >35 °C ambient can permanently damage capacity; store at ~50 %, recharge to 50 % every 6 months — [Apple: Maximizing Battery Life and Lifespan](https://www.apple.com/za/batteries/maximizing-performance/)
- Rated 80 % capacity at 1000 cycles; replace at max cycle count — [Apple Support 102888](https://support.apple.com/en-us/102888)
- >30 °C = elevated; full charge at elevated temperature is worst case; >4.10 V/cell = high voltage — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- 1-year loss at 25 °C: 4 % at 40 % SoC vs 20 % at 100 % SoC; at 40 °C: 15 % vs 35 % — [BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries)
- Charge Limit pauses within a few % of the limit and resumes after a >5 % drop; occasional 100 % calibration is by design — [Apple Support 102338](https://support.apple.com/en-us/102338)

### Inferences (proposed Talon rules)
- "Parked at full": plugged in with SoC ≥ 95 % for > 24 h (warn) or > 72 h (strong nudge) while no Charge Limit is set → recommend Charge Limit 80 %. Suppress for a single calibration top-up.
- "Limit not respected": Charge Limit set but SoC ≥ limit + 5 % for > 24 h → possible stuck gauging mitigation (macOS 27 reports); suggest letting it complete a full cycle, then report.
- Heat: battery temperature > 35 °C while charging (warn), > 40 °C (alert, suggest unplugging/charging later); any increase in TimeChargingThermallyLimited → "charging was slowed by heat". Ambient guidance 10–35 °C.
- Health milestones: Apple Maximum Capacity < 80 % or Condition ≠ Normal → service; raw health falling faster than ~2 % per 100 cycles after the first ~150 cycles → "ageing faster than spec" (account for early √t calendar fade).
- Cycle pace: projected 1000 cycles date; > ~1 cycle/day sustained = heavy use.
- Cell imbalance: Qmax spread > ~2–3 % of DesignCapacity → watch; PermanentFailureStatus ≠ 0 → urgent.
- Storage mode: if no charging/usage detected for > 7 days, suggest ~50 % storage SoC.
- Avoid nagging about deep discharges or "calibration" rituals: Apple's system handles gauge calibration, and BU shows partial cycles are gentler, so simply avoid routinely running to 0 %.

### Gaps
- No Apple-published battery-temperature thresholds while charging (only ambient). The 35/40 °C battery-temperature alert levels are proposals.
- No data on how much macOS 26.4 Charge Limit at 80 % extends real MacBook pack life; benefit size must be extrapolated from lab cell data.
