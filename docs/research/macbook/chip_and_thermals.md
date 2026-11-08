# MacBook Air M5 (Mac17,3): chip, thermal design and throttling, for the Talon monitoring app

Context from the coordinator (measured on the user's machine, not from web sources): Mac17,3, Apple M5, 4 Super + 6 Efficiency cores, 16 GB, APPLE SSD AP0512Z (512 GB), macOS 27.0.1, fanless. IOReport DVFS tables: E-cluster max 3048 MHz (8 steps), Super/P-cluster max 4464 MHz (19 steps), GPU max 1578 MHz. HID exposes about 39 temperature sensors ("PMU tdie1–14", "PMU tdev2–8", "PMU2 …", "PMU tcal", "NAND CH0 temp", "gas gauge battery"). A 6-second all-core load took the die from 38 to 50 °C with clocks pinned at max.

## 1. M5 chip specs, M5 MacBook Air launch and configurations, differences from the M4 Air

### Takeaway
The M5 is a third-generation 3 nm SoC: up to 10 CPU cores (4 "super" + 6 efficiency), up to 10 GPU cores with a Neural Accelerator in each, a 16-core Neural Engine, and 153 GB/s memory bandwidth. The MacBook Air M5 (13-inch = Mac17,3, A3449) was announced 3 March 2026 and shipped 11 March 2026. It starts at 16 GB / 512 GB for $1,099. Compared with the M4 Air it has roughly 15–18% more CPU performance, about 30–40% more GPU performance, an SSD about 2x faster, and an N1 Wi-Fi 7 chip.

### Cited Findings
**Chip (Apple's M5 announcement, Oct 2025)**
- Process: "3nm, third generation." CPU: up to 10 cores, up to 4 performance (now called "super") and 6 efficiency. GPU: 10 cores, one Neural Accelerator per GPU core. Neural Engine: 16 cores. Memory bandwidth: 153 GB/s, "nearly 30% higher than M4." Apple did not state the transistor count. — [Apple Newsroom](https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/)
- Apple's claims against the M4: over 4x GPU AI compute, up to 15% faster multithreaded CPU, up to 30% faster graphics (45% with ray tracing). Other features: second-generation Dynamic Caching and a third-generation ray-tracing engine. — [Apple Newsroom](https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/)

**The "Super" core naming**
- In March 2026, alongside the M5 Pro and M5 Max, Apple renamed its old "performance" cores to "super" cores. It applied the new name retroactively to all M5 chips and reused "performance" for a new mid-tier core in the M5 Pro and Max. The base M5 has super cores plus efficiency cores, and no "performance" cores. — [9to5Mac](https://9to5mac.com/2026/03/20/apple-explains-why-m5-chips-have-three-different-core-types-in-new-interview/); [Six Colors](https://sixcolors.com/post/2026/03/apple-gives-in-to-temptation-and-renames-its-cpu-cores/); [Macworld](https://www.macworld.com/article/3077260/what-the-hell-is-an-m5-super-core.html)
- Apple's Anand Shimpi: "The super core is the fastest CPU core in the world. It is optimized for single-core performance." He called the efficiency core "our CPU core with the highest efficiency." — [9to5Mac](https://9to5mac.com/2026/03/20/apple-explains-why-m5-chips-have-three-different-core-types-in-new-interview/)
- A headline in a Harvard TagTeam feed says "macOS Tahoe 26.3.1 update will 'upgrade' your M5's CPU to new 'super' cores," meaning macOS UI and tools show the new name from 26.3.1 on. I saw only the headline and did not read the article. — [TagTeam feed](https://tagteam.harvard.edu/hub_feeds/3382/feed_items/17307549)

**Clocks (Notebookcheck spec table) compared with the user's measurement**
- Notebookcheck lists 4 S-cores at 4.6 GHz and 6 E-cores at 3.0 GHz. — [Notebookcheck MBA13 M5 review](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- On the user's machine, IOReport tops out at 4464 MHz on super cores and 3048 MHz on E cores. Notebookcheck's "4.6 GHz" is a rounded or marketing figure, or a different value; trust the on-device DVFS table.

**Model and launch**
- Mac17,3 = MacBook Air (13-inch, M5), model A3449. The 15-inch is Mac17,4 (A3448). Announced 3 March 2026, on sale 11 March 2026. — [The Apple Wiki](https://theapplewiki.com/wiki/Mac17,3); [Apple "Identify your MacBook Air"](https://support.apple.com/en-ca/HT201862)
- Pre-orders opened 4 March and the machine launched 11 March. Up to 10 GPU cores. 153 GB/s bandwidth, 28% more than the M4. Storage starts at 512 GB and goes to 4 TB, with SSD read/write "about 2x faster" than the previous generation. N1 chip with Wi-Fi 7 and Bluetooth 6. Starts at $1,099, $100 more than the M4 Air. — [MacRumors](https://www.macrumors.com/2026/03/03/apple-announces-macbook-air-with-m5/)
- Every configuration starts at 16 GB, with 24 GB and 32 GB options. The 15-inch starts at $1,299. — [Cult of Mac](https://www.cultofmac.com/news/what-new-m5-macbooks-will-cost-you); storage upgrade pricing: [Daring Fireball](https://daringfireball.net/linked/2026/03/03/new-macbook-air-with-m5)
- The base 13-inch has an 8-core GPU. Notebookcheck's "Entry" 13-inch review unit uses the "Apple M5 8-core" GPU, and Apple says "up to 10." — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- The review unit had 16 GB of LPDDR5x-9600 and a 53.8 Wh battery (13-inch). The 15-inch has a 66.5 Wh battery. — [Notebookcheck 13"](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html); [Notebookcheck 15"](https://www.notebookcheck.net/Apple-MacBook-Air-15-M5-Review-Very-powerful-fanless-and-without-competition.1244905.0.html)
- The SSD is the same part as the user's: "Apple SSD AP0512Z, 512 GB, PCIe 4.0." Blackmagic measured 6473 MB/s read and 6559 MB/s write, against 2833 / 1988 MB/s on the M4 Air's AP0256Z. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)

**Benchmarks against the M4 Air (Notebookcheck 13")**
- Cinebench 2024 Multi: 957 (M5 Air), 815 (M4 Air), 1172 (M5 MBP 14). CB24 Single: 200, 173, 200. Steel Nomad Light: 4405, 3168, 5221. Cinebench 2024 GPU: 5415, 3574, 6139. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)

### Inferences
- In the UI, Talon should label the 4 fast cores "Super cores" (Apple's current term since March 2026) and could add "(performance)" for users who know the older name. IOReport and some tools may still call this the "P-cluster."
- 4464 MHz is the right "max" to use when computing "% of max clock" for super cores, and 3048 MHz for E cores. Read both from the DVFS table rather than hard-coding them.

### Gaps
- I could not retrieve Apple's MacBook Air M5 tech-specs page directly. Sources conflict on Thunderbolt 4 versus Thunderbolt 5 (an aggregator summary claimed TB5; most coverage says TB4) and on the bundled charger (see section 5).
- I found no transistor count or die size for the M5 from a primary source.

## 2. Fanless thermal behaviour: sustained-load throttling, power limits, temperatures, Air vs Pro

### Takeaway
The M5 Air bursts to about 24–28 W of package power for seconds to minutes, then settles to a sustained level. Combined CPU+GPU stress settles at about 8–9 W; CPU-only Cinebench settles at about 13 W after a couple of minutes, and the score drops to about 820 at 9 W after 30 minutes. That loses roughly 14% of multi-core performance after 30 minutes (957 → 820 in CB24), while single-core and short tasks run at full speed. The chassis stays below about 45 °C. The M5 MacBook Pro 14 with a fan sustains roughly 15 W CPU and is about 18% faster in multi-core, and up to about 40% faster in sustained GPU or gaming loads.

### Cited Findings
**Power limits (Notebookcheck spec tables)**
- 13-inch: CPU "24 W PL2 (short burst), 9 W PL1 (sustained)"; GPU "16.5 W." — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- 15-inch: CPU "23 W PL2, 11 W PL1"; GPU "17 W." The larger chassis sustains slightly more power. — [Notebookcheck MBA15 M5](https://www.notebookcheck.net/Apple-MacBook-Air-15-M5-Review-Very-powerful-fanless-and-without-competition.1244905.0.html)

**Sustained-load behaviour**
- 13-inch, combined CPU/GPU stress: power peaks at up to 26 W, then levels off at about 8 W. In Cinebench 2024 Multi, power falls to about 13 W after a couple of minutes. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- 13-inch: CB24 Multi was 957 on a single run and "820 points at 9 W" after a 30-minute stress, about a 14% drop. Notebookcheck published no per-loop curve. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- 13-inch, average power during the CB R23 Multi + Wild Life Extreme stress test: CPU 4.33 W (range 3.83–11.71 W) and GPU 4.56 W. The M5 MBP 14 averaged 14.9 W CPU and 15.2 W GPU; the M4 Air averaged 3.9 W CPU and 5.08 W GPU. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- 15-inch stress test: up to 28 W, then "quickly levels off at around 9 Watts after around 20 minutes." The page says the system "has to reduce the power limit quite quickly." After a 30-minute CB24 loop, the result is "~10% lower." The GPU drops about 23% in the Steel Nomad Light stress test. — [Notebookcheck MBA15 M5](https://www.notebookcheck.net/Apple-MacBook-Air-15-M5-Review-Very-powerful-fanless-and-without-competition.1244905.0.html); summary via [WebSearch result citing the same review]
- 13-inch GPU: about an 18% drop in the Steel Nomad Light stress test. Gaming SoC power was 7–8 W across all tested games. Cyberpunk 1080p Ultra held a "rock solid" 19.5–19.6 fps over one hour. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- Notebookcheck's later Air-vs-Pro article: the MacBook Pro 14 M5 runs about 40% faster in Cyberpunk 2077. The Pro held a locked 60 fps in Elden Ring, while the Air 13 throttled to about 50 fps. — [Notebookcheck news](https://www.notebookcheck.net/Apple-MacBook-Air-13-M5-gasps-for-air-as-MacBook-Pro-14-M5-shows-40-higher-gaming-performance-in-Cyberpunk-2077.1264788.0.html)
- A developer-oriented test found the M5 Air had the largest repeated-iteration drop-off (about 6%) of five Air generations, yet it still finished fastest overall. — [MindStudio](https://www.mindstudio.ai/blog/m5-macbook-air-dev-review) (secondary, lower authority)
- A consumer guide claims about 40% CPU throttling under extended load. No other source supports that figure. — [Evetech EveZone](https://evezone.evetech.co.za/deep-dives/is-the-base-m5-mac-enough-what-the-fanless-air-s-40-throttle-means-for-you) (treat as an outlier)
- Notebookcheck saw no reduction in CPU performance on battery power. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)

**Surface (skin) temperatures**
- 13-inch, maximum under load: 44.1 °C on top, 42.4 °C on the bottom, 37.1 °C average on top. At idle: 23.7 °C top, 23.8 °C bottom. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- 15-inch: the chassis reaches "slightly more than 40 °C." — [Notebookcheck MBA15 M5](https://www.notebookcheck.net/Apple-MacBook-Air-15-M5-Review-Very-powerful-fanless-and-without-competition.1244905.0.html)
- LTT Labs tested the MacBook Air M5 in a Cinebench 2026 loop with surface thermal imaging, and noted that the M1 Air throttled while its temperature kept rising. The page returned 403, so I could not extract its numbers. — [LTT Labs](https://lttlabs.com/articles/2026/03/25/macbook-thermal-testing)

**Die temperatures (M5 Air data missing; analogues)**
- M5 MacBook Pro 14 (fan, not the Air): Max Tech measured a core average of about 99 °C in Cinebench 2024 multi-core, and the chip "started to throttle due to higher temperatures." — [Macworld](https://www.macworld.com/article/2951397/the-m5-macbook-pro-runs-hotter-than-the-m4-it-replaces.html); [TweakTown](https://www.tweaktown.com/news/108478/apples-new-m5-macbook-pro-cant-stay-cool-with-single-fan-m5-chip-hits-crazy-99c-under-load/index.html)
- Analogue: the M3 15-inch Air (Max Tech) peaked at 114 °C, then throttled frequency and power to settle around 100 °C. — [TechSpot](https://www.techspot.com/community/topics/apple-m3-macbook-air-hits-114-degrees-celsius-under-full-load.284829); [Tom's Hardware forum](https://forums.tomshardware.com/threads/m3-macbook-air-hits-eye-popping-114-degrees-celsius-in-stress-test-and-didnt-melt-%E2%80%94-temperature-settles-down-at-100-degrees-after-thermal-throttling.3838946)
- Analogue: on a 30-minute CB R23 loop, M1 and M2 Airs dropped to 5369 and 6757 points. — [TweakTown](https://www.tweaktown.com/news/87417/apple-m2-macbook-air-throttles-bad-cooled-pro-doesnt/index.html)

### Inferences
- The control loop appears to let die temperatures climb into the high 90s or about 100 °C before cutting power, rather than throttling early. The 38 → 50 °C in 6 s at full clock that the user measured is consistent with that: the Air has thermal mass to spend first. Expect full clocks for roughly the first 1–3 minutes of all-core load, a step down to about 13 W within minutes for CPU-only loads, and about 8–9 W at steady state on the 13-inch. Time to throttle is longer at low ambient temperature and shorter on a lap or bed.
- To show "throttling" honestly, Talon should look at three signals together: CPU busy near 100%, super-core frequency below its DVFS max, and falling package power. The thermal pressure level (section 3) is the authoritative signal.
- Most user workloads (browsing, IDEs, short builds) are bursty and never reach steady state on this machine. Throttling matters for long renders, local LLM inference, gaming and long compiles.

### Gaps
- I found no published M5-Air-specific die temperature traces, sustained per-core clock (GHz) traces, or exact time-to-throttle in minutes. LTT Labs probably has surface data but blocked fetching. Max Tech's M5 Air video was not found in text form.

## 3. Safe temperatures, Apple's thermal management (pressure levels), tjmax, and lifespan effects

### Takeaway
Apple does not publish a tjmax for Apple Silicon. Community measurements show die temperatures of about 100–110 °C (peaks to 114 °C on an M3 Air) under heavy load, with firmware throttling to hold around 100 °C. That is the design operating point, not a fault. macOS exposes a five-level thermal pressure state (nominal, moderate, heavy, trapping, sleeping) via the Darwin notification `com.apple.system.thermalpressurelevel`, with no root needed. The public `ProcessInfo.thermalState` collapses moderate and heavy into "fair." I found no evidence that sustained high SoC temperatures inside Apple's control envelope measurably shorten SoC life. Heat clearly does harm batteries, and Apple says ambient above 35 °C can permanently reduce capacity.

### Cited Findings
**Thermal pressure levels**
- `thermald` publishes the current level to Darwin notifications under `com.apple.system.thermalpressurelevel`, with values defined in `OSThermalNotification.h`; reading it needs no root. `powermetrics -s thermal` (root) also reports "Current pressure level." Levels: nominal (0), moderate (1), heavy (2), trapping (3), sleeping (4). — [stanislas.blog (MacThrottle author)](https://stanislas.blog/2025/12/macos-thermal-throttling-app/)
- Mapping to `ProcessInfo.thermalState`: nominal → nominal; moderate and heavy → fair; trapping → serious; sleeping → critical. The author observed moderate "when the Mac starts getting hot" and heavy "when throttling starts," and never saw trapping or sleeping in stress tests (`stress-ng --cpu 0 -t 600`). — [stanislas.blog](https://stanislas.blog/2025/12/macos-thermal-throttling-app/); [MacThrottle project listing](https://awesome.ecosyste.ms/projects/github.com%2Fangristan%2FMacThrottle)
- Apple's `ProcessInfo.ThermalState` documentation: nominal is within normal limits, fair is slightly elevated, serious is high, and critical "significantly impact[s]" performance and the device needs to cool down. If the state is unknown, it reports nominal. — [Apple Developer docs](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum.md); [Apple Energy Efficiency Guide (archive)](https://developer.apple.com/library/mac/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html)
- The same author noted that an undocumented IOKit API topped out around 80 °C, while iStat Menus and MX Power Gadget showed above 100 °C on the same machine. Sensor choice changes the number dramatically. — [stanislas.blog](https://stanislas.blog/2025/12/macos-thermal-throttling-app/)

**tjmax and "safe"**
- No official Apple tjmax was found. Forum reports put throttling onset at about 100–107 °C, and M4 Max peaks have been reported around 110 °C. — [TidBITS Talk](https://talk.tidbits.com/t/need-fan-setting-assistance/31355); [Wccftech M5 Max thermals](https://wccftech.com/m5-max-runs-cooler-than-m4-max-but-still-gets-scorching-hot/)
- Analogue (Intel's documented position, not Apple's): the junction limit is usually 100–110 °C. Running at or near the maximum during sustained workloads "isn't necessarily cause for concern," and if throttling can't hold a safe temperature, the CPU shuts down. — [Intel support](https://www.intel.com/content/www/us/en/support/articles/000005597/processors.html)
- M3 Air analogue: a 114 °C peak, then a settle at about 100 °C after throttling, with no damage. — [TechSpot](https://www.techspot.com/community/topics/apple-m3-macbook-air-hits-114-degrees-celsius-under-full-load.284829)

**Battery and ambient (Apple)**
- "MacBook works best at 50° to 95° F (10° to 35° C) ambient temperatures." Storage: −20 to 45 °C. Ambient above 35 °C "can permanently damage battery capacity," and "charging the device in high ambient temperatures can damage it further." "Software may limit charging above 80% when the recommended battery temperatures are exceeded." For long-term storage, charge to about 50% and keep below 32 °C. — [Apple Batteries – Maximizing Performance](https://www.apple.com/batteries/maximizing-performance/)

### Inferences
- Talon should key its advice on thermal pressure level, not on raw °C. Suggested mapping: nominal = OK; moderate = "warm"; heavy = "throttling" (performance is reduced, not dangerous); trapping or sleeping = warn loudly, since this is rare and abnormal on a fanless Air.
- For raw die temperature: below about 70 °C is idle or light use; 70–95 °C is normal under load; about 95–105 °C is expected under sustained all-core load (firmware is managing it); sustained readings above about 110 °C, or trapping or sleeping, are unusual. These bands are inferred from community analogues, not Apple specs.
- Longevity advice should focus on the battery: heat while at high state of charge is the documented harm. It should not suggest that a 100 °C die is damaging the SoC, because no evidence supports that.

### Gaps
- No Apple-published tjmax or per-level trigger thresholds; the triggers are opaque thermald policy.
- No published study quantifies SoC electromigration or aging versus temperature for Apple Silicon. No source was found on whether sustained 100 °C operation shortens M-series life.
- No M5-specific data on which pressure level the Air reaches in practice. On M-series Airs, heavy is likely during sustained loads, but this is unverified for M5.
- SSD (NAND) thermal throttling thresholds for Apple's AP-series SSDs were not found.

## 4. Sensor names (tdie, tdev, tcal; PMU vs PMU2) and which to display

### Takeaway
Apple does not document these names. In the widely used Stats app, "PMU tdie%" means "Power management unit die," "PMU tdev%" means "Power management unit dev(ice)," "NAND CH% temp" means "Disk," and "gas gauge battery" means "Battery." On M5, Stats reads per-core CPU and GPU temperatures from SMC keys (Tp00…, Tg0U…) rather than HID. "PMU tcal" appears to be a calibration or constant value; an M2 PMU tcal sensor sat at a fixed 51 °C. Recommended display: CPU/SoC temperature = max (hotspot) of PMU tdie*, or of SMC Tp0* when available; SSD = NAND CH0 temp; Battery = gas gauge battery. Exclude tcal.

### Cited Findings
- From Stats (exelban) `values.swift`, the HID sensor list (all platforms): "PMU tdie%" is "Power management unit die %", "PMU tdev%" is "Power management unit dev %", "NAND CH% temp" is "Disk %s", and "gas gauge battery" is "Battery". On some chips the list also includes "pACC MTR Temp Sensor%" (CPU performance core), "eACC MTR Temp Sensor%" (CPU efficiency core), "GPU MTR Temp Sensor%", "SOC MTR Temp Sensor%", "ANE MTR…", and "PMGR SOC Die Temp Sensor%". Stats has no entry for tcal. — [Stats values.swift](https://raw.githubusercontent.com/exelban/stats/master/Modules/Sensors/values.swift)
- Stats SMC keys for M5 (Platform.m5Gen): CPU super cores `Tp00, Tp04, Tp08, Tp0C, Tp0G, Tp0K`; "CPU performance" cores (Pro/Max) `Tp0O…Tp0y`; GPU `Tg0U, Tg0X, Tg0d, Tg0g, Tg0j, Tg1Y, Tg1c, Tg1g`. No M5 efficiency-core SMC keys are listed. NAND: `TH0x`. Battery: `TB1T`/`TB2T`. Airflow `TaLP`/`TaRF`, ambient `TA%P`. — [Stats values.swift](https://raw.githubusercontent.com/exelban/stats/master/Modules/Sensors/values.swift)
- For comparison, M4 keys are E-cores `Te05, Te0S, Te09, Te0H` and P-cores `Tp01, Tp05, Tp09, Tp0D…`. Keys change every generation. — [Stats values.swift](https://raw.githubusercontent.com/exelban/stats/master/Modules/Sensors/values.swift)
- "Everyone has to reverse engineer the sensors since Apple doesn't document them" and changes them between generations. An open-source developer briefly treated an M2 "PMU tcal" that "was always at 51 °C" as a real temperature. — [MacRumors forum](https://spy.macrumors.com/threads/temps-on-new-m2-macbook-pros.2378659)
- macmon reads HID temperatures by matching the Apple vendor usage page 0xff00 and usage 0x0005 (temperature sensor), takes names from the "Product" property, discards readings ≤0 or >150 °C, and sorts by name. Its frequency tables come from `pmgr` `voltage-states1-sram` (E cluster), `voltage-states5-sram` (P/super cluster) and `voltage-states9` (GPU). On M5 it falls back to parsing `acc-clusters`. "M4+ store [frequencies] in kHz." — [macmon sources.rs](https://docs.rs/crate/macmon/latest/source/src/sources.rs)
- Different APIs give very different numbers on the same Mac: an undocumented IOKit read peaked around 80 °C while iStat and MX Power Gadget showed over 100 °C. — [stanislas.blog](https://stanislas.blog/2025/12/macos-thermal-throttling-app/)

### Inferences
- The user's M5 Air HID list has no pACC/eACC MTR names, only PMU tdie/tdev. So with HID alone, "CPU temperature" must be derived from PMU tdie1–14, which are die-level sensors read via the power management unit. Show the max as "SoC hotspot," and optionally the mean as "SoC average." The max correlates best with throttling decisions.
- tdev sensors likely sit on or near the package or board rather than the hottest silicon. They are useful as a "device/board" temperature but should not be headlined as CPU temperature.
- "PMU2" is probably a second PMIC (power management IC) instance with its own die and dev sensors, not a separate CPU cluster. This comes from the naming only; no source confirms it. Treat it like PMU (include PMU2 tdie in the hotspot max only if it tracks load).
- tcal should be excluded: it is likely a calibration reference, and the M2 evidence shows it constant at 51 °C. Talon can confirm this empirically by checking that it does not change under load.
- SMC keys Tp00/Tp04/Tp08/Tp0C (4 super cores on base M5) are the most CPU-specific source if Talon can read SMC. Validate them on-device, because Stats' list is community-maintained.
- SSD: show "NAND CH0 temp" (HID) or `TH0x` (SMC). Battery: "gas gauge battery" (HID) or `TB1T`/`TB2T` (SMC).

### Gaps
- No authoritative definition of "tdie", "tdev", "tcal" or "PMU2" was found from Apple or Asahi docs. Asahi Linux sensor documentation was not reached in this session.
- Whether the M5 base exposes efficiency-core temperatures by any key is unknown.

## 5. Practical guidance for fanless Macs; known issues or recalls

### Takeaway
The documented guidance is Apple's: use the MacBook at 10–35 °C ambient, avoid charging in heat, and don't charge inside insulating cases. Above-temperature conditions make macOS cap charging at 80%. A fanless Air dissipates heat through the bottom and top chassis (about 42–44 °C surfaces under load), so soft surfaces and clamshell use reduce sustained performance, but they are a performance issue, not a safety one. As of the sources found, there is no recall or widespread hardware defect for the M5 MacBook Air.

### Cited Findings
- Apple: ambient 10–35 °C. Above 35 °C can permanently damage battery capacity, and charging in heat damages it further. Charging may be held at 80% when battery temperature limits are exceeded. Remove certain cases before charging because they "may generate excess heat." — [Apple Batteries](https://www.apple.com/batteries/maximizing-performance/)
- The M5 Air chassis reaches 42.4 °C on the bottom and 44.1 °C on top under maximum load. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html)
- Notebookcheck's 13-inch unit came with a 30 W PSU that "limits power for a few seconds during the stress test before consumption settles around 24 W" at the wall, and listed load wall power at 29.4–30.4 W. Separate coverage says a 40 W Dynamic Power Adapter (60 W max) is included in some markets. The UK reportedly lacks it, per an unverified MacRumors comment. The bundled charger varies by configuration and region. — [Notebookcheck MBA13 M5](https://www.notebookcheck.net/Insane-performance-and-efficiency-without-fans-Apple-MacBook-Air-13-M5-Entry-Review.1242707.0.html); [MacRumors comments](https://www.macrumors.com/2026/03/03/apple-announces-macbook-air-with-m5/)
- Analogue claim, M4 Air: at 28–30 °C ambient, throttle onset shifts toward about 6–7 minutes. This comes from an unverified secondary source. — [TechYorker](https://techyorker.com/?p=491784)
- Known issues: searches found no recall or Apple safety notice for the M5 MacBook Air. Pre-launch articles speculated that the fanless Air would struggle with the M5, but those were not defect reports. The concrete heat-related report I found was a single Reddit claim of display discoloration on an M5 **Max** MacBook Pro, not the Air. — [Gizmodo Japan](https://www.gizmodo.jp/2025/10/m5-macbook-may-have-big-problem.html); [BGR](https://www.bgr.com/2005890/m5-macbook-pro-design-flaw/); [Wccftech](https://wccftech.com/m5-max-excessive-heat-can-cause-rare-macbook-pro-display-discoloration//amp/)
- Apple published the MacBook Air (15-inch, M5) repair manual on 12 March 2026. This is routine and not a defect indicator. — [Apple Support 125764](https://support.apple.com/en-us/125764)
- An aggregator reports an early activation problem on some M5 MacBook Pro units that Apple tied to the N1 chip. The source is likely auto-generated, so it is low confidence. — [ShopSavvy](https://shopsavvy.com/answers/macbook-pro-m5-known-problems-issues-bugs.md)

### Inferences (advice Talon could give, derived from the above)
- **Lap or bed:** Fabric blocks the bottom panel, which is a primary heat-spreading surface. Expect earlier throttling and a warmer battery. Advise a hard surface for long heavy jobs. This is about performance and battery comfort, not danger.
- **Ambient:** Warn when the measured ambient or idle chassis temperature implies more than 35 °C (Apple's limit), especially while charging.
- **Charging under load:** Charging adds battery heat on top of SoC heat. During sustained heavy work, suggest letting Optimized Battery Charging or the charge limit hold around 80%. Do not push full charges while the battery is hot. Talon can show "charging paused/limited for temperature" when it sees the cap.
- **Clamshell mode:** The lid closed reduces top-surface dissipation. Expect lower sustained clocks. A vertical stand or an open lid helps somewhat. (Inferred; no M5-specific measurements were found.)
- **External cooling:** A metal stand or a laptop cooler under the bottom panel plausibly extends time before throttling on a fanless chassis. No M5 Air measurements quantify this, so it is a gap.
- **Low Power Mode:** No M5 Air measurements were found. On Apple Silicon it lowers clocks and power, so it would reduce heat and the throttling swing at the cost of peak speed. Talon could suggest it for long background jobs.

### Gaps
- No M5-Air-specific measurements on lap use, clamshell mode, external coolers, or Low Power Mode effects on temperature or sustained performance.
- No late-2026 news (after about March–July 2026 coverage) was found on M5 Air hardware issues. A dedicated search on Apple Community forums for specific defects (e.g. display, hinge, SSD) was not done and may be worth a follow-up.
