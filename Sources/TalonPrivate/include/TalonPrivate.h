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

CF_ASSUME_NONNULL_END

#endif
