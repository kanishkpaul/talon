// Spike 2 — Can we put a HARD memory ceiling on a process on macOS?
//
// Spawns a "hog" child that keeps allocating (and touching) memory, then tries
// three kernel mechanisms to cap it at LIMIT_MB. A mechanism "works" if the
// kernel kills the hog near the limit instead of letting it reach HOG_MAX_MB.
//
//   A. posix_spawnattr_setjetsam_ext  — limit set at launch (how `cap run` would do it)
//   B. memorystatus_control SET_MEMLIMIT_PROPERTIES — limit on an already-running process
//   C. memorystatus_control SET_JETSAM_TASK_LIMIT   — older single-value variant of B
//
// Run once as yourself and once with sudo to see what needs the admin helper.
// Usage: memcap [limitMB]

#include <dlfcn.h>
#include <libproc.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define HOG_MAX_MB 1500
#define HOG_STEP_MB 25

// --- Private declarations (from xnu: kern_memorystatus.h, spawn_private.h) ---
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT   6
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES 7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL         0x1
#define POSIX_SPAWN_JETSAM_MEMLIMIT_ACTIVE_FATAL   0x04
#define POSIX_SPAWN_JETSAM_MEMLIMIT_INACTIVE_FATAL 0x08
#define JETSAM_PRIORITY_DEFAULT 180

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memlimit_props_t;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
typedef int (*setjetsam_ext_fn)(posix_spawnattr_t *, short, int, int, int);

// --- The hog: allocate + touch memory, report progress on stdout ---
static int hog(void) {
    for (int mb = HOG_STEP_MB; mb <= HOG_MAX_MB; mb += HOG_STEP_MB) {
        volatile char *p = malloc(HOG_STEP_MB << 20);
        if (!p) return 2;
        for (size_t i = 0; i < ((size_t)HOG_STEP_MB << 20); i += 4096) p[i] = (char)(i * 31 + mb); // dirty every page
        printf("%d\n", mb);
        fflush(stdout);
        usleep(60 * 1000);
    }
    return 0;
}

static char self_path[4096];
static char *child_mode = "hog";

// Spawn the hog with stdout piped back to us. If jetsam_limit > 0, use method A.
static pid_t spawn_hog(int *read_fd, int jetsam_limit, int *spawn_err) {
    int fds[2];
    pipe(fds);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    *spawn_err = 0;
    if (jetsam_limit > 0) {
        setjetsam_ext_fn f = (setjetsam_ext_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_setjetsam_ext");
        if (!f) { *spawn_err = -1; return -1; }
        f(&attr, POSIX_SPAWN_JETSAM_MEMLIMIT_ACTIVE_FATAL | POSIX_SPAWN_JETSAM_MEMLIMIT_INACTIVE_FATAL,
          JETSAM_PRIORITY_DEFAULT, jetsam_limit, jetsam_limit);
    }
    pid_t pid;
    char *argv[] = {self_path, child_mode, NULL};
    int rc = posix_spawn(&pid, self_path, &fa, &attr, argv, NULL);
    close(fds[1]);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) { *spawn_err = rc; close(fds[0]); return -1; }
    *read_fd = fds[0];
    return pid;
}

// Read progress until the hog exits; report how far it got and how it died.
static void finish(const char *label, pid_t pid, int fd, int limit) {
    FILE *f = fdopen(fd, "r");
    int mb = 0, last = 0;
    while (fscanf(f, "%d", &mb) == 1) last = mb;
    fclose(f);
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) == 128 + SIGKILL) {
        printf("  %-44s child KILLED after reaching %d MB  → limit is inherited ✅\n", label, last);
    } else if (WIFSIGNALED(status)) {
        int near = last <= limit + HOG_STEP_MB * 2;
        printf("  %-44s KILLED by signal %d after reaching %d MB  → %s\n", label, WTERMSIG(status), last,
               near ? "WORKS ✅" : "killed, but far past the limit ⚠️");
    } else if (limit == 0) {
        printf("  %-44s reached %d MB and exited normally (expected)\n", label, last);
    } else {
        printf("  %-44s NOT capped — hog reached %d MB and exited normally ❌\n", label, last);
    }
}

