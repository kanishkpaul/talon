<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/banner-light.svg">
    <img alt="talon — a firm grip on your mac" src="assets/banner-dark.svg" width="100%">
  </picture>
</p>

<p align="center">
  <img alt="macOS 27" src="https://img.shields.io/badge/macOS-27-1d1d1f?style=flat-square&logo=apple&logoColor=white">
  <img alt="Apple silicon M5" src="https://img.shields.io/badge/Apple%20silicon-M5-0A84FF?style=flat-square">
  <img alt="Swift 6.4" src="https://img.shields.io/badge/Swift-6.4-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="status" src="https://img.shields.io/badge/status-phase%201%20in%20progress-0A84FF?style=flat-square">
  <img alt="personal" src="https://img.shields.io/badge/built%20for-one%20mac-8E8E93?style=flat-square">
</p>

<p align="center">
  <b>Put a ceiling on anything. See what wears your hardware. Reclaim space with a scalpel. Keep this Mac healthy for years.</b><br>
  <sub>A personal control panel for a fanless M5 MacBook Air — native, quiet, and as polished as the machine it runs on.</sub>
</p>

<p align="center">
  <a href="#what-talon-does">What it does</a> ·
  <a href="#proven-on-the-metal">Phase 0 results</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="#the-app">The app</a> ·
  <a href="#build-and-run">Run it</a>
</p>

<br>

## What talon does

<table>
  <tr>
    <td width="25%" valign="top">
      <h3>Ceilings</h3>
      Give any app, process or experiment a limit on memory, CPU or disk I/O — and decide, per rule, how hard talon holds the line.
    </td>
    <td width="25%" valign="top">
      <h3>Health</h3>
      Battery capacity and cycles, SSD wear and bytes written, 39 temperature sensors, thermal throttling, swap and memory pressure — with history going back months.
    </td>
    <td width="25%" valign="top">
      <h3>Care</h3>
      Specific, honest advice: what is writing to your SSD, when the battery has been parked at 100 % too long, what was running when the chip throttled.
    </td>
    <td width="25%" valign="top">
      <h3>Scalpel</h3>
      Surgical storage cleanup: the exact space each cut gives back, what it is, what it costs to remove — and every cut reversible.
    </td>
  </tr>
</table>

### You choose how strict each ceiling is

| Level | When a ceiling is crossed |
|---|---|
| **Watch** | Mark it on the chart. Nothing else. |
| **Warn** | Send a notification. |
| **Ask** | A small glass panel: *raise the ceiling*, *pause*, or *quit*. |
| **Slow down** | Move it to the efficiency cores and throttle its disk I/O. |
| **Pause** | Freeze it in place. One click resumes it. |
| **Quit** | Ask it to quit; force-quit after a grace period. |
| **Hard cap** | The kernel enforces it. The process can never exceed the ceiling. |

Every rule also has a warning threshold and a grace period, so a one-second spike never kills your work. The signature interaction: set a ceiling by **dragging a line across the app's live chart**, with a haptic tick as you cross its current usage.

### For experiments

```bash
talon run --mem 6G -- python train.py                           # works today: kernel-enforced, no admin
talon run --mem 6G --cpu 200% --strict ask -- python train.py   # planned
```

A hard memory ceiling on the command today; a shared budget across every worker it spawns is next.

### scalpel: storage, cut precisely

Most cleaners guess. They add up folder sizes that double-count APFS clones, wipe caches that refill an hour later, and hide what they removed. scalpel measures the **space you would actually get back** (clone-aware, hard-link-aware, snapshot-aware), and explains each item before you touch it: what it is, which app made it, when it was last used, and what happens after it's gone.

| | |
|---|---|
| **Finds** | Xcode DerivedData and simulators, package-manager caches, Docker disks, AI models, stale `node_modules`, leftovers from deleted apps, installer debris, duplicates, large untouched files, snapshot-held space |
| **Cuts** | Into a 7-day holding area, restorable in one click. Uses each app's own cleanup tool where one exists. Never touches system paths. |
| **Protects** | Warns when clearing a cache would just cost SSD writes to rebuild it. Replaces duplicates with APFS clones instead of deleting. |
| **Watches** | Free-space forecast, the folders growing fastest, runaway logs and caches |

