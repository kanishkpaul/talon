// Spike 6.2 — exact reclaim. In a fresh temp dir: write 1 GiB, clone it, and compare what
// ATTR_CMNEXT_PRIVATESIZE / CLONE_REFCNT predict with the free space statfs actually reports
// after deleting each copy. Then the same for a clone that has partly diverged. Cleans up after itself.
// Build: clang -O2 -o /tmp/reclaim 2-exact-reclaim.c && /tmp/reclaim
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define GiB (1024LL * 1024 * 1024)
#define MiB (1024LL * 1024)

struct __attribute__((packed)) attrs_t { uint32_t len; attribute_set_t ret; off_t alloc; off_t priv; uint64_t cloneid; uint32_t refcnt; char pad[32]; };

static void attrs(const char *label, const char *path) {
    struct attrlist al = { .bitmapcount = ATTR_BIT_MAP_COUNT };
    al.commonattr = ATTR_CMN_RETURNED_ATTRS;
    al.fileattr = ATTR_FILE_ALLOCSIZE;
    al.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;
    struct attrs_t a = {0};
    if (getattrlist(path, &al, &a, sizeof a, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) { perror(path); return; }
    printf("    %-3s alloc %8.1f MiB  private %8.1f MiB  clone-id %llu  refcnt %u\n", label,
           a.alloc / (double)MiB, a.priv / (double)MiB, a.cloneid, a.refcnt);
}

/// Container free space, after letting APFS settle (frees can land a moment after unlink).
static long long freeBytes(void) {
    struct statfs s;
    long long last = -1;
    for (int i = 0; i < 20; i++) {
        sync();
        statfs(".", &s);
        long long now = (long long)s.f_bfree * s.f_bsize;
        if (now == last) return now;
        last = now;
        usleep(250000);
    }
    return last;
}

static void fill(const char *path, long long bytes) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char *buf = malloc(8 * MiB);
    for (long long done = 0; done < bytes; done += 8 * MiB) { arc4random_buf(buf, 8 * MiB); write(fd, buf, 8 * MiB); }
    fsync(fd); close(fd); free(buf);
}

static void overwrite(const char *path, off_t at, long long bytes) {
    int fd = open(path, O_WRONLY);
    char *buf = malloc(8 * MiB);
    for (long long done = 0; done < bytes; done += 8 * MiB) { arc4random_buf(buf, 8 * MiB); pwrite(fd, buf, 8 * MiB, at + done); }
    fsync(fd); close(fd); free(buf);
}

static void step(const char *what, long long before, long long predicted) {
    long long after = freeBytes();
    printf("  %-44s free %+9.1f MiB   predicted %+9.1f MiB\n", what, (after - before) / (double)MiB, predicted / (double)MiB);
}

int main(void) {
    char dir[] = "/tmp/talon-reclaim-XXXXXX";
    if (!mkdtemp(dir) || chdir(dir)) { perror("mkdtemp"); return 1; }
    printf("in %s\n", dir);

    long long f0 = freeBytes();
    fill("a", GiB);
    step("write a (1 GiB)", f0, -GiB);
    attrs("a", "a");

    long long f1 = freeBytes();
    clonefile("a", "b", 0);
    step("clone a → b", f1, 0);
    attrs("a", "a"); attrs("b", "b");

    long long f2 = freeBytes();
    unlink("b");   // PRIVATESIZE(b) was 0, so ~nothing should come back
    step("delete b (private was 0)", f2, 0);
    attrs("a", "a");

    // Partial divergence: clone again, rewrite 128 MiB in the middle of the clone.
    clonefile("a", "c", 0);
    overwrite("c", 256 * MiB, 128 * MiB);
    printf("  clone a → c, then rewrite 128 MiB of c:\n");
    attrs("a", "a"); attrs("c", "c");

    long long f3 = freeBytes();
    unlink("c");
    step("delete c (diverged 128 MiB)", f3, 128 * MiB);
    attrs("a", "a");

    long long f4 = freeBytes();
    unlink("a");
    step("delete a (last copy)", f4, GiB);

    chdir("/");
    rmdir(dir);
    return 0;
}
