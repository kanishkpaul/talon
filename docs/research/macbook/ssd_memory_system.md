# SSD endurance, unified memory, swap and macOS system health on the M5 MacBook Air

Researcher notes, 2026-11-08. Machine context from the brief: MacBook Air Mac17,3 (M5), 16 GB, 512 GB "APPLE SSD AP0512Z", macOS 27.0.1. SMART: Percentage Used 0 %, Available Spare 100 % (threshold 99 %), Data Units Written 12.08 TB, Read 32.94 TB, Power-On Hours 266, Power Cycles 129, Unsafe Shutdowns 20, Media Errors 0. Free 231 GB. Swap ~0.9 of 2 GB.

Sourcing note: Howard Oakley (Eclectic Light Company) is the best single source here. Many endurance numbers come from his estimates or from reader comments on his posts, and these are labelled as such. Apple publishes no SSD endurance figures. No M5 Air teardown was found.

## Apple internal SSD endurance: TBW, Percentage Used, the M1 wear scare, and replaceability

### Takeaway
Apple publishes no TBW figure. Oakley and real SMART readings put Apple SSDs at roughly 3,000 to 6,000+ full-drive write cycles, so a 512 GB drive probably lasts well beyond 1,000 TB written. "Percentage Used" is a vendor-defined estimate that rises slowly and is coarse. On the M5 Air the SSD is reported (not yet teardown-confirmed) as soldered to the logic board, so SSD death means a logic-board replacement.