```bash
talon scalpel scan ~                          # planned CLI
talon scalpel clean --tier safe --dry-run
```

Design: [`docs/scalpel.md`](docs/scalpel.md).

<br>

## Proven on the metal

Before writing the app, every risky piece was tested on the actual machine — an M5 MacBook Air (4 Super + 6 Efficiency cores, 16 GB, 512 GB) on macOS 27. Full write-up: [`spikes/FINDINGS.md`](spikes/FINDINGS.md).

| Question | Answer |
|---|---|
| Can it watch every process without becoming the problem? | **Yes.** A full sweep of ~680 processes costs **0.35 % CPU** at 1 Hz, with 2 MB of memory. Capped apps get a faster 4 Hz lane. |
| Can memory be hard-capped on macOS? | **Yes.** Set at launch, the kernel killed a runaway process at **275 MB of a 300 MB ceiling** — no admin needed. Running apps can be capped through the helper. |
| Is the soft cap fast enough? | **Yes.** Against memory growing at ~400 MB/s, the watchdog overshot by at most one 25 MB step. |
| Can it see heat on a fanless Mac? | **Yes.** 39 sensors, macOS's thermal pressure level, and live clock speed per cluster (E-cores 3048 MHz, Super cores 4464 MHz). |
| Can it read SSD and battery health directly? | **Yes.** NVMe SMART and the battery controller, no third-party tools. |
| Can a root helper be safe? | **Yes.** `talond` serves one user ID, refuses system processes, and hard-capped a running app over XPC. |

<details>
<summary><b>What phase 0 changed in the design</b></summary>
<br>

- Kernel memory limits are **per process**, not inherited by children — so experiments get a process-tree budget enforced by talon itself.
- Sweeping every process 4× a second cost 1.5 % CPU — so sampling is **tiered**: 1 Hz for everything, faster only for capped apps.
- IOReport CPU energy counters read **zero on macOS 27** — so power comes from the battery's own telemetry instead.
- The older `SET_JETSAM_TASK_LIMIT` call is rejected on macOS 27 — talon uses `SET_MEMLIMIT_PROPERTIES`.

</details>

<details>
<summary><b>This Mac today</b> · November 2026</summary>
<br>

| | Reading | Verdict |
|---|---|---|
| Battery | 97 cycles · 97 % (Apple) · 93.2 % raw nominal | Healthy — ~10 % of its 1,000-cycle rating |
| SSD | 0 % wear · 12.08 TB written · 0 media errors · 100 % spare | Healthy — roughly 1–4 % of expected endurance |
| Memory | 0.9 GB swap on 16 GB | Normal |
| Storage | 231 GB free | Plenty |
| Thermals | Nominal pressure · die 38 → 50 °C under a short full load | As designed |

Deeper analysis: [`docs/reports/macbook-air-m5-health.md`](docs/reports/macbook-air-m5-health.md).

</details>

<br>

## Architecture

```mermaid
flowchart LR
    subgraph user["your session"]
        app["talon.app<br/>menu bar · window"]
        cli["talon<br/>CLI"]
        widget["widgets"]
    end

    subgraph root["root · launchd"]
        talond{{"talond"}}
        sampler["sampler<br/>1 Hz all · 4 Hz capped"]
        rules["rules engine"]
        enforcer["enforcer<br/>signals · QoS · jetsam"]
        probes["health probes<br/>SMART · battery · thermal"]
        db[("SQLite<br/>tiered history")]
    end

    kernel["XNU · IOKit"]

    app <-->|XPC| talond
    cli <-->|XPC| talond
    talond -.->|snapshot| widget
    talond --- sampler --> rules --> enforcer --> kernel
    talond --- probes --> kernel
    sampler --> db
```

