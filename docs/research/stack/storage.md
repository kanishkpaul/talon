# Talon: Local Time-Series Storage (months to years of metrics on a MacBook Air M5)

Scope: a root Swift daemon samples about 700 PIDs at 1 Hz, plus about 60 system series and sparse events. The SwiftUI app and widget read history for 1 h, 24 h, 7 d, 30 d and 1 y views. The goals are low CPU, low RAM and minimal SSD writes.
Research date: 2026-11-08. Sources date from 2024–2026 unless flagged. The Gorilla paper is from 2015, and SQLite's WAL and pragma docs are evergreen reference pages.

**Bottom line for the report writer:** use SQLite through GRDB 7.x, opened as a `DatabasePool` in WAL mode with `synchronous=NORMAL`. The daemon should be the only process that opens the database. Keep the last hour at 1 s resolution in an in-memory ring buffer. Write 10 s, 1 min and 1 h downsampled tiers in batched transactions (one commit every 60 s or more). Store per-app aggregates, not per-PID rows. Serve the app through XPC, and serve the widget through a small snapshot in the App Group container. The estimated physical write volume is about 30–100 MB/day (about 10–35 GB/yr). The naive "every PID, every second, in SQLite" design would write about 4–6 GB/day (about 1.5–2 TB/yr) and could not fit on a 512 GB disk. These estimates are my own arithmetic, shown under Q1. They are not measured.

---

## Q1. Write volume per day, and how to minimize SSD writes

### Takeaway
The deciding variable is schema design, not database choice: per-PID, per-second rows cost gigabytes a day in any row store. Per-app aggregates, a RAM-only 1 s tier and commits batched to at least 60 s cut the physical volume by about 50–100×, to tens of MB/day. SQLite settings (WAL, `synchronous=NORMAL`, checkpoint and journal-size pragmas) then remove the per-commit fsync. They also keep the WAL file bounded.

