// Process grouping + kernel memory ceilings. Declarations come from xnu
// (kern_memorystatus.h, spawn_private.h); symbols are resolved at runtime where they are private.

#include "TalonPrivate.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>

// MARK: - Responsible PID

typedef pid_t (*responsible_fn)(pid_t);
static responsible_fn responsible;

static void resolve_responsible(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        responsible = (responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    });
}

bool talon_responsible_available(void) {
    resolve_responsible();
    return responsible != NULL;
}

pid_t talon_responsible_pid(pid_t pid) {
    resolve_responsible();
    if (!responsible) return pid;
    pid_t r = responsible(pid);
    return r > 0 ? r : pid;
}

// MARK: - memorystatus

#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES 7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL 0x1
#define POSIX_SPAWN_JETSAM_MEMLIMIT_ACTIVE_FATAL 0x04
#define POSIX_SPAWN_JETSAM_MEMLIMIT_INACTIVE_FATAL 0x08
#define JETSAM_PRIORITY_DEFAULT 180

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memlimit_props_t;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

int talon_set_memory_limit(pid_t pid, int32_t megabytes) {
    memlimit_props_t p = {megabytes, MEMORYSTATUS_MEMLIMIT_ATTR_FATAL, megabytes, MEMORYSTATUS_MEMLIMIT_ATTR_FATAL};
    return memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &p, sizeof p) == 0 ? 0 : errno;
}

int talon_get_memory_limit(pid_t pid, int32_t *active_mb, int32_t *inactive_mb, bool *fatal) {
    memlimit_props_t p = {0};
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, pid, 0, &p, sizeof p) != 0) return errno;
    *active_mb = p.memlimit_active;
    *inactive_mb = p.memlimit_inactive;
    *fatal = (p.memlimit_active_attr & MEMORYSTATUS_MEMLIMIT_ATTR_FATAL) != 0;
    return 0;
}

// MARK: - Spawn with a ceiling

typedef int (*setjetsam_ext_fn)(posix_spawnattr_t *, short, int, int, int);

int talon_spawn_capped(pid_t *pid, const char *file, char *const argv[], char *const envp[], int32_t megabytes) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    sigset_t defaults, empty;
    sigemptyset(&defaults);
    sigemptyset(&empty);
    int reset[] = {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE};
    for (size_t i = 0; i < sizeof reset / sizeof *reset; i++) sigaddset(&defaults, reset[i]);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &empty);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);

    if (megabytes > 0) {
        setjetsam_ext_fn f = (setjetsam_ext_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_setjetsam_ext");
        if (!f) { posix_spawnattr_destroy(&attr); return -1; }
        f(&attr, POSIX_SPAWN_JETSAM_MEMLIMIT_ACTIVE_FATAL | POSIX_SPAWN_JETSAM_MEMLIMIT_INACTIVE_FATAL,
          JETSAM_PRIORITY_DEFAULT, megabytes, megabytes);
    }
    int rc = posix_spawnp(pid, file, NULL, &attr, argv, envp);
    posix_spawnattr_destroy(&attr);
    return rc;
}