### Cited Findings
- Apple does not publish TBW/endurance figures for its internal SSDs. — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/); [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Oakley's conservative estimate (2026) is about 3,000 erase-write cycles for Apple SSDs, and he expects Apple's to do better, "probably 6,000 or more". Total endurance scales with capacity: 1 TB × 3,000 cycles ≈ 3,000 TB written. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- His earlier, more cautious 2022 framing put typical good SSDs at about 150 TBW (250 GB), 300 TBW (500 GB) and 600 TBW (1 TB). He cited suggestions that a 1 TB Apple SSD manages 600–1,200 TBW and called that range highly uncertain. — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)
- Real-world SMART readings reported in comments on Oakley's 2026 post:
  - MacBook Air M1: 10 % used after 136 TB written, implying about 1,360 TB total.
  - Mac Studio: 2 % used after 267 TB.
  - iMac Pro: 3 % used after 220 TB.
  - A cited dosdude1 Mac mini M1 endurance test wrote 4,500 TB and the drive kept working. This was relayed second-hand by a commenter and is not verified here.
  — [Eclectic Light comments, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Forum data point: a 500 GB M1 Mac showed 171 TB written after 3 years with Percentage Used at 5 %. A widely shared 2021 community estimate put M1 endurance at about 2,000 TB for 256 GB and about 5,000 TB for 2 TB. These are community extrapolations, not Apple figures. — summarised via [Apple Community thread](https://discussions.apple.com/thread/252532855); [MacRumors thread](https://forums.macrumors.com/threads/ssd-swap-high-usage-of-terabytes-written.2284893/page-142)
- How Percentage Used works:
  - Oakley says it is derived from data written, capacity and expected cycles, so it is essentially the same information as bytes written.
  - The cycle figure is a manufacturer estimate from sample testing that varies by batch.
  - He calls relying on it "a gamble".
  — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Percentage Used is an integer, so 1 % can mean 1–2 % used. One user saw the value sit at 0–1 % for a long time and then climb to 15 % within a few months, which suggests the reading may not rise linearly. These are anecdotes. — [MacRumors thread (via search summary)](https://forums.macrumors.com/threads/ssd-swap-high-usage-of-terabytes-written.2284893/page-142)
- Units: NVMe Data Units Written is counted in thousands of 512-byte units, rounded up, so 1 unit = 512,000 bytes. Example: 100,000,000 units ≈ 51.2 TB. Oakley notes it is unclear whether the total includes wear-levelling overhead. — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)
- SMART counters stay with the SSD. A DFU restore does not reset TBW; only replacing the logic board (which contains the SSD) changes them. — [Eclectic Light, Feb 2026 (author reply)](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Oakley does not recommend relying on SMART health indicators as early warnings for SSDs. They are poor predictors, and an SSD's health is hard to act on when replacement means a new logic board. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Failure pattern:
  - SSD failures follow a U-shaped "bathtub" curve: early failures in the first weeks, wear-out at end of life.
  - Random electronic failure can happen before the cycle limit.
  - Clean power and moderate temperatures help.
  - Oakley expects SSDs to either fail around age 10 or carry on for another decade.
  — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- The 2021 M1 wear controversy:
  - In Feb 2021, M1 users posted smartctl readings showing very high TB written. AppleInsider said these were "based on incomplete data".
  - Hector Martin (Asahi Linux), who had flagged the issue, said macOS 11.4 resolved it.
  - An AppleInsider source called it a "data reporting error within the tools used to report SSD wear" rather than excessive writes. Apple never confirmed this publicly.
  - Some users reported 11.4 only halved their write rate. One posted an average of about 35 GB/day on 11.4.
  - Oakley attributes the rapid wear on early 8 GB M1s to heavy use, small SSDs, and a kernel swap bug (per a commenter) that was later fixed.
  — [AppleInsider, June 2021](https://appleinsider.com/articles/21/06/04/apple-resolves-m1-mac-ssd-storage-longevity-issue-in-macos-114-beta); [Tom's Hardware](https://tomshardware.com/news/apple-fixes-ssd-wear-out-reporting-issues); [HotHardware](https://hothardware.com/news/apple-fixes-ssd-wear-in-m1-macs); [Apple Community](https://discussions.apple.com/thread/252982868?page=3); [Eclectic Light, 2022](https://eclecticlight.co/2022/11/29/how-much-unified-memory-does-your-apple-silicon-mac-need/)
- M5 MacBook Air hardware:
  - Released March 11, 2026.
  - Base storage 512 GB, configurable up to 4 TB. Base memory 16 GB.
  - Apple claims SSD read/write speeds are doubled.
  - Early assessments say RAM and SSD are soldered and not replaceable, so a fault often means a logic-board replacement. BornCity presents this as unconfirmed pending teardown.
  — [BornCity](https://borncity.com/news/apple-macbook-air-m5-mehr-leistung-alte-reparaturprobleme/); [T3](https://www.t3.com/tech/laptops/macbook-air-gets-an-upgrade-to-m5-making-the-worlds-most-popular-laptop-even-faster)
- Notebookcheck benchmarks, as reported by TechNews:
  - The 13" M5 Air SSD writes up to about 230 % faster than the M4 Air.
  - It beats a 16" M4 Pro MBP by up to about 20 % in a 5 GB Blackmagic test.
  - It is probably PCIe Gen 4, with a suspected dual-NAND layout.
  — [TechNews.tw, Mar 2026](https://technews.tw/2026/03/09/m5-macbook-air-ssd/)
- iFixit gave the M5 MacBook Pro 4/10 for repairability, the same as its predecessor. — [Apfelpatient](https://www.apfelpatient.de/en/news/m5-macbook-pro-in-teardown-performance-top-repair-flop)
- Back to 2020: iFixit's 2020 MacBook Air teardown found the SSD and RAM soldered. — [iPhone in Canada](https://www.iphoneincanada.ca/mac/ifixit-macbook-air-2020-teardown)

### Inferences
- This machine's 12.08 TB written is about 23.6 full writes of the 512 GB drive. Endurance estimates for a 512 GB drive:
  - Oakley's 3,000-cycle floor gives about 1,500 TBW, so 12 TB is about 0.8 %. That fits SMART's integer "0 %".
  - The extrapolated M1 Air figure (about 1,360 TB) gives the same picture.
  - Even the most conservative 2022 number (300 TBW for a 500 GB drive) puts it at 4 %.
- Talon should show "estimated life used" as a range, e.g. 12 TB ÷ (300–1,500 TB) = 0.8–4 %, and label the SMART Percentage Used as the drive's own estimate. Projected years remaining = remaining TBW ÷ trailing write rate. A single precise number would mislead.
- Available Spare (100 % vs 99 % threshold) and Media Errors (0) are the real red-flag fields:
  - Alert if Media Errors rises above 0.
  - Alert if Available Spare starts falling.
  - Alert if the NVMe Critical Warning field becomes non-zero.
  - Percentage Used should be an informational trend, not an alarm.
- Because the SSD is soldered, Talon should present SSD wear advice as protecting the logic board and emphasise backups, without alarmism.

### Gaps
- No iFixit or other teardown of the M5 MacBook Air was found, so "soldered SSD" rests on early reports and Apple's design history. There is no M5-Air-specific confirmation.
- No Apple-published or M5-specific endurance data. All TBW numbers are estimates or extrapolations from older Apple SSDs (M1/T2 era).
- No Hector Martin primary source (tweet or Asahi doc) was fetched. His role is reported second-hand via Tom's Hardware and HotHardware.
- No Asahi documentation on Apple's ANS NVMe controller and how it computes SMART fields was reviewed.

## Is 12 TB written normal? Typical daily write rates and main write sources

### Takeaway
Yes. Reported macOS write rates of about 30–60 GB/day on ordinary Macs are common. 12.08 TB on an M5 Air that is at most about 8 months old works out to roughly 50 GB/day or more. That is within the normal range but on the busier side, and swap, Spotlight, caches and app or model downloads are the usual causes.

### Cited Findings
- Oakley's 1 TB iMac Pro wrote about 150 TB over 2,500+ days: about 21 TB/year, just under 60 GB/day. An earlier reading was about 120 TB in four years (about 30 TB/year). — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/); [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)
- A commenter sees about 30 GB/day on two lightly loaded Macs with near-zero swap. Oakley suggests Spotlight indexing, QuickLook caching, Finder and network-related cache churn as likely causes. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- The Unified log writes only about 250–500 MB/day even on a Mac awake 24/7, under 1 % of Oakley's daily load. Logging is not a meaningful wear source. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Oakley calls swap on the VM volume "the worst enemy" of SSD life for most users. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Extreme case: a database workload wrote about 60 GB/hour, about 159 TB in 3 months (commenter). — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Other reported rates (commenters on Oakley's 2022 memory post): about 15 GB/day over three weeks, about 18 TB/year for a heavy user, and about 30 GB/day averaged across several users. — [Eclectic Light, 2022](https://eclecticlight.co/2022/11/29/how-much-unified-memory-does-your-apple-silicon-mac-need/)
- On a 500 GB drive with 300 TBW, an extra 10 GB/day of swap would shorten its life by over a year. — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)
- The M5 Air went on sale March 11, 2026. — [BornCity](https://borncity.com/news/apple-macbook-air-m5-mehr-leistung-alte-reparaturprobleme/)
- Daily average write rate can be computed as Data Units Written ÷ days since purchase (commenter method). — [Eclectic Light, 2022](https://eclecticlight.co/2022/11/29/how-much-unified-memory-does-your-apple-silicon-mac-need/)

### Inferences
- Maximum possible age is about 242 days (11 Mar to 8 Nov 2026), so 12.08 TB means at least about 50 GB/day, or more if bought later. That matches Oakley's own about 60 GB/day.
- At about 18 TB/year, even a pessimistic 300 TBW lasts about 16 years, and Oakley-style 1,500 TBW lasts about 80 years. Wear is not a practical concern at this rate. Talon should say so plainly.
- Reads (32.94 TB) cause negligible wear. Talon should not alarm on reads.
- Likely write sources for this user (unverified for this machine):
  - Swap under a Safari + ChatGPT + Claude workload.
  - Safari and Electron caches.
  - Spotlight after OS updates (macOS 27.0.1 is new).
  - LLM-app and Claude Code caches and downloads.
  - Time Machine local snapshots.
  Talon should attribute writes per process, not guess.
- Recommended Talon metric: trailing 7- and 30-day write rate from SMART deltas, sampled daily. Thresholds:
  - Normal: under about 50 GB/day.
  - Elevated: about 50–150 GB/day.
  - Investigate: sustained above 150 GB/day.
  These thresholds are a judgement extrapolated from the reported ranges, not a published standard.

### Gaps
- No systematic dataset of macOS daily write rates. All figures are personal or anecdotal.
- No quantified sources found for Photos analysis, Time Machine local snapshots, Xcode DerivedData, Docker or LLM model downloads specifically. These are plausible but unmeasured here.
- Actual purchase date unknown, so the true daily rate cannot be pinned down.

## Why Power-On Hours under-reports, and what Unsafe Shutdowns means on Macs

### Takeaway
Apple SSD Power-On Hours appear to grossly under-count: many reports show a few hours across many power cycles. This is probably because the controller spends most time in low-power states that do not accrue hours, but there is no authoritative explanation. Talon should not use it for age or rate calculations. In NVMe terms, Unsafe Shutdowns counts power loss without a shutdown notification: crashes, forced power-offs, battery-dead events. A count of 20 in 129 cycles is moderate and only worth correlating with panics.

### Cited Findings
- A brand-new Mac showed about 130 power cycles but only about 3 power-on hours. — [MacRumors](https://forums.macrumors.com/threads/brand-new-mac-from-apple-showing-130-power-cycles-but-only-3-power-on-hours-should-i-be-worried.2445626)
- A user comment calls Apple SSD Power On Hours "not trustworthy, seems too small" while write totals are credible. — [V2EX](https://v2ex.com/t/782525)
- An M1 AP0512 reading showed Power On Hours 109, Unsafe Shutdowns 70, no media errors. — [dalvikplanet blog, 2022](https://dalvikplanet.blogspot.com/2022/11/imac-24-m1-benchmarks-and-ssd-wear.html?m=1)
- One commenter believes each SSD sleep/wake counts as a power cycle. This is a user guess. — [MacRumors](https://forums.macrumors.com/threads/high-ssd-power-cycles-on-a-brand-new-m1-air-normal.2286581)
- NVMe Unsafe Shutdowns counts power lost without a prior shutdown notification from the host:
  - Clean reboots increment Power Cycles only.
  - Power cuts, kernel panics and holding the power button increment Unsafe Shutdowns.
  - Some drives' firmware increments it even on clean boots or power-save transitions. If it rises exactly once per boot with only clean boots, suspect firmware.
  — [Netdata guide](https://www.netdata.cloud/guides/smartctl-disk-monitoring/smartctl-unsafe-shutdowns/); [Netdata NVMe guide](https://www.netdata.cloud/guides/nvme/nvme-unsafe-shutdowns-increasing/); [Framework forum](https://community.frame.work/t/smartctl-shows-excessive-power-cycles-and-unsafe-shutdowns/70954/)
- Reported Apple values vary widely:
  - A Mac Studio showed 710 power-on hours and 23 unsafe shutdowns. Oakley said 23 "seems like a large number".
  - An iMac Pro showed 237 unsafe shutdowns, mostly tied to GPU freezes.
  - Another Mac Studio reportedly showed 109.
  — [Eclectic Light comments, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/); search summary of [MacRumors](https://forums.macrumors.com/threads/imac-ssd-errors-anything-to-be-concerned-about.2357902)

### Inferences
- 266 POH against 129 power cycles and about 8 months of real use is consistent with the widely reported Apple under-count. Talon should hide POH or mark it "not meaningful on Apple SSDs" and use the purchase date or the oldest log/install date for age.
- 20 unsafe shutdowns out of 129 cycles (about 16 %) is plausibly made up of:
  - kernel panics or watchdog resets,
  - force-restarts (holding the power key),
  - battery fully drained,
  - early setup and migration restarts,
  - firmware quirks around deep sleep.
  Talon should track the delta of this counter and cross-reference *.panic reports and "previous shutdown cause" in logs. A rising counter with matching panics is worth surfacing. A static count is not.
- APFS is copy-on-write, so occasional unsafe shutdowns are rarely harmful to the file system. This is general knowledge and was not specifically sourced here.

### Gaps
- No Apple or Asahi source explains why the Apple controller under-reports POH, or exactly which events increment Unsafe Shutdowns on Apple silicon (e.g. whether hibernation or deep sleep counts).
- No source mapped macOS "previous shutdown cause" codes to the SMART counter.

## macOS memory management on Apple Silicon: compression, swap, pressure, and 16 GB under heavy apps

### Takeaway
macOS fills RAM with cache, then compresses memory, then swaps to `/System/Volumes/VM/swapfile*`. Memory pressure, not "memory used", is the health signal. Occasional 1–2 GB of swap is fine; regular 4 GB+ is a concern. Wear impact is best judged as swap bytes written (`vm_stat` swapouts × 16 KB page) versus total SSD writes.

### Cited Findings
- XNU source defines the macOS swap file path as `/System/Volumes/VM/swapfile` (numbered files). — [XNU vm_compressor_backing_store.h](https://opensource.apple.com/source/xnu/xnu-7195.81.3/osfmk/vm/vm_compressor_backing_store.h.auto.html)
- Swap lives in a hidden APFS "VM" volume and the files grow and shrink as needed:
  - On recent macOS, swap files are about 1 GB each and may persist after use (commenter).
  - The VM volume should be under 1 MB when swap is unused.
  - Activity Monitor's "Swap Used" should read 0 when swap isn't in use.
  — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/); [Eclectic Light, 2022](https://eclecticlight.co/2022/12/02/tracking-swap-space-is-it-wearing-out-your-ssd/)
- Oakley's thresholds:
  - Occasional 1–2 GB of swap is not worrying; regular use of 4 GB or more is.
  - `sysctl vm.swapusage` gives a quick check and is more reliable than Finder sizes.
  — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Measuring swap writes with `vm_stat`:
  - `vm_stat` totals run since boot. `vm_stat -c 1 1` gives a compact line ending in swapins/swapouts.
  - The man-page definitions of swapins and swapouts are reversed. Oakley says to treat swapouts (usually the larger number) as writes to disk.
  - Values are in pages: 16,384 bytes on Apple silicon, 4,096 on Intel (check with `pagesize`).
  — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/02/tracking-swap-space-is-it-wearing-out-your-ssd/); man-page inconsistency also noted at [vm_stat man page](https://keith.github.io/xcode-man-pages/vm_stat.1.html) and [Apple system_cmds vm_stat.c](https://git.saurik.com/apple/system_cmds.git/blob/HEAD:/vm_stat.tproj/vm_stat.c)
- Rule of thumb for swap's share of total writes:
  - Under 10 % of total SSD writes: swap contributes little to wear.
  - 50 % or more: more RAM would significantly reduce wear.
  - Extreme swap could wear an SSD out in under 5 years against a typical life of about 10.
  — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/02/tracking-swap-space-is-it-wearing-out-your-ssd/)
- Oakley's 2022 memory measurements:
  - Apple silicon's fast SSD means swap often goes unnoticed, but heavy swap shortens SSD life.
  - Base system use was about 6 GB.
  - Safari with 12 tabs added about 2–2.5 GB.
  - WindowServer uses about 0.5–1 GB, rising above 1 GB with dozens of windows, at about 25 MB per Safari window on Ventura.
  - The GPU shares unified memory.
  — [Eclectic Light, 2022](https://eclecticlight.co/2022/11/29/how-much-unified-memory-does-your-apple-silicon-mac-need/)
- Oakley recommends keeping at least 60 GB free on the internal SSD, ideally 80–100 GB, which supports swap and VM. — [Eclectic Light, 2022 (author reply)](https://eclecticlight.co/2022/11/29/how-much-unified-memory-does-your-apple-silicon-mac-need/)
- Memory Pressure (Activity Monitor) combines free memory, swap rate, wired memory and file-cached memory. Swap usage alone does not signal a problem; persistent high pressure plus visible slowdown does. Concern is warranted when compressed memory keeps growing under a stable workload and swapouts keep increasing. — [chrischodev guide](https://blog.chrischodev.com/macos-memory-pressure-guide/) (secondary, non-Apple)
- Programmatic memory pressure:
  - Chromium and Firefox read the undocumented sysctl `kern.memorystatus_vm_pressure_level`. Mozilla notes 4 = critical; other values were not confirmed in sources found.
  - Apple's supported route is a dispatch memory-pressure source (normal/warn/critical events).
  — [Chromium memory_pressure_monitor_mac.cc](https://chromium.googlesource.com/chromium/src.git/+/88962c06dc856db08d386c29a6f254a2cc8b5e37/base/memory/memory_pressure_monitor_mac.cc); [Mozilla AvailableMemoryWatcherMac.cpp](https://searchfox.org/mozilla-central/source/xpcom/base/AvailableMemoryWatcherMac.cpp)

### Inferences
- This user's ~0.9 GB of swap sits within Oakley's "not worrying" band. Talon should report it as normal unless swapouts grow quickly day to day.
- The workload (Safari 4.3 GB + ChatGPT 2.9 GB + Claude ~3 GB + Numbers/Preview + about 6 GB system/WindowServer) is near or over 16 GB, so periodic compression and modest swap are expected. Electron/WebView apps (ChatGPT, Claude desktop) each carry their own browser engine overhead.
- Talon should show:
  1. Memory pressure level (dispatch source; sysctl as fallback).
  2. Compressed memory (`host_statistics64` `compressor_page_count` × 16 KB).
  3. Swap used (`vm.swapusage`).
  4. Swapouts per hour and per day as bytes (delta of `vm_statistics64.swapouts` × 16,384).
  5. Swap bytes as a share of SSD bytes written that day.
  Advice should trigger on sustained warn/critical pressure or swap above 4 GB, or swap above about 25–50 % of daily writes. Swap merely being present should not trigger advice.
- Useful advice for this user: close idle Safari tabs or windows, quit unused Electron/LLM apps. Avoid generic "RAM cleaner" advice: purging cache is counter-productive (secondary sources agree, not deeply sourced here).

### Gaps
- No Apple primary documentation found on Apple silicon hardware memory compression, or on how `dynamic_pager` sizes swap files on macOS 26/27.
- No measured data on 16 GB M5 behaviour with Electron/LLM apps specifically.
- The numeric mapping of `kern.memorystatus_vm_pressure_level` values 1 and 2 is unverified.

## Attributing disk writes to processes

### Takeaway
`proc_pid_rusage` (`RUSAGE_INFO_V4`, field `ri_diskio_byteswritten`) gives per-process cumulative bytes written and is the best low-overhead source. It misses swap (kernel), counts writes against the daemon rather than the requesting app, and resets when a process exits. Use SMART deltas for ground truth and `iostat` for device-level rates.

### Cited Findings
- `proc_pid_rusage(pid, flavor, buffer)` with `RUSAGE_INFO_V2` through `V4` exposes `ri_diskio_byteswritten` (u64, total bytes written to disk; present since v2). `RUSAGE_INFO_CURRENT` maps to V4. V3+ adds `ri_logical_writes`, which counts logical writes that may be coalesced or buffered. Note the spelling: `byteswritten` with no underscore. — [docs.rs mac-process](https://docs.rs/crate/mac-process/latest/source/src/libproc/pid_rusage.rs); [rusage_info_v4 bindings](https://docs.alumina-lang.net/libc/x86_64_apple_darwin/rusage_info_v4.html); [rusage_info_v2 aarch64](https://docs.alumina-lang.net/libc/aarch64_apple_darwin/rusage_info_v2.html)
- Whether these counters are physical or logical writes is not authoritatively documented by Apple. A 2010 darwin-kernel thread notes the Linux equivalent reflects bytes the task "caused to be written". — [darwin-kernel list, 2010](https://lists.apple.com/archives/darwin-kernel/2010/Feb/msg00014.html)
- `iostat` reports only what the kernel writes, which may differ from what the disk physically writes (write amplification, wear levelling). — [Eclectic Light, 2022 (author reply)](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)

### Inferences
- Pitfalls:
  - Swap writes are kernel activity (kernel_task / the compressor), not charged to the app that caused memory pressure. Measure swap separately via `vm_stat`.
  - Spotlight writes appear under mds/mds_stores/mdworker, Time Machine under backupd, iCloud under bird/cloudd, Photos analysis under photoanalysisd. Talon should map these daemons to plain-language categories.
  - The counters reset when a process exits, so Talon must sample periodically (e.g. every 1–5 min) and accumulate per bundle ID.
  - Reading other users' or root processes may need privileges.
  - `fs_usage` gives live attribution but needs root and is heavy. Use it only for an on-demand "what is writing right now" mode.
  These points are design inferences, not cited.
- Reconcile the sum of per-process bytes plus swap bytes against SMART Data Units Written deltas. The difference is filesystem metadata, write amplification and unattributed daemons.

### Gaps
- No source found documenting how `ri_diskio_byteswritten` treats mmap writes, APFS clones, or writes issued by XPC services on behalf of apps.
- `fs_usage` and `iostat` usage specifics on macOS 27 were not verified.

## Free-space recommendations for APFS SSDs

### Takeaway
Keep at least 10 %, ideally 15–25 %, of the SSD free. For a 512 GB Mac that is about 60–100 GB minimum. This helps wear levelling, performance, swap, updates and snapshots. "Purgeable" figures are estimates. This user's 231 GB free (about 45 %) is very healthy.

### Cited Findings
- Oakley (2026): keep at least 10 % free, aim for 15 % or more; the article summary suggests 15–25 %. Free space aids wear levelling, keeps performance up, and leaves room for large snapshots. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- Oakley (2022): at least 60 GB free, ideally 80–100 GB, so 512 GB is the practical minimum SSD size. — [Eclectic Light, 2022](https://eclecticlight.co/2022/11/29/how-much-unified-memory-does-your-apple-silicon-mac-need/)
- Wear levelling is most efficient with ample free space. Moving static data adds program/erase cycles, most noticeably when free space is low and write rates are high. — [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)
- How APFS free space works:
  - Volumes share their container's free space. Container free space is container capacity minus space used by volumes, and `diskutil apfs list` reports it.
  - Finder and Disk Utility figures for used space can differ (e.g. 826.67 vs 814.03 GB).
  - Purgeable space (e.g. web caches) is an estimate macOS frees on demand.
  - Container free space is "generally reliable".
  - Illustrated on a 2 TB Apple silicon SSD running macOS 26.6.2.
  — [Eclectic Light, Aug 2026](https://eclecticlight.co/2026/08/21/the-arithmetic-of-free-space/)
- Snapshots count as purgeable. Time Machine purges its own local snapshots after 24 hours. Purgeable accounting has been "inconsistent and often misleading" since APFS. — [Eclectic Light tag/free-space search summary](https://eclecticlight.co/2026/08/24/arent-snapshots-purgeable/); [Eclectic Light, 2023](https://eclecticlight.co/2023/04/19/ventura-space-management-what-gets-purged-and-how/)
- Trim:
  - macOS 27 changed the log entries that confirm an SSD is trimmed at mount.
  - Oakley published a method to verify Trim (Sep 2026).
  - Trim frees unused pages and keeps write speed up.
  — [Eclectic Light, Sep 2026](https://eclecticlight.co/2026/09/23/checking-an-ssds-trims-in-golden-gate/); [Eclectic Light, Nov 2025](https://eclecticlight.co/2025/11/13/does-that-ssd-trim-and-why-is-it-important/)

### Inferences
- Talon should read container free space (via `diskutil apfs list`, or `volumeAvailableCapacityForImportantUsage` / `statfs` on the Data volume). Thresholds for a 512 GB disk:
  - Green: above 25 %.
  - Amber: 10–15 % (about 50–75 GB).
  - Red: below 10 % or below about 50 GB.
- Show purgeable separately with an "estimate" label.
- Major macOS updates need tens of GB free. This is general knowledge; no specific figure was sourced here.

### Gaps
- No Apple official free-space recommendation found.
- The contents of the Aug 2026 "Aren't snapshots purgeable?" post were not fetched in full.

## Other system-health signals: panics, crashes, uptime, backups, updates, security, background items, Spotlight

### Takeaway
Research coverage here was thin within the call budget. Most of what follows is standard macOS knowledge, flagged as unverified for macOS 27. The most actionable signals are kernel panic frequency, Time Machine last-backup age, pending updates, FileVault/SIP state, and background-item creep.

### Cited Findings
- Oakley recommends regular backups specifically because Apple SSD or logic-board failure is unrecoverable without them. — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/)
- macOS 27 ("Golden Gate" per Oakley's title) changed unified log entries for Trim. This is a reminder that log-based checks must be re-validated on 27. — [Eclectic Light, Sep 2026](https://eclecticlight.co/2026/09/23/checking-an-ssds-trims-in-golden-gate/)
- Oakley's Mints utility reads SMART data for internal SSDs on Apple silicon without a driver. DriveDx and smartctl also report Percentage Used and Data Units Written on Apple silicon. Disk Utility's SMART status is "not very helpful". — [Eclectic Light, Feb 2026](https://eclecticlight.co/2026/02/26/how-long-will-my-macs-ssd-last/); [Eclectic Light, 2022](https://eclecticlight.co/2022/12/05/how-to-estimate-an-ssds-working-life/)

### Inferences
These are standard macOS mechanisms, not verified against sources in this session. Talon should re-check them on macOS 27.
- **Kernel panics:** `/Library/Logs/DiagnosticReports/*.panic` (Apple silicon panics are often named `panic-full-*.panic`). Watchdog or "Kernel" reports are also there.
  - 0 in 30 days: normal.
  - 1 isolated: note it.
  - Repeated: surface it, and correlate with Unsafe Shutdowns deltas.
- **App crashes:** `~/Library/Logs/DiagnosticReports/*.ips`. Count per app per week. Repeat crashers are actionable.
- **Uptime:** `sysctl kern.boottime`. Long uptimes (weeks) are fine on macOS; suggest a restart only alongside a leak or high pressure.
- **Time Machine:** `tmutil latestbackup` / `tmutil destinationinfo`. Local snapshots via `tmutil listlocalsnapshots /`.
  - Warn if the last backup is more than 7 days old.
  - Warn strongly if no backup is configured, since a soldered SSD makes this critical.
- **Updates:** `softwareupdate --list` (can be slow and needs network). The installed version comes from `sw_vers`.
- **Security:**
  - FileVault: `fdesetup status`.
  - SIP: `csrutil status`.
  - Gatekeeper: `spctl --status`.
  - Firewall: `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`.
- **Login/background items:** `sfltool dumpbtm` (needs admin) lists Background Task Management items. Also System Settings > General > Login Items & Extensions. Track the count over time to spot creep.
- **Spotlight:** `mdutil -s /` for indexing state. Heavy `mds_stores` writes after OS updates are expected and transient.

### Gaps
- Did not verify DiagnosticReports paths and naming, `sfltool dumpbtm` output format, or `tmutil` behaviour specifically on macOS 26/27. No Apple support doc for these was fetched within the tool budget.
- No sourced thresholds for "concerning" panic or crash frequency.