History is kept the way a careful TSDB would keep it: the last hour lives in memory, older data is rolled up into 10-second, 1-minute and hourly tiers, and writes are batched — so a tool meant to protect the SSD doesn't wear it.

### Stack

| Layer | Choice |
|---|---|
| Language | Swift 6.4, plus a thin C / Objective-C shim for private headers |
| Interface | SwiftUI, with AppKit for the menu bar panel and the live process table |
| Charts | Swift Charts on pre-downsampled series |
| Storage | SQLite via GRDB, owned by `talond` |
| IPC | XPC over a launchd Mach service |
| Build | One Swift package for the core, daemon and CLI · XcodeGen for the app and widget |

Why this stack, and what was ruled out: [`docs/reports/talon-stack-choice.md`](docs/reports/talon-stack-choice.md).

<br>

## Roadmap

- [x] **Phase 0** — prove the risky parts on this Mac
- [x] **Research** — language and stack, and the hardware itself
- [ ] **Phase 0.5** — settle the open questions: XPC peer requirements, widgets under personal signing, live-table and chart performance, a 24-hour write soak, scalpel scan speed and exact-reclaim accuracy
- [ ] **Phase 1** — `talond`, the sampler, tiered history, the menu bar panel, Overview and Processes
  - [x] TalonKit package: C shim, model, IPC schema, sensors, sampler, tiered aggregator, policy
  - [x] `talond`: 1 Hz sweep, SQLite history (10 s / 1 min / 1 h + events), XPC, cap / freeze / thaw
  - [x] `talon` CLI: `status`, `top`, `health`, `run --mem`, `cap`, `freeze`, `history`, `apps`, `events`
  - [x] Menu bar panel, Overview and Processes (XcodeGen app on an AppKit spine)
  - [ ] Run the app against a live `talond` (agent or root daemon) and tune it on real data
- [ ] **Phase 2** — ceilings, the strictness ladder, drag-to-set, `talon run`
- [ ] **Phase 3** — Health and History
- [ ] **Phase 4** — scalpel: exact-reclaim scanner, findings, holding area, growth watch
- [ ] **Phase 5** — Care, notifications, widgets, charge-limit awareness
- [ ] **Phase 6** — motion, haptics, accessibility, the last 10 %

<br>

## The app

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/panel-dark.png">
    <img alt="The talon menu bar panel" src="docs/screenshots/panel-light.png" width="360">
  </picture>
  <br><sub>The menu bar panel (rendered with <code>--demo</code> data).</sub>
</p>

A bird in the menu bar that stays quiet until something needs attention: it turns orange under memory or thermal pressure, red when either is critical. Click it for the panel: six live readings with the last five minutes behind each, and the top apps. The window adds **Overview** (history from 15 minutes to 30 days, with min–max bands so spikes survive downsampling; battery, SSD, thermal and storage health; who wrote to the SSD today) and **Processes** (every process grouped under its app, filterable, sortable, with pause, resume and memory ceilings from the context menu).

The app links only `TalonModel` and `TalonIPC`. Every number comes from `talond` over XPC, so it never needs sensors, private APIs or the database.

```bash
make app        # build .build/app/Build/Products/Release/Talon.app
make app-demo   # run it on synthetic data, window open, labelled DEMO DATA
make snapshots  # render panel, Overview and Processes (light + dark) to PNGs, no screen access needed
```

## Build and run

Needs Xcode 27 (Swift 6.4). Everything below runs as you; only `sudo make install` needs admin.

```bash
make                       # release build of talon + talond, ad-hoc signed
make test                  # 47 tests, including real XPC round-trips and a kernel ceiling

.build/release/talon                      # status: CPU, memory, swap, thermals, power, free space
.build/release/talon top --sort disk      # who's writing to the SSD right now, grouped by app
.build/release/talon health               # battery, SSD SMART, 37 sensors — straight from the hardware
.build/release/talon run --mem 2G -- cmd  # kernel memory ceiling at launch, no admin
```

History, `cap`, `freeze` and `apps` talk to `talond`. Run it one of two ways:

