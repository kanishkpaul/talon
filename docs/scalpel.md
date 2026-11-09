# scalpel — surgical storage analysis and cleanup

Part of talon. Status: **built** — `TalonScalpel` (scanner, findings, holding area, dedupe), `talon scalpel` in the CLI, and the Scalpel pane in the app; spikes measured (see [Spike results](#spike-results)).

Most Mac "cleaners" guess. They show folder sizes that double-count APFS clones, delete caches that rebuild themselves an hour later (wearing the SSD to free space that comes straight back), and hide what they actually removed. scalpel does the opposite: it measures exactly what deleting something will give back, explains what each item is and what removing it costs, and every cut is reversible.

## Principles

1. **Exact, not estimated.** Every number is the space you would actually get back — not the logical file size.
2. **Explain every cut.** Each item shows what it is, who made it, when it was last used, why it's safe (or not), and what happens after it's gone.
3. **Reversible by default.** Nothing is deleted directly. Items go to a holding area and are purged later, or to the Trash.
4. **Use the owner's tool.** Where an app has its own cleanup command (`xcrun simctl`, `brew cleanup`, `docker system prune`, `tmutil`), scalpel calls it instead of deleting files behind the app's back.
5. **Protect the SSD.** Clearing a cache that regenerates costs writes. scalpel says so, and only suggests it when the space is needed or the cache is stale.
6. **Never touch what it can't explain.** System and SIP-protected paths, and personal documents, are off-limits unless you point scalpel at them explicitly.

## What "exact" means on APFS

A Finder-style size total is wrong on APFS for four reasons. scalpel handles each:

| Trap | Why sizes lie | How scalpel gets it right |
|---|---|---|
| **Clones** | Copied files share blocks until edited. Deleting one copy frees almost nothing. | `ATTR_CMNEXT_PRIVATESIZE` gives the bytes that belong to this file alone. `ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_CLONE_REFCNT` group the clones. |
| **Hard links** | One file with many names gets counted many times. | Count each inode (`ATTR_CMN_FILEID`) once. On APFS `ATTR_CMNEXT_LINKID` is per *name*, not per file, and every name reports the full size as private — see spike 2. |
| **Firmlinks / volume group** | `/` and `/System/Volumes/Data` show the same data twice. | Walk the Data volume (`/` becomes `/System/Volumes/Data`); never cross a device or mount point, never follow a symlink. |
| **Snapshots & purgeable** | Deleted files can stay on disk inside local Time Machine snapshots; "purgeable" space is only an estimate. | Show snapshot-held space separately (`tmutil`). Report the container's real free space, not the purgeable total. |

The result for any folder is three numbers: **logical size** (what Finder shows), **on-disk size**, and **reclaimable** (what you'd actually get back). The reclaimable number drives every decision.

Scanning uses `getattrlistbulk(2)`, which fetches all attributes for a whole directory in one call. Measured: a 1.86 M-item home folder in ~23 s using one core of kernel time, with no effect on a 1 Hz timer (spike 1).

## What it finds

Each finding has a **safety tier**:

- **Safe**: regenerates automatically and holds no unique data.
- **Review**: probably unneeded, but it's your call.
- **Protected**: shown for context, never cleaned.

| Category | Examples | Tier | How it's removed |
|---|---|---|---|
| Developer build output | Xcode DerivedData, Archives, old device support files, `target/` (Cargo), `.build/` (SwiftPM), Gradle caches | Safe / Review | Holding area. Rebuilds take longer afterwards. |
| Simulators | Unavailable simulators, old runtimes | Safe | `xcrun simctl delete unavailable`, `simctl runtime delete` |
| Package caches | Homebrew, npm/pnpm/yarn/bun, pip/uv/conda, CocoaPods | Safe | The owner's tool (`brew cleanup`, `npm cache clean`, …) |
| Containers and VMs | Docker / OrbStack disk images, dangling images, build cache | Review | `docker system prune` (shows what it would remove first) |
| AI models | Hugging Face hub, Ollama, LM Studio, MLX weights | Review | Holding area. Shows the model name and when it was last loaded. |
| Stale projects | `node_modules` and virtualenvs in repos with no commit for N months | Review | Holding area. Easy to restore with `npm i` / `uv sync`. |
| App leftovers | `~/Library/Application Support`, `Containers`, `Caches` and `Preferences` folders for apps that are no longer installed (matched by bundle ID) | Review | Holding area |
| Downloads debris | `.dmg` / `.pkg` / `.zip` installers already installed or older than N days | Review | Trash |
| Duplicates | Identical files, matched by size, then a partial hash, then a full hash, excluding clones that already share blocks | Review | Replace the duplicate with an APFS clone (frees the space, keeps both paths), or Trash it |
| Large & old | Big files not opened in N months (last-used date from Spotlight metadata) | Review | Trash |
| Snapshots | Local Time Machine snapshots holding deleted data | Review | `tmutil deletelocalsnapshots` |
| System | `/System`, SIP-protected paths, the swap files, other users' data | Protected | Never |

Every row in the UI shows the path, the owning app, last used, reclaimable bytes, the reason it's in this tier, and **what happens after**. For example: "Next Xcode build of this project will take ~2 min longer", or "Ollama will re-download this model (4.7 GB) if you use it again".

## The cut

1. **Select.** Pick items, or a preset such as "Safe only", "Developer", or "Free 50 GB with the least regret".
2. **Preview.** See the exact reclaimable total, a list of every path, which owner tools will run, and the estimated SSD writes if the item will regenerate.
3. **Cut.** Items move to `~/.talon/holding/` (same volume, so the move is instant and writes nothing). Owner tools run with their own confirmations.
4. **Hold.** For 7 days (configurable), restoring anything is one click.
5. **Purge.** Holding-area items are deleted for good after the hold period, or immediately on request.

Safety checks before any cut:
- No process has a file in the item open (checked with `proc_pidfdinfo`).
- The owning app isn't running.
- The path is inside an allowed root, with symlinks never followed outward.
- Full Disk Access is present, so the scan isn't silently missing folders.

## Watching growth over time

scalpel also feeds talon's history:
- Free space over time, with a forecast of when it will cross the 60 GB floor.
- Growth per top-level folder, with alerts when something grows unusually fast (for example a log or cache adding 5 GB a day).
- "Who grew this week": the five folders that gained the most space.
- A link to talon's SSD-write tracking: an app that writes a lot *and* holds a lot of space gets flagged once, not twice.

## Interface

- **Map:** a sunburst you drill into, with segments sized by reclaimable bytes rather than logical size. A toggle switches to a treemap.
- **Findings:** the categories above, grouped and sorted by reclaimable space, each with its safety-tier badge.
- **Inspector:** a side panel with the full explanation for the selected item.
- **Holding area:** what's held, when it purges, and one-click restore.
- **CLI:**

  ```bash
  talon scalpel scan ~                     # map + findings, as a table or --json
  talon scalpel why ~/Library/Developer    # explain one path
  talon scalpel clean --tier safe --dry-run
  talon scalpel holding                    # what's held, and when it purges
  talon scalpel restore <cut-id>           # put a cut back (never overwrites)
  talon scalpel purge --older-than 7d      # dry run; add --yes to delete for good
  talon scalpel dedupe ~/Photos-export     # duplicates → APFS clones (dry run; --yes to apply)
  ```

  `clean` is a dry run unless you pass `--yes`. It leaves out caches used in the last 14 days (unless free space is under 60 GB, or with `--include-recent`), and it runs owner tools only with `--run-tools`.

## Where it runs

The scan runs **as you**, in the app or CLI, not in `talond`. Your files don't need root access, and keeping the root helper's job small keeps it safe. scalpel needs Full Disk Access to see everything; without it, it says which folders it couldn't read instead of under-reporting.

## Spikes before building

1. **Scan speed.** `getattrlistbulk` over the whole home folder: time taken, CPU used, and whether it disturbs the 1 Hz sampler.
2. **Exact reclaim.** Clone a 1 GB file, then compare `PRIVATESIZE` and `CLONE_REFCNT` with the free space actually recovered after deleting each copy.
3. **Duplicate → clone.** Use `clonefile(2)` to replace a duplicate with a clone, and confirm the metadata and extended attributes survive.
4. **Snapshot-held space.** Measure how much space local snapshots hold, and that it's released after `tmutil deletelocalsnapshots`.
5. **App leftovers.** Match leftover folders to installed apps by bundle ID, with no false positives, across `/Applications`, `~/Applications`, and Setapp / Homebrew casks.

## Spike results

Measured on the M5 MacBook Air (10 cores: 4 P + 6 E, 16 GB, 512 GB), macOS 27.0.1, 9 November 2026. Scripts are in [`spikes/6-scalpel/`](../spikes/6-scalpel/). Everything against the real home folder was read-only. Spikes 2 and 3 ran in temp folders they created and removed.

### 1. Scan speed — fast enough; two workers is the sweet spot

`1-scan-speed.sh` scans `~` twice with `talon scalpel scan ~ --no-duplicates --json` while a 1 Hz timer runs alongside. `1b-workers.sh` varies the worker count and costs each attribute.

| | Result |
|---|---|
| Home folder | 1,620,660 files, 241,224 folders, 19,025 symlinks |
| Wall time (2 workers, default) | **23.2–23.8 s** (~79,000 items/s), plus about 1 s for the findings |
| CPU | 22.9–23.6 s, almost all of it kernel (0.8 s user, 22.4 s system): about **one core** at utility QoS |
| Peak memory | 71–76 MB resident |
| 1 Hz timer while scanning | mean 3.2–3.6 ms late, max 5.0 ms. Idle baseline: mean 3.8 ms, max 5.0 ms. **No visible effect.** |
| Sizes | logical 173.8 GB · on disk 165.8 GB · reclaimable 164.4 GB |
| APFS sharing seen | 111,062 clone groups and 3,451 hard-linked inodes counted once |
| Unreadable | 520 folders, all `EPERM`: the terminal running the spike has no Full Disk Access (Mail, Safari, `~/.Trash`, many `Containers`). Each is listed, not skipped. |
| Other volumes skipped | 1 (`~/Library/Developer/CoreDevice/DeviceFS`, a mount point) |

Worker count, same scan (cache warm):

| Workers | Wall | CPU | Items/s |
|---|---|---|---|
| 1 | 39.4 s | 17.1 s | 47,000 |
| **2** | **22.8 s** | **22.3 s** | **82,000** |
| 4 | 16.2–17.4 s | 36–41 s | 107,000–115,000 |
| 8 | 17.5 s | 91 s | 107,000 |

More than two workers mostly buys contention inside APFS: four saves a quarter of the wall time for nearly twice the CPU, and eight adds no speed and four times the CPU. The scanner defaults to two.

Each attribute's kernel cost, single-threaded over `~/Library` (171,778 entries, `attrcost.c`): names and types 0.79 s system time. Adding sizes, dates, flags, inode, link count, `EXT_FLAGS`, `LINKID`, `CLONEID` and `CLONE_REFCNT` costs almost nothing more (0.81–0.88 s). **`PRIVATESIZE` is the expensive one**: 1.43 s with the full set, about 70 % more, because APFS has to walk the file's extents. It's what makes the numbers exact, so it stays. A lighter mode could skip it for files without `EF_MAY_SHARE_BLOCKS`, at the cost of not seeing snapshot-held blocks.

### 2. Exact reclaim — PRIVATESIZE predicts statfs to the MiB

`2-exact-reclaim.c`: in a temp folder, write 1 GiB, clone it, delete the copies one at a time, and compare against container free space (`statfs`, polled until stable).

| Step | Free space change | Predicted by scalpel |
|---|---|---|
| Write `a` (1 GiB) | −1024.0 MiB | −1024 MiB |
| Clone `a` → `b` | +0.0 MiB | 0 (both now report `PRIVATESIZE` 0, `CLONE_REFCNT` 2, same `CLONEID`) |
| Delete `b` | −0.0 MiB | 0 (`PRIVATESIZE(b)` was 0); `a` goes back to private 1024 MiB, refcount 1 |
| Clone `a` → `c`, rewrite 128 MiB of `c` | — | `a` and `c` each private 128 MiB; **refcount drops to 1 and `c` gets a new `CLONEID`** |
| Delete `c` | +128.0 MiB | +128 MiB |
| Delete `a` (last copy) | +1024.0 MiB | +1024 MiB |

What it established:

- `PRIVATESIZE` matches the space actually freed to the MiB in every step.
- `CLONE_REFCNT` **counts the file itself**: two full clones each report 2.
- Once a clone diverges at all, it leaves the clone group (refcount 1, new id). The blocks it still shares show up only as a smaller `PRIVATESIZE` on both files. So a folder holding both partial clones reports them as reclaimable at 128 + 128 MiB, though deleting both would free 1,152 MiB. scalpel under-promises here and never over-promises. Its on-disk figure double-counts the shared part.
- Hard links (from the unit tests): every name shares `ATTR_CMN_FILEID` (= `st_ino`) but has its **own `LINKID`**, and every name reports the **full size as `PRIVATESIZE`**. The design's "count each LINKID once" would have double-counted, so scalpel groups by inode instead. It counts the blocks as reclaimable only when every link is inside the folder.

### 3. Duplicate → clone — metadata survives

`3-dup-clone.sh` makes a 64 MiB original and a byte-identical real copy with its own metadata, then runs `talon scalpel dedupe <tmp> --yes`.

| On the copy | Before | After |
|---|---|---|
| Mode | `-rw-------` | `-rw-------` |
| Flags | `hidden` | `hidden` |
| Born / modified | 2020-01-02 03:04:05 / same | 2020-01-02 03:04:05 / same |
| Extended attributes | `com.example.note`, `kMDItemWhereFroms`, `com.apple.provenance` | the same three. The original's `com.example.source` did **not** carry over. |
| Contents | identical | identical (`cmp`) |
| Free space | — | **+63–64 MiB** (`df` rounding) |

The unit test also checks access time, nanosecond modification time, Finder's Date Added (`ATTR_CMN_ADDEDTIME`, which has to be set again after the rename), and that the copy now shares the original's `CLONEID` with refcount 2.

The one thing that changes is the **inode number**. The copy is a new file renamed into place, so an alias or bookmark that resolves by file ID falls back to resolving by path. Nothing else is visible.

### 4. Snapshot-held space — what's measurable without admin

`4-snapshots.sh` only lists. No snapshot was deleted or thinned, and nothing ran with sudo.

- **This Mac has no local Time Machine snapshots right now.** `tmutil listlocalsnapshots /` and `listlocalsnapshotdates /` are empty, and `diskutil apfs listSnapshots` on the Data volume says "No snapshots". The only snapshot is the sealed system volume's OS-update snapshot (not purgeable, never touched).
- Without admin you can **list** snapshots (`tmutil`, `diskutil apfs listSnapshots`) and read the container totals (`diskutil apfs list`: 311.3 GB in use, 183.0 GB not allocated, Data volume 280.8 GB consumed). You **can't** see how much space each snapshot holds: neither tool reports per-snapshot sizes. So the Snapshots finding lists the snapshots with size "unknown", and its owner tool is `tmutil deletelocalsnapshots /`, run only on explicit request.
- Purgeable: `statfs` free is 183.0 GB. Finder's "available" (`volumeAvailableCapacityForImportantUsage`) is 203.1 GB, so about **20 GB is purgeable**, an estimate macOS may or may not honour. `talon scalpel scan` reports the real free space and shows the purgeable figure only as a note.
- Still open: confirming that space comes back after `tmutil deletelocalsnapshots`. That needs a Mac with local snapshots, and deleting them, which this spike doesn't do.

### 5. App leftovers — zero false positives after two fixes

`5-leftovers.sh` runs the matcher over the real `~/Library` (Application Support, Containers, Caches, Preferences, Saved Application State, HTTPStorages, WebKit, Logs) with no size floor, then checks each candidate against Spotlight and `/Applications`. "Installed" means any of these:

- an app, helper, login item, extension, XPC service or plug-in under `/Applications` (including Setapp and Utilities), `~/Applications`, `/System/Applications`, CoreServices, the Homebrew Caskroom, or `/Library/Application Support`;
- a running process;
- an id LaunchServices or Spotlight knows;
- a related id (helper ↔ parent app, or the same vendor).

Anything modified in the last 30 days is skipped, and so is any `com.apple.*` id.

The first run found 19 candidates. Spot-checking them turned up **two false positives**, both now excluded:

- `org.cups.PrintingPrefs` is macOS's own printing system, outside `com.apple.*`.
- `com.segment.storage.oai` is written by the Segment analytics SDK inside the installed ChatGPT.app, under the SDK's own id.

A third, `org.webkit.Playwright`, was ambiguous: it's the Playwright test browser, which lives in `~/Library/Caches/ms-playwright`, out of LaunchServices' sight. scalpel now keeps a short list of system components and SDK vendors that write under their own id from inside other apps (`org.cups`, `org.webkit`, `org.chromium`, `com.segment`, Sparkle, Sentry, Crashlytics, Mixpanel, Amplitude, Keystone, …) and never calls those leftovers. Extensions are folded into their app's finding.

The final run found **10 findings (16 ids)**. Each was checked: no app with the id in Spotlight, `/Applications` or `~/Applications`.

| Leftover | Size | Last written | Where |
|---|---|---|---|
| `com.local.batcave` | 876 KB | 2026-07-20 | WebKit |
| `com.westbridge.stremio5-mac` (Stremio) | 788 KB | 2026-08-03 | Preferences, WebKit |
| `com.electron.wispr-flow` (Wispr Flow) | 364 KB | 2026-10-07 | HTTPStorages, Preferences |
| `com.TickTick.task.mac` + 4 extensions | 128 KB | 2026-10-03 | Containers |
| `net.whatsapp.WhatsApp.Intents` + bridge service | 76 KB | 2026-10-04 | Containers |
| `com.chess.iphone` | 48 KB | 2026-08-12 | Containers |
| `ru.keepcoder.Telegram` + share extension | 44 KB | 2026-07-03 | Containers |
| `com.recorder.screen` | 36 KB | 2026-07-05 | Containers |
| `jp.co.capcom.RE4US` (Resident Evil 4) | 36 KB | 2026-07-25 | Containers |
| `org.mozilla.firefox` | 4 KB | 2026-09-13 | Preferences |

Together these hold only about 2.3 MB. On this Mac, leftovers are about clutter, not space. The containers are small because their `Data` folders are TCC-protected and unreadable without Full Disk Access, so the real sizes may be larger. All are below the CLI's default 1 MB floor (`--min-size 0` shows them). Nothing was removed.

### Also learned

- **`xcrun simctl` installs on first use.** The first `xcrun simctl list` on this Mac printed "Install Started … Install Succeeded": Xcode's first-launch component install. The simulator detector only runs simctl when `~/Library/Developer/CoreSimulator/Devices` exists. Even so, the first scan on a fresh Xcode can trigger the install.
- **Reads update access times.** The Data volume isn't mounted `noatime`, so hashing candidate files for duplicates bumps their access times. The real-home spikes ran with `--no-duplicates` for that reason. For "last used", scalpel prefers Spotlight's `kMDItemLastUsedDate`, which reads don't touch.
- **macOS tags files with `com.apple.provenance`.** Files a process creates get this xattr. Dedupe treats it like any other xattr: the copy keeps its own.
- **On this Mac, everything "safe" is in use.** All 30 safe findings, about 24 GB of DerivedData, SwiftPM `.build`, Cargo `target` and package caches, were touched in the last 14 days. Following principle 5, `talon scalpel clean` leaves recently used caches out of the plan unless free space is under the 60 GB floor or you pass `--include-recent`. It also reports the SSD writes they'd cost: about 32 GB to regenerate 24 GB.
