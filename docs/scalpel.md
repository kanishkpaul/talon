# scalpel — surgical storage analysis and cleanup

Part of talon. Status: **planned** (design + spike list; no code yet).

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
| **Hard links** | One file with many names gets counted many times. | Count each `ATTR_CMNEXT_LINKID` once. |
| **Firmlinks / volume group** | `/` and `/System/Volumes/Data` show the same data twice. | Walk the Data volume and use `ATTR_CMNEXT_NOFIRMLINKPATH` for display. |
| **Snapshots & purgeable** | Deleted files can stay on disk inside local Time Machine snapshots; "purgeable" space is only an estimate. | Show snapshot-held space separately (`tmutil`). Report the container's real free space, not the purgeable total. |

The result for any folder is three numbers: **logical size** (what Finder shows), **on-disk size**, and **reclaimable** (what you'd actually get back). The reclaimable number drives every decision.

Scanning uses `getattrlistbulk(2)`, which fetches all attributes for a whole directory in one call. The target is a full home-folder scan in seconds, with no measurable effect on the rest of the system.

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
  talon scalpel holding                    # list / restore / purge
  ```

## Where it runs

The scan runs **as you**, in the app or CLI, not in `talond`. Your files don't need root access, and keeping the root helper's job small keeps it safe. scalpel needs Full Disk Access to see everything; without it, it says which folders it couldn't read instead of under-reporting.

## Spikes before building

1. **Scan speed.** `getattrlistbulk` over the whole home folder: time taken, CPU used, and whether it disturbs the 1 Hz sampler.
2. **Exact reclaim.** Clone a 1 GB file, then compare `PRIVATESIZE` and `CLONE_REFCNT` with the free space actually recovered after deleting each copy.
3. **Duplicate → clone.** Use `clonefile(2)` to replace a duplicate with a clone, and confirm the metadata and extended attributes survive.
4. **Snapshot-held space.** Measure how much space local snapshots hold, and that it's released after `tmutil deletelocalsnapshots`.
5. **App leftovers.** Match leftover folders to installed apps by bundle ID, with no false positives, across `/Applications`, `~/Applications`, and Setapp / Homebrew casks.