| | Command | Sees | Can |
|---|---|---|---|
| **User agent** | `make agent` · `make unagent` | your processes | history, freeze / thaw |
| **Root daemon** | `make build && sudo make install` · `sudo make uninstall` | every process | all of that, plus kernel ceilings on running apps |

```bash
talon daemon                          # is it running, and what does it cost?
talon history cpuTemp --range 24h     # sparkline + min / avg / max from the tiered history
talon apps --range 7d --by disk       # which apps wrote the most
talon freeze 4242 && talon thaw 4242  # pause in place; talond resumes it if talond ever exits
talon cap 4242 --mem 2G               # root daemon only
make logs                             # follow talond's log
```

Measured on this Mac: release `talond` costs **~0.5 % CPU and 5.6 MB** sweeping ~570 processes once a second with every sensor on, and commits history once a minute.

<details>
<summary><b>What building phase 1 changed</b></summary>
<br>

- `PowerTelemetryData.SystemLoad` goes stale on battery (0.5 W while the pack supplied 3.6 W), so system power is voltage × current, minus what goes into the battery when plugged in.
- The per-app minute table holds the top 40 apps by CPU, by memory *and* by writes, so ~80–110 rows a minute here rather than 40.
- The daemon's logic lives in a library (`TalonDaemon`), so tests drive the real request handling over a real anonymous XPC connection without launchd or root.

</details>

### The phase 0 spikes

```bash
cd spikes && ./build.sh
./1-sampler/sampler --hz 1 --fast-hz 4 --watch 5   # sweep every process, report overhead
./2-memcap/memcap 300                              # hard and soft memory ceilings
./3-thermal/thermal                                # sensors, pressure, clocks (try: thermal 300)
./4-health/health                                  # SSD SMART + battery
sudo ./root-tests.sh                               # installs the spike helper, tests it, removes it
```

## Repository

```
talon/
├── Package.swift        TalonKit: libraries + talond + talon
├── Makefile             build · test · sign · agent · install · logs
├── Sources/
│   ├── TalonPrivate/    C shim: memorystatus, jetsam spawn, responsible pid, HID temps, NVMe SMART
│   ├── TalonModel/      Sendable value types shared by everything (and later the app)
│   ├── TalonIPC/        TalonRequest / TalonReply, the wire codec, the XPC client
│   ├── TalonSensors/    processes, memory, CPU, disk, thermal, battery, SSD
│   ├── TalonCore/       sampler, tiered aggregator, policy, enforcer, capped launcher
│   ├── TalonStore/      GRDB schema, tiers, retention (daemon-only)
│   ├── TalonDaemon/     talond's state, request handling, XPC listener
│   ├── talond/          the helper's entry point
│   └── talon/           the CLI
├── Tests/TalonTests/    Swift Testing: units, policy table, store, codec, live sensors, XPC
├── App/
│   ├── project.yml      XcodeGen spec (the .xcodeproj is generated, not committed)
│   └── TalonApp/        menu bar panel, Overview, Processes (NSOutlineView), demo source, snapshots
├── launchd/             LaunchDaemon and LaunchAgent plists
├── assets/              banner art
├── docs/
│   ├── scalpel.md       storage analyser and cleaner design
│   ├── reports/         stack choice · M5 Air health and longevity
│   └── research/        the notes behind the reports
└── spikes/              phase 0 — every risky API, tested on this Mac
```

## Principles

- **Never the problem it solves.** Under 1 % CPU, a few MB of memory, minimal SSD writes.
- **Safe by construction.** The helper only acts on your own processes, refuses system ones, accepts typed commands only, and every pause can be undone.
- **Honest numbers.** Apple's figures where they exist, raw values beside them, and a clear line between measured and estimated.
- **Native or nothing.** No web views. Liquid Glass, SF Symbols, spring animations, real haptics.

<br>

<p align="center">
  <sub><b>talon</b> — the claw of a bird of prey. It grips hard, and lets go exactly when it should.</sub><br>
  <sub>A personal project, built for exactly one Mac.</sub>
</p>
