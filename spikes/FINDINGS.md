# Talon — Phase 0 findings

Machine: MacBook Air (Mac17,3), Apple M5 (4 Super + 6 Efficiency cores), 16 GB, 512 GB SSD, macOS 27.0.1, Xcode 27.2.
Rebuild everything: `./build.sh`. Admin-only tests: `sudo ./root-tests.sh` (installs the helper, tests it, removes it).

## Verdict

| # | Question | Result |
|---|---|---|
| 1 | Sample every process cheaply? | ✅ with a tiered design |
| 2 | Hard memory cap? | ✅ at launch with no admin · ✅ on running apps via the helper |
| 3 | See heat + throttling on a fanless Air? | ✅ no admin needed |
| 4 | Read SSD wear + battery health? | ✅ no admin needed |
| 5 | Admin helper over XPC? | ✅ installs, connects, enforces, safety rule holds |

## 1. Sampler — `1-sampler/`

- Sweeping all ~680 processes costs ~3.5 ms. As yourself, ~440 are readable; the other ~240 (root/system) need the helper.
- 4 Hz full sweep = **1.5 % CPU** → too much. **1 Hz full sweep = 0.35 %**, own memory 2 MB.
- Tiered design: 1 Hz for everything + faster checks only for apps with a ceiling. 85 capped processes at 4 Hz → 0.6 % total; at 10 Hz → 1.2 %. Real-world caps are a handful of processes, so 4–10 Hz on capped apps is fine.
- Grouping helpers under their app (`responsibility_get_pid_responsible_for_pid`) works — e.g. Safari 18 processes, ChatGPT 33.

**Decision:** 1 Hz sweep, 4 Hz default for capped apps (user-adjustable).

## 2. Memory ceilings — `2-memcap/`

Test: a "hog" grows 25 MB every 60 ms (~400 MB/s); ceiling 300 MB.

| Method | Admin? | Result |
|---|---|---|
| A. Kernel cap set **at launch** (`posix_spawnattr_setjetsam_ext`) | **No** | ✅ Killed by the kernel at 275 MB — never exceeds the ceiling |
| B. Kernel cap on a **running** process (`SET_MEMLIMIT_PROPERTIES`) | Yes | ✅ As root: killed by the kernel at 275 MB. Refused as user (EPERM) |
| C. Older `SET_JETSAM_TASK_LIMIT` | Yes | ❌ Invalid argument on macOS 27 — use B |
| D. Soft cap — Talon watchdog kills on breach | No | ✅ 4 Hz: stopped at 300 MB · 10 Hz: 325 MB (overshoot ≤ one 25 MB step) |
| E. Launch cap inherited by **child processes**? | — | ❌ Not inherited — each process has its own kernel limit |

**Decisions:**
- `cap run` uses method A → true hard cap with no admin.
- Experiments that spawn workers: Talon enforces a **budget for the whole process tree** with the watchdog (kernel limits are per process), and the helper can also apply per-process kernel caps to children as they appear.
- Strictness levels Watch → Quit run on the watchdog; "Hard cap" uses the kernel.

## 3. Heat & throttling — `3-thermal/` (`./thermal 300` for a 5-minute soak)

- **39 temperature sensors** readable (CPU die ×14, SoC, SSD NAND, battery). Ignore the `tcal` calibration sensors.
- **Thermal pressure level** (nominal → critical) readable.
- **Live clock speed per cluster** (IOReport): E-cores max 3048 MHz, Super cores max 4464 MHz. Under full load for 6 s: clocks pinned at max, die 38 → 50 °C, pressure nominal.
- **Throttling metric** = average active clock ÷ max clock while busy. On a fanless Air this drops during sustained load; a 5-minute soak (`./thermal 300`) will show it. Not run yet, to avoid heating your laptop mid-session.
- ⚠️ Per-component **CPU power** from IOReport reads 0 on M5. Use whole-system power from the battery instead (below). GPU clock table doesn't map cleanly; GPU busy % works.

## 4. SSD & battery — `4-health/`

SSD (Apple AP0512Z), read directly — smartmontools not needed:
- Wear **0 %**, spare 100 %, no media errors, no critical warnings, 35 °C.
- **12.08 TB written** / 32.94 TB read. 20 unsafe shutdowns.
- Apple SSD "power-on hours" (266) under-reports real use, so write *rates* must come from Talon's own daily history, not SMART hours.

Battery:
- 97 cycles. On macOS 27 capacities live under `BatteryData` (top-level values read 0).
- Raw: design 4629 mAh, nominal 4315 mAh → **93.2 %**; Apple shows **97 %** (System Information). Show Apple's figure as the headline, track raw mAh as the trend.
- Battery temperature: use the `gas gauge battery` sensor from spike 3.
- **Whole-system power draw** live (`PowerTelemetryData.SystemLoad`) — e.g. 3.9 W idle, 17.4 W busy.

## 5. Admin helper — `5-helper/`

Design: root LaunchDaemon `talond`, XPC Mach service `dev.talon.helper`.
Safety: accepts connections only from your user ID; acts only on processes you own (refuses system processes).

- ✅ Installed as a LaunchDaemon with a 3-line script; launchd starts it on demand.
- ✅ As root it can read **all** processes (556/556, vs ~440 as user).
- ✅ Safety rule held: refused to cap launchd (pid 1, owned by root).
- ✅ Hard-capped an already-running process through XPC → kernel killed it at 275 MB (ceiling 300).
- Ad-hoc signing (plain `swiftc` output) is enough — no Apple Developer account needed.
- Uninstalled cleanly after the test.

## Insights already worth surfacing in the app
- 0.9 GB of swap in use on 16 GB → watch swap growth, since it drives SSD writes.
- 12 TB written in this SSD's life so far → "who's writing to your SSD" view is worth building.
- 20 unsafe shutdowns → track and flag new ones.
