// TalonPrivate — the only place talon touches private Darwin interfaces.
//
// Every entry point degrades instead of crashing: a missing symbol or a refused call
// returns an error code, and the Swift sensor layer turns that into an "unavailable" reading.
// Proven on an M5 MacBook Air, macOS 27 (see spikes/FINDINGS.md).

#ifndef TALON_PRIVATE_H
#define TALON_PRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

CF_ASSUME_NONNULL_BEGIN

// MARK: - Process grouping

/// True when `responsibility_get_pid_responsible_for_pid` resolved at runtime.
bool talon_responsible_available(void);
/// The process macOS holds responsible for `pid` (e.g. Safari for its WebContent helpers).
/// Returns `pid` itself when the private call is unavailable or fails.
pid_t talon_responsible_pid(pid_t pid);

// MARK: - Kernel memory ceilings (memorystatus / jetsam)

/// Fatal kernel memory limit on a running process (SET_MEMLIMIT_PROPERTIES).
/// Needs root for any process but your own children. Returns 0 or an errno.
int talon_set_memory_limit(pid_t pid, int32_t megabytes);

/// Reads back the active / inactive limits. A value <= 0 means "no limit". Returns 0 or an errno.
int talon_get_memory_limit(pid_t pid, int32_t *active_mb, int32_t *inactive_mb, bool *fatal);

/// posix_spawnp with a fatal kernel memory ceiling set at launch (posix_spawnattr_setjetsam_ext).
/// No admin needed. Signals the CLI ignores while waiting (INT, QUIT, TERM, HUP, PIPE) are reset to
/// their defaults in the child. `megabytes <= 0` spawns without a ceiling.
/// Returns 0, an errno from posix_spawn, or -1 if the private setter is missing.
int talon_spawn_capped(pid_t *pid, const char *file, char *_Nullable const argv[_Nonnull],
                       char *_Nullable const envp[_Nonnull], int32_t megabytes);

// MARK: - Thermal

/// macOS's own thermal pressure level: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
/// Returns 0 on success.
int talon_thermal_pressure(uint64_t *level);

/// Every temperature sensor the HID event system exposes, name → °C (CFNumber, double).
/// Calibration sensors (`tcal`) are included; callers filter. NULL if the HID client is unavailable.
CFDictionaryRef _Nullable talon_copy_temperatures(void) CF_RETURNS_RETAINED;

// MARK: - Mach

/// Frees an array returned by host_processor_info (mach_task_self() is a macro Swift can't call).
void talon_vm_deallocate(void *address, size_t size);

// MARK: - CPU clocks (IOReport)

typedef struct {
    char name[16];       // "ECPU", "PCPU", …
    double avg_mhz;      // average clock while active since the previous call
    double max_mhz;      // the cluster's top frequency
    double busy;         // 0…1, share of time not idle
} talon_cluster_t;

/// Per-cluster clocks since the previous call. The first call primes the counters and returns
/// `*count == 0`. Returns 0, or -1 when IOReport or the pmgr frequency tables are unavailable.
int talon_clocks_read(talon_cluster_t *out, int max, int *count);

// MARK: - SSD (NVMe SMART via Apple's IONVMeSMART CFPlugIn)

typedef struct {
    char model[64];
    uint8_t critical_warning;
    int16_t temperature_c;
    uint8_t available_spare;
    uint8_t spare_threshold;
    uint8_t percent_used;          // the wear figure
    uint64_t data_units_read;      // units of 512,000 bytes
    uint64_t data_units_written;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
} talon_smart_t;

/// Reads the SMART log of the first SMART-capable NVMe drive. Returns 0, or a nonzero
/// IOReturn / -1 (no capable drive) on failure.
int talon_smart_read(talon_smart_t *out);

// MARK: - Storage (scalpel)

enum {
    TALON_HAS_FILEID = 1 << 0,
    TALON_HAS_PRIVATESIZE = 1 << 1,
    TALON_HAS_LINKID = 1 << 2,
    TALON_HAS_CLONEID = 1 << 3,
    TALON_HAS_EXTFLAGS = 1 << 4,
    TALON_HAS_CLONEREFCNT = 1 << 5,
};

/// One directory entry as getattrlistbulk returned it, unpacked.
typedef struct {
    uint32_t name_offset;     // byte offset of the NUL-terminated name from the start of the caller's buffer
    uint32_t error;           // ATTR_CMN_ERROR: nonzero when the volume couldn't read this entry's attributes
    uint32_t obj_type;        // VREG, VDIR, VLNK, …
    uint32_t flags;           // st_flags (UF_*, SF_*)
    int32_t dev;
    uint32_t link_count;
    uint32_t mount_status;    // DIR_MNTSTATUS_* (directories)
    uint32_t clone_refcnt;    // ATTR_CMNEXT_CLONE_REFCNT
    uint32_t has;             // TALON_HAS_* — which optional attributes the volume returned
    uint32_t reserved;
    uint64_t file_id;
    uint64_t link_id;
    uint64_t clone_id;
    uint64_t ext_flags;       // EF_* (EF_MAY_SHARE_BLOCKS, EF_SHARES_ALL_BLOCKS, …)
    int64_t mtime;
    int64_t atime;
    uint64_t logical;         // ATTR_FILE_TOTALSIZE
    uint64_t allocated;       // ATTR_FILE_ALLOCSIZE
    uint64_t private_size;    // ATTR_CMNEXT_PRIVATESIZE: bytes freed if this file alone were deleted
} talon_dirent_t;

/// One getattrlistbulk(2) call on an open directory. Fills `out` (capacity >= size / 32 is always enough)
/// and returns the entry count, 0 at the end of the directory, or -errno.
int talon_bulk_read(int dirfd, void *buffer, size_t size, talon_dirent_t *out, int capacity);

/// The same attributes for one path (never following a final symlink). Returns 0 or an errno.
int talon_stat_entry(const char *path, void *buffer, size_t size, talon_dirent_t *out);

/// Sets birth, modification and access times (never following a final symlink). Returns 0 or an errno.
int talon_set_times(const char *path, int64_t created, int64_t created_ns, int64_t modified, int64_t modified_ns,
                    int64_t accessed, int64_t accessed_ns);

/// Finder's "Date Added" (ATTR_CMN_ADDEDTIME). Return 0 or an errno (ENOATTR when the volume has none).
int talon_get_added_time(const char *path, int64_t *seconds, int64_t *nanoseconds);
int talon_set_added_time(const char *path, int64_t seconds, int64_t nanoseconds);

/// 1 if `pid` has a file open at or below `prefix` (or its working directory there), copying that path
/// into `found`; 0 if not; -1 if the process can't be inspected.
int talon_pid_holds_path(pid_t pid, const char *prefix, char *found, size_t found_size);

CF_ASSUME_NONNULL_END

#endif