### Cited Findings
- In WAL mode, a commit appends pages to the WAL file. A checkpoint later copies them into the main database file, so each changed page is written at least twice. By default SQLite checkpoints automatically when the WAL reaches 1000 pages. A checkpoint does not truncate the WAL. SQLite "merely causes SQLite to start overwriting the WAL file from the beginning", unless `journal_size_limit` is set — [SQLite WAL](https://www.sqlite.org/wal.html)
- With `synchronous=NORMAL` in WAL mode, "the checkpoint is the only operation to issue an I/O barrier or sync operation". Writers "omit this sync" on each commit. The trade-off is that a committed transaction "might roll back following a power loss or system crash" — [SQLite WAL](https://www.sqlite.org/wal.html); [SQLite PRAGMA](https://www.sqlite.org/pragma.html)
- SQLite describes `synchronous=NORMAL` as "the best balance between performance and safety for most applications running in WAL mode" — [SQLite PRAGMA](https://www.sqlite.org/pragma.html)
- `journal_size_limit` caps the size of WAL files left behind after checkpoints. The default is -1 (no limit), and 0 always truncates to the minimum. `wal_autocheckpoint` defaults to 1000 pages. The default `page_size` is 4096 bytes. `auto_vacuum=incremental` stores the bookkeeping needed for vacuuming but only reclaims pages when `PRAGMA incremental_vacuum` runs — [SQLite PRAGMA](https://www.sqlite.org/pragma.html)
- The `-shm` wal-index "rarely exceeds 32 KiB in size and is never synced", so it adds no meaningful SSD writes — [SQLite WAL](https://www.sqlite.org/wal.html)
- Compression references for a custom TSDB:
  - Gorilla (Facebook, VLDB 2015, an older source) uses delta-of-delta timestamps and XOR-encoded floats. It averages about 1.37 bytes per point, versus 16 bytes raw (about 12×) — [Gorilla paper (mirror)](https://wwwhtbprolvldbhtbprolorg-s.evpn.library.nenu.edu.cn/pvldb/vol8/p1816-teller.pdf); [Gorilla summary](https://zhenghe.gitbook.io/open-courses/papers-we-love/gorilla-a-fast-scalable-in-memory-time-series-database)
  - Prometheus reports an average of about 1–2 bytes per sample in its storage docs (seen via a commit mirror). Its WAL costs about 13 bytes per sample uncompressed, roughly halved by Snappy, which has been on by default since 2.20 — [Prometheus storage.md mirror](https://forger.sitiv.fr/apitech/prometheus/blame/commit/0e8a2e44a4c54f70d1de052d52bb1304148ddfa5/docs/storage.md); [Robust Perception (older blog)](https://www.robustperception.io/how-much-space-does-the-wal-take-up)
  - Netdata dbengine tier 0 (per-second) samples take 4 bytes uncompressed and about 0.6 bytes on disk. Tier 1 (per-minute) takes 16 bytes uncompressed and about 6 bytes on disk. Tier 2 (per-hour) is listed at 16 bytes uncompressed and "18 bytes" on disk. The 18-byte figure looks inconsistent and should be verified — [Netdata disk & retention](https://learn.netdata.cloud/docs/netdata-agent/resource-utilization/disk-&-retention)

### Inferences (my arithmetic; assumptions stated)

**Volume model.** Assume 700 PIDs × 3 numeric metrics (footprint, CPU time, disk bytes written), with the responsible app stored as an ID. That gives 700 × 86,400 = **60.5 M rows/day**, or **181 M points/day**. Assume about 150 distinct responsible apps after rollup, and about 60 system series: roughly 40 temperatures, 4 cluster clocks, thermal pressure, swap, memory pressure, battery capacity and power, and SMART counters.

**Bytes/day by approach.** The SQLite row sizes are estimates: about 8-byte timestamp and small integer varints, plus a 4–7 byte record header and B-tree cell overhead.

| Approach | Logical bytes/day | Physical writes/day (incl. WAL, checkpoint, page rewrite) | Per year | On-disk size after 1 y |
|---|---|---|---|---|
| A. SQLite, every PID every second (about 40 B/row), commit each second | about 2.4 GB | about 4–6 GB (WAL plus checkpoint, about 2×; partial leaf pages rewritten every commit) | **about 1.5–2.2 TB written** | about 0.9 TB, which does not fit |
| B. Custom Gorilla-style file, every PID every second (1.37 B/pt) | about 250 MB | about 250–300 MB if appended in 64 KiB+ blocks | about 90–110 GB | about 90 GB |
| C. Same as B at Netdata-like 0.6 B/pt | about 110 MB | about 110–130 MB | about 40–50 GB | about 40 GB |
| D. **Recommended tiered SQLite design**, commit every 60 s | about 8–12 MB | **about 30–100 MB** | **about 10–35 GB** | **about 150–350 MB** (with retention) |
| E. Design D, but committing every 1 s | about 8–12 MB | about 350–700 MB (each tiny commit writes at least 1–2 pages of 4 KiB plus a 24 B frame header) | about 130–250 GB | same as D |

- Row E shows why batching matters. A 220-byte row committed every second costs about 4–8 KiB of physical WAL writes, 20–40× write amplification. Batching to 60 s or 300 s commits reduces per-commit page overhead to about 1,440 or 288 page-sets per day.
- APFS copy-on-write metadata and SSD-internal write amplification come on top of every row. I found no source quantifying either for this workload (see Gaps).

**Recommended tier and retention design.** This is the source of row D.

| Tier | Where | Resolution | Content | Retention | Logical size/day |
|---|---|---|---|---|---|
| T0 | Daemon RAM ring buffer (not persisted) | 1 s | ~60 system series as Float32 (about 0.9 MB/h). Per-app (~150 apps × 3 metrics) at 1 s is about 6.5 MB/h, or 0.65 MB/h at 10 s. Per-PID: only the current snapshot plus a short ring (for example 5 min), for the "what's hogging now" view | 1 h | 0 bytes to disk |
| T1 | SQLite `sys_10s` (wide row: ts plus ~60 integer-scaled columns, ~200–250 B) | 10 s | System series | 48 h–7 d | 8,640 rows ≈ 1.9 MB |
| T2a | SQLite `sys_1m` (min/avg/max per series, ~500 B) | 1 min | System series | 90 d | 1,440 rows ≈ 0.7 MB |
| T2b | SQLite `app_1m` (ts, app_id, mem_avg, mem_max, cpu_ms, disk_bytes; ~30–35 B; WITHOUT ROWID PK (ts, app_id)) | 1 min | Only apps that were active in that minute, or top-N (~40) plus an "other" row | 30 d | 40–150 apps × 1,440 ≈ 1.8–7 MB |
| T3 | SQLite `sys_1h`, `app_1h` | 1 h | min/avg/max/sum | Forever (≥1 y) | ≈ 0.15 MB |
| Events | SQLite `event` (ts, kind, app_id, pid, payload JSON) | Irregular | Limit breaches, kills, throttling, panics, plus a top-N per-PID snapshot at event time | Forever | < 0.1 MB typical |

- Steady-state database size is about 4 MB (T1, 48 h) + 63 MB (T2a, 90 d) + 55–200 MB (T2b, 30 d) + about 55 MB/yr (T3) + events. That totals **about 0.2–0.35 GB**.
- **Physical write estimate for D:**
  - About 10 MB of logical rows reach the WAL with about 4–24 KiB of partial-page overhead per commit. At 1,440 commits/day that overhead is 6–35 MB.
  - Checkpoints write about 10–15 MB of distinct pages into the main file.
  - Retention DELETEs dirty a few MB of pages per day, and freed pages are reused.
  - Total: **about 30–60 MB/day**. Budgeting 2× for APFS and FTL overhead gives **about 100 MB/day upper bound, or 35 GB/yr**. At 5-min commits the low end falls to about 20–30 MB/day.
- **Settings to apply:**
  - `journal_mode=WAL` and `synchronous=NORMAL`.
  - `wal_autocheckpoint` at default (1000 pages ≈ 4 MB) or larger, for example 4000. Checkpoints then run a few times a day at most, and pages rewritten within a window are checkpointed once.
  - `journal_size_limit` around 8 MB.
  - `auto_vacuum=INCREMENTAL` with occasional `incremental_vacuum`, or no vacuum at all, since freed pages get reused.
  - `temp_store=MEMORY`.
  - Avoid secondary indexes. Use WITHOUT ROWID tables, or INTEGER PRIMARY KEY = ts, so inserts append at the right edge of one B-tree.
- Store temperatures as INTEGER centi-degrees, power as milliwatts, and memory in KiB or pages. Small integers become 1–3 byte varints, whereas REALs with fractional parts take 8 bytes.
- Downsampling into T1, T2 and T3 happens in daemon memory (running accumulators), not through SQL `INSERT … SELECT` over T1. Each tier is written once, which avoids read-then-rewrite churn.
- Losing up to 60 s of not-yet-committed aggregates on a kernel panic is acceptable for this product. Panic and kill events should be committed immediately (they are rare). A panic is itself an event Talon records after reboot, from panic logs.

### Gaps
- No source gives Apple's rated TBW for the M5 MacBook Air's 512 GB SSD. There is also no measured figure for APFS write amplification on small SQLite WAL appends. Validate with `iostat`, or the daemon's own `proc_pid_rusage` `ri_diskio_byteswritten` on itself, during a 24 h soak test.
- No source gives the actual count of distinct responsible apps on a typical Mac. The 40–150 range is an assumption, so measure it.
- Whether Apple's system SQLite on macOS defaults to `F_FULLFSYNC` or `F_BARRIERFSYNC` for syncs was not verified. It matters for checkpoint cost, not for byte volume.

---

## Q2. Query performance for range queries and downsampled aggregates

### Takeaway
With tiered storage, every history view reads at most about 10k rows from one tier through a clustered primary-key range scan. That is trivially fast in SQLite, with expected single-digit milliseconds, though I found no benchmark to cite. Avoid aggregating raw high-resolution data at query time.

### Cited Findings
- Netdata's model shows the tier-selection pattern. It keeps per-second data for about 14 days, per-minute for about 3 months and per-hour for about 2 years (at about 4,000 metrics/s, 1 GiB per tier). Higher tiers are down-sampled versions of the lower tiers, so long-range charts read the coarse tier — [Netdata disk & retention](https://learn.netdata.cloud/docs/netdata-agent/resource-utilization/disk-&-retention)
- Stats (exelban) keeps per-minute history buckets with snapshot, min, max, average and count for each numeric field. It persists them every 60 s and keeps 24 h of history — [exelban/stats Kit/plugins/DB.swift](https://raw.githubusercontent.com/exelban/stats/master/Kit/plugins/DB.swift)

### Inferences
- **View → tier mapping:**

| View | Tier | Points per series |
|---|---|---|
| 1 h | T0 RAM at 1 s | 3,600 |
| 24 h | T1 at 10 s, or T2 at 1 min | 8,640 or 1,440 |
| 7 d | T2 at 1 min | 10,080, or about 1,000 if bucketed to 10 min with `GROUP BY ts/600` |
| 30 d | T3 hourly (720), or T2 bucketed to 1 h | 720 |
| 1 y | T3 hourly | 8,760, or about 365 if bucketed daily |

  Charts on a roughly 1,000-px-wide widget or window cannot show more than about 1–2k points, so query time is dominated by row decoding, not I/O.
- A range scan on a PK-clustered table (`WHERE ts BETWEEN ? AND ?`) touches about N/rows-per-page leaf pages. That is about 15–20 rows per 4 KiB page for wide system rows and about 120 for app rows. 10k rows is therefore about 100–700 pages, or 0.4–3 MB, mostly in page cache.
- "Top apps over the last 7 d" is `SELECT app_id, SUM(cpu_ms) FROM app_1h WHERE ts>=? GROUP BY app_id`, which scans about 168 × 150 = 25k rows. With 1 y it scans about 1.3 M rows, which may take tens to hundreds of ms. Precompute a daily `app_1d` table if that view is common.
- DuckDB would make the 1 y "top apps" aggregation faster through columnar storage and vectorized execution. At these row counts that advantage does not matter (see Q5).

### Gaps
- I found no 2024–2026 benchmark of SQLite range-scan latency on Apple Silicon at 10⁴–10⁶ rows. The latency figures above are reasoning, not measurement. A 30-minute micro-benchmark in the prototype would settle it.

---

## Q3. Concurrency: one root writer plus app and widget readers; file location and permissions

### Takeaway
Have all reads go through the daemon over XPC. The widget reads a snapshot file in the App Group container that the app (or daemon) writes. Direct multi-process SQLite reading is possible in WAL mode, but it brings `-shm` and `-wal` permission problems with a root-owned file. GRDB observation also cannot see another process's writes, and the widget sandbox blocks access to `/Library/Application Support`. The 1 h live tier lives only in daemon RAM anyway.

### Cited Findings
- **SQLite WAL across processes:**
  - "All processes using a database must be on the same host computer". Shared memory is an mmapped `-shm` file "in the same directory as the database itself".
  - "Writers and readers can run at the same time", but "there can only be one writer at a time".
  - Since 3.22.0, a read-only WAL database can be opened if any of these hold: the `-shm` and `-wal` files already exist and are readable; the directory is writable so the files can be created; or the connection uses `immutable`.

  — [SQLite WAL](https://www.sqlite.org/wal.html)
- If there is "always at least one active reader", checkpoints cannot complete and "the WAL file will grow without bound". Long-lived reader transactions in the app could therefore bloat the WAL — [SQLite WAL](https://www.sqlite.org/wal.html)
- **GRDB's multi-process guidance:**
  - Use `DatabasePool` (WAL), and protect connection creation with `NSFileCoordinator`.
  - Read-only connections need the `-shm` and `-wal` files. Use persistent WAL (`SQLITE_FCNTL_PERSIST_WAL`) so that "the -shm and -wal files are never deleted".
  - Writers should set a busy timeout, and GRDB opens write transactions as IMMEDIATE.
  - Observation "features are not able to detect database changes performed by other processes". Use Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) or `NSFileCoordinator`, and `DatabaseRegionObservation` can trigger these.
  - The guide advises: "Always consider sharing plain files" before sharing a database.

  — [GRDB DatabaseSharing.md](https://raw.githubusercontent.com/groue/GRDB.swift/master/GRDB/Documentation.docc/DatabaseSharing.md)
- GRDB 7.12.0 (1 Nov 2026) "works around an SQLite WAL snapshot bug" and fixes a `SharedValueObservation` deadlock, ordering and cancellation issue — [GRDB releases](https://github.com/groue/GRDB.swift/releases)

### Inferences
- **Recommended topology:**
  1. **Daemon** (root, launchd LaunchDaemon) owns `/Library/Application Support/Talon/talon.sqlite`, with the directory root-owned at 0755 and files at 0644. It opens one GRDB `DatabasePool`: one writer connection plus a reader pool, so XPC queries never block the batch writer.
  2. **XPC service** (`NSXPCConnection` mach service) exposes typed queries such as `series(id, from, to, tier)`, `topApps(range)` and `events(range)`. The daemon merges T0 RAM with on-disk tiers. Payloads are compact arrays (`[Int64]` and `[Float]`), not row objects. A 10k-point series is about 120 KB.
  3. **SwiftUI app** subscribes to the XPC service's live stream for the 1 h view. It uses request/response for the longer views. `ValueObservation` is used only inside the daemon, if anywhere.
  4. **Widget** reads a small JSON/plist snapshot (latest values plus a few downsampled sparklines, a few KB) in the shared App Group container. The app refreshes it, or the daemon writes it to the console user's group container, and then `WidgetCenter.reloadTimelines` is triggered.
- **Why not direct reads:**
  - Root-owned `-shm` and `-wal` files must be readable, and must persist, for a non-root reader. The reader cannot create them in a root-owned directory.
  - A user process reading root's DB means looser permissions on data that may be sensitive (app usage history).
  - GRDB `ValueObservation` would not fire on daemon writes, so you would need Darwin notifications anyway.
  - Long reader transactions can starve checkpoints.
  - Widget extensions are sandboxed and cannot read `/Library/Application Support/Talon` without a temporary-exception entitlement. That last point is from general knowledge of WidgetKit and was not re-verified here.
- If direct reads are still wanted (for example, the app works while the daemon is down), the daemon should:
  - set `SQLITE_FCNTL_PERSIST_WAL`;
  - make the DB, `-wal` and `-shm` files group- or world-readable;
  - checkpoint with `TRUNCATE` sparingly.

  The app should open read-only, keep read transactions short, and listen for a Darwin notification posted after each batch commit.

### Gaps
- I did not verify current (macOS 26/27) rules for a sandboxed widget connecting to a non-app-group mach service, or reading root-owned paths. Treat the widget-snapshot approach as the conservative default.
- I did not verify whether the daemon writing into a per-user `~/Library/Group Containers/<group>` as root triggers TCC or container-ownership issues on recent macOS.

---

## Q4. Maturity and Swift 6 compatibility of GRDB and the alternatives, SwiftData's suitability, and candidate comparison

### Takeaway
GRDB is the clear pick. It is actively maintained (7.12.0 shipped on 1 Nov 2026), built for Swift 6 concurrency, and its multi-process behavior is documented. SwiftData and Core Data are object graphs, not a time-series store, and report slow bulk inserts. Realm is deprecated. DuckDB's single-process write lock rules out direct multi-process access.

### Cited Findings
- **GRDB 7:**
  - 7.0 enabled Swift 6 language mode and has a "Swift Concurrency and GRDB" guide. The announcement calls better integration with Swift 6 concurrency the main reason to upgrade — [Swift Forums: GRDB 7 is out](https://forums.swift.org/t/grdb-7-is-out/77465); [GRDB 7.0.0 release](https://newreleases.io/project/github/groue/GRDB.swift/release/v7.0.0)
  - Release cadence ran 7.6 (Jul) → 7.7 (Sep, Xcode 26 support) → 7.8 (Oct) → 7.9 (Dec, now requiring Swift 6.1+ and Xcode 16.3+) → 7.10 (Feb, Linux/Android/Windows) → 7.11 (Jun) → 7.12.0 (1 Nov 2026) — [GRDB releases](https://github.com/groue/GRDB.swift/releases); [Swift Package Index lists v7.12.0 as latest, updated 1 Nov 2026](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasesharing)
- **SwiftData performance:**
  - Hacking with Swift advises batching saves beyond about 5,000 objects and warns that a context stored as an actor property can make batch inserts "an order of magnitude slower" — [Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftdata/how-to-batch-insert-large-amounts-of-data-efficiently)
  - Apple forum users report 10+ s UI freezes with more than 100k entries. That thread claims custom indexing was unavailable, which is likely outdated (see Inferences) — [Apple Developer Forums 740517](https://developer.apple.com/forums/thread/740517)
  - Others report SwiftUI re-rendering on every insert when importing into the main context — [Apple Developer Forums 782396](https://developer.apple.com/forums/thread/782396)
  - A Swift Forums thread notes that atomic bulk imports mean "reimplement your own journaling on top of SwiftData" — [Swift Forums: Handling large SwiftData import](https://forums.swift.org/t/handling-large-swiftdata-import/83455)
- **Realm:** MongoDB deprecated the Atlas Device SDKs (including Realm Swift) in September 2024, with end-of-life and removal on 30 September 2025. The on-device database "will continue to exist as an open source project", and a community Swift branch without Sync exists — [MongoDB deprecation page](https://www.mongodb.com/docs/atlas/device-sdks/deprecation.md); [MongoDB forum](https://mongodb.com/community/forums/t/deprecation-of-realm-swift-sdk/300126)
- **DuckDB Swift:** The official package is `duckdb/duckdb-swift`, developed inside the main DuckDB repo. Its API is "subject to change between minor version updates" — [duckdb-swift GitHub](https://github.com/duckdb/duckdb-swift); [DuckDB Swift docs](https://duckdb.org/docs/api/swift)

### Inferences
- **Candidate comparison for Talon:**

| Option | Fit for 1 Hz ingest + tiers | Multi-process (root writer, user reader) | Swift 6 / maintenance (late 2026) | Footprint | Verdict |
|---|---|---|---|---|---|
| **SQLite + GRDB 7.12** | Excellent with batched transactions and WITHOUT ROWID tables | WAL: 1 writer plus N readers; documented sharing guide | Active, Swift 6.1+, `Sendable`, async APIs | Uses system SQLite (zero added binary) or the bundled SQLCipher variant | **Recommended** |
| SQLite.swift | Fine | Same SQLite semantics, with no GRDB pool or observation helpers | Maintained, but less active, and Swift 6 strictness is less central (not verified this session) | Small | Acceptable alternative |
| Raw SQLite C API | Best control (prepared statements, `sqlite3_wal_hook`) | Same | Manual `Sendable` wrappers needed | Zero | Viable for the daemon's hot path; a thin wrapper of about 300 lines |
| SwiftData / Core Data | Poor: per-object overhead, change tracking, bulk-insert slowness reported | Core Data needs persistent history tracking for multi-process. SwiftData from a root daemon is awkward | Apple-maintained, but rough edges continue | Framework is free | **Not recommended** for time series. Fine for app settings |
| DuckDB (Swift) | Columnar and great for analytics. Writes are optimized for bulk, not tiny commits | Single read-write process lock (Q5) | API unstable between minors | Tens of MB (Q5) | Not recommended as primary store |
| Custom append-only, Gorilla-style | Best bytes per point (0.6–1.4 B) | You design it (mmap plus a header seqlock) | All custom code | Tiny | Only worth it if per-PID 1 s history must persist. Could be a later optimization for T0 spill |
| libsql / Turso | SQLite-compatible | Not investigated | Not investigated | — | No evidence it adds value for a local single-user app |
| Realm | Object store | — | Deprecated (EOL Sept 2025); community-only | Several MB | **Avoid** |

- SwiftData has offered an `#Index` macro since the macOS 15/iOS 18 cycle (WWDC24), so the forum claim that "custom indexing is not available" is likely outdated. This comes from training knowledge and was not re-fetched in this session.
- A hybrid pattern also deserves a mention: SQLite rows holding compressed blobs (for example, one row per series per hour with Gorilla-encoded deltas). It gives near-TSDB density with SQLite's durability and tooling. It is the right upgrade path if Talon later wants persisted per-PID 1 s history . Even compressed, per-PID 1 s data is about 110–250 MB/day (about 40–90 GB/yr), which is still too much. At 10 s it falls to about 11–25 MB/day, so persisted per-PID data should stay at 10 s or 1 min.

### Gaps
- No search was run on libsql/Turso's 2026 status, its Swift bindings, or the Turso Rust rewrite. It is excluded from the recommendation for lack of evidence, not because of evidence against it.
- SQLite.swift's 2025–2026 release activity and Swift 6 strict-concurrency status were not verified.
- The status of the Realm community branch after September 2025 was not verified.

---

## Q5. DuckDB's fit

### Takeaway
DuckDB is the wrong primary store for Talon:
- **Multi-process:** a native DuckDB file allows one read-write process. Other processes can read only when every process opens it read-only, so a root writer plus app readers needs everything to go through the daemon, or the Quack/DuckLake setups.
- **Write path and stability:** the write path favors bulk appends, and the Swift API is marked unstable.
- **Binary size:** tens of MB, against SQLite's zero added bytes on macOS.

Its analytics advantage is irrelevant at Talon's data size of a few hundred MB.

### Cited Findings
- DuckDB 2.0 docs say multi-process writes to the native format need the Quack remote protocol (client-server), or DuckLake with a PostgreSQL catalog. In read-only mode, "multiple processes can read from the database, but no processes can write" — [DuckDB 2.0 concurrency](https://duckdb.org/docs/2.0/connect/concurrency.html)
- The Swift API was introduced in 2023 and is "subject to change between minor version updates" — [duckdb-swift GitHub](https://github.com/duckdb/duckdb-swift); [Introducing DuckDB for Swift (2023)](https://duckdb.org/2023/04/21/swift)
- The only size data found is a DuckDB 2.1 dev macOS arm64 Python wheel at about 18.4 MB. That is not a reliable proxy for the Swift static library — [PyPI duckdb](https://pypi.org/project/duckdb/2.1.0.dev2610300858/)

### Inferences
- If the daemon is the sole opener and serves XPC, DuckDB's locking is not fatal. It would still add about 15–40 MB to the daemon binary (estimated) and higher RSS. Its columnar row-group checkpointing is tuned for bulk loads rather than a trickle of small commits, and nothing at Talon's scale needs vectorized analytics.
- Possible niche: export history to Parquet or CSV for power users, or run DuckDB in the app on an exported snapshot for ad-hoc analysis.

### Gaps
- No authoritative binary size for duckdb-swift: the DuckDB "footprint" docs page returned 404.
- I did not find DuckDB guidance on small-transaction write amplification.

---

## Q6. How existing tools store history, and which patterns translate

### Takeaway
Every mature monitor uses tiered downsampling, with per-tier min/max/avg/count, a RAM head for recent data and periodic batched flushes. Talon should copy this, using Stats' pattern (1-min buckets, 60 s flush) and Netdata's tiers (1 s → 1 min → 1 h) inside SQLite.

### Cited Findings
- **Stats (exelban):**
  - Uses an `LLDB` wrapper (very likely LevelDB) stored under Application Support.
  - Latest values are written as JSON at most every 30 s, with a 1 h TTL.
  - History is kept as per-minute buckets (snapshot plus min/max/avg/count per numeric field) under keys `history@v2@<key>@<timestamp>`. It is flushed by a 60 s timer, kept for 24 h and pruned at most every 15 min.

  — [exelban/stats DB.swift](https://raw.githubusercontent.com/exelban/stats/master/Kit/plugins/DB.swift). A third-party scan also lists LevelDB as a dependency — [Desktop Insights](https://desktopinsights.com/apps/stats)
- **Netdata dbengine:** tiers at 1 s, 1 min and 1 h, about 0.6, 6 and 18 bytes per sample on disk, default 1 GiB and 14 d / 3 mo / 2 y per tier. Size limits are soft, because whole files are deleted — [Netdata disk & retention](https://learn.netdata.cloud/docs/netdata-agent/resource-utilization/disk-&-retention)
- **Prometheus TSDB:**
  - In-memory head plus a WAL written before samples enter memory.
  - 2-hour blocks compacted to disk at about 1–2 B/sample.
  - Gorilla-style XOR plus delta-of-delta chunks.

  — [Prometheus storage.md mirror](https://forger.sitiv.fr/apitech/prometheus/blame/commit/0e8a2e44a4c54f70d1de052d52bb1304148ddfa5/docs/storage.md); [Prometheus TSDB internals](https://www.youngju.dev/blog/prometheus/prometheus_tsdb_internals.en)
- **Gorilla:**
  - Compresses streaming data in 2-hour blocks to 1.37 B/point.
  - The paper notes that longer blocks give diminishing returns. This is the implementer's reading and was not verified against the paper.

  — [keisku/gorilla README](https://github.com/keisku/gorilla); [Gorilla paper (mirror)](https://wwwhtbprolvldbhtbprolorg-s.evpn.library.nenu.edu.cn/pvldb/vol8/p1816-teller.pdf)
- **Apple PowerLog (PLSQL):**
  - Apple's power diagnostics are SQLite databases (`CurrentPowerlog.PLSQL`) with many tables.
  - Example: `PLAppTimeService_Aggregate_AppRunTime` holds per-app aggregated run time (BundleID, BackgroundTime, ScreenOnTime). This is an iOS-sourced description.

  — [Plaso ios_powerlog parser](https://plaso.readthedocs.io/en/latest/_modules/plaso/parsers/sqlite_plugins/ios_powerlog.html); [EffectivePower viewer](https://github.com/ciphercom/EffectivePower)

### Inferences
- **Patterns that translate to Talon:**
  1. Keep the 1 s head in RAM and flush aggregates in batches (Prometheus head, Stats' 60 s timer).
  2. Store min/max/avg/count per bucket so coarse tiers still show spikes. Temperatures and memory peaks matter for a "preserve your Mac" app.
  3. Keep per-app aggregate tables rather than per-PID ones (Apple PowerLog's `*_Aggregate_*` tables use the same idea, and SQLite is good enough for Apple's own always-on daemon).
  4. Run time-based retention per tier (Netdata).
  5. Write events into a separate, never-downsampled table.
- That Apple uses SQLite for powerlogd, an always-on, root-level, high-frequency system logger, is a strong precedent for SQLite in exactly this role.
- **sar/atop** (not researched this session, general knowledge): both write fixed-interval binary records, sar defaulting to 10 min and atop to 10 min, with daily file rotation. This is the "coarse interval + daily file" pattern. Talon's 10 s/1 min tiers are already finer.

### Gaps
- I found no source on iStat Menus' history storage format, and no confirmed macOS path or schema for powerlogd. `/private/var/db/powerlog/` is the commonly cited location but was not confirmed by a fetched source.
- I did not research sar/atop file formats this session. The intervals above come from general knowledge.