static void show_props(pid_t pid) {
    memlimit_props_t p = {0};
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, pid, 0, &p, sizeof p) == 0)
        printf("      readback: active %d MB (%s), inactive %d MB (%s)\n", p.memlimit_active,
               p.memlimit_active_attr & 1 ? "fatal" : "soft", p.memlimit_inactive,
               p.memlimit_inactive_attr & 1 ? "fatal" : "soft");
    else
        printf("      readback: GET_MEMLIMIT_PROPERTIES failed (%s)\n", strerror(errno));
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "hog") == 0) return hog();
    if (argc > 1 && strcmp(argv[1], "parent") == 0) { // spawn a hog child (no limit attrs) and wait for it
        uint32_t n = sizeof self_path; _NSGetExecutablePath(self_path, &n);
        pid_t c; char *av[] = {self_path, "hog", NULL};
        posix_spawn(&c, self_path, NULL, NULL, av, NULL);
        int st; waitpid(c, &st, 0);
        return WIFSIGNALED(st) ? 128 + WTERMSIG(st) : WEXITSTATUS(st);
    }
    int limit = argc > 1 ? atoi(argv[1]) : 300;
    uint32_t sz = sizeof self_path;
    _NSGetExecutablePath(self_path, &sz);

    printf("Hard-cap test: limit %d MB, hog grows to %d MB in %d MB steps. Running as uid %d%s.\n\n",
           limit, HOG_MAX_MB, HOG_STEP_MB, getuid(), geteuid() == 0 ? " (root)" : "");

    int fd, err;
    pid_t pid;

    // Baseline: no limit
    pid = spawn_hog(&fd, 0, &err);
    finish("Baseline (no limit)", pid, fd, 0);

    // D: soft cap — Talon's own watchdog polls footprint and kills on breach
    int rates[] = {4, 10};
    for (int r = 0; r < 2; r++) {
        pid = spawn_hog(&fd, 0, &err);
        uint64_t peak = 0;
        for (int t = 0; t < rates[r] * 8; t++) { // give up after 8 s
            struct rusage_info_v4 ri;
            if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) { printf("      rusage: %s (t=%d)\n", strerror(errno), t); break; } // exited
            if (ri.ri_phys_footprint > peak) peak = ri.ri_phys_footprint;
            if (ri.ri_phys_footprint > (uint64_t)limit << 20) { kill(pid, SIGKILL); break; }
            usleep(1000000 / rates[r]);
        }
        char label[64]; snprintf(label, sizeof label, "D. Soft cap: watchdog at %d Hz", rates[r]);
        printf("      (footprint seen by watchdog when it fired: %llu MB)\n", peak >> 20);
        finish(label, pid, fd, limit);
    }

    // A: limit at spawn
    pid = spawn_hog(&fd, limit, &err);
    if (pid < 0) printf("  %-44s spawn failed: %s\n", "A. setjetsam_ext at launch", err == -1 ? "symbol not found" : strerror(err));
    else { show_props(pid); finish("A. setjetsam_ext at launch", pid, fd, limit); }

    // E: does a launch-time limit carry over to child processes?
    child_mode = "parent";
    pid = spawn_hog(&fd, limit, &err);
    if (pid > 0) finish("E. Launch limit, hog is a CHILD process", pid, fd, limit);
    child_mode = "hog";

    // B: SET_MEMLIMIT_PROPERTIES on a running process
    pid = spawn_hog(&fd, 0, &err);
    memlimit_props_t p = {limit, MEMORYSTATUS_MEMLIMIT_ATTR_FATAL, limit, MEMORYSTATUS_MEMLIMIT_ATTR_FATAL};
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &p, sizeof p) != 0) {
        printf("  %-44s call refused: %s\n", "B. SET_MEMLIMIT_PROPERTIES (running proc)", strerror(errno));
        kill(pid, SIGKILL); waitpid(pid, NULL, 0); close(fd);
    } else { show_props(pid); finish("B. SET_MEMLIMIT_PROPERTIES (running proc)", pid, fd, limit); }

    // C: SET_JETSAM_TASK_LIMIT on a running process
    pid = spawn_hog(&fd, 0, &err);
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, pid, (uint32_t)limit, NULL, 0) != 0) {
        printf("  %-44s call refused: %s\n", "C. SET_JETSAM_TASK_LIMIT (running proc)", strerror(errno));
        kill(pid, SIGKILL); waitpid(pid, NULL, 0); close(fd);
    } else { show_props(pid); finish("C. SET_JETSAM_TASK_LIMIT (running proc)", pid, fd, limit); }
    return 0;
}
