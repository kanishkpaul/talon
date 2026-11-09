// Spike 6.1b — what does each getattrlistbulk attribute cost the kernel?
// Walks a tree single-threaded (no symlinks, one volume) once per attribute set and reports
// wall time and user/system CPU. Read-only.
// Usage: attrcost <dir>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/vnode.h>
#include <unistd.h>

static char buf[256 << 10];
static uint64_t entries;

typedef struct { const char *label; attrgroup_t cmn, file, ext; } set_t;

static void walk(const char *path, const set_t *s, dev_t dev) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) return;
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | s->cmn;
    al.fileattr = s->file;
    al.forkattr = s->ext;
    char **subs = NULL; size_t nsubs = 0, cap = 0;
    for (;;) {
        int n = getattrlistbulk(fd, &al, buf, sizeof buf, FSOPT_NOFOLLOW | (s->ext ? FSOPT_ATTR_CMN_EXTENDED : 0));
        if (n <= 0) break;
        char *e = buf;
        for (int i = 0; i < n; i++) {
            uint32_t len; memcpy(&len, e, 4);
            char *p = e + 4;
            attribute_set_t got; memcpy(&got, p, sizeof got); p += sizeof got;
            attrreference_t ref; memcpy(&ref, p, sizeof ref);
            const char *name = p + ref.attr_dataoffset; p += sizeof ref;
            dev_t d; memcpy(&d, p, 4); p += 4;
            fsobj_type_t t; memcpy(&t, p, 4);
            entries++;
            if (t == VDIR && d == dev) {
                if (nsubs == cap) { cap = cap ? cap * 2 : 16; subs = realloc(subs, cap * sizeof *subs); }
                size_t l = strlen(path) + strlen(name) + 2;
                subs[nsubs] = malloc(l); snprintf(subs[nsubs++], l, "%s/%s", path, name);
            }
            e += len;
        }
    }
    close(fd);
    for (size_t i = 0; i < nsubs; i++) { walk(subs[i], s, dev); free(subs[i]); }
    free(subs);
}

static double now(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }
static double cpu(int sys) {
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    struct timeval t = sys ? u.ru_stime : u.ru_utime; return t.tv_sec + t.tv_usec / 1e6;
}

int main(int argc, char **argv) {
    const char *root = argc > 1 ? argv[1] : ".";
    struct stat st; if (stat(root, &st)) { perror(root); return 1; }
    set_t sets[] = {
        { "names + type only", 0, 0, 0 },
        { "+ sizes, times, ids (stat-like)", ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID,
          ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE, 0 },
        { "+ EXT_FLAGS + LINKID", ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID,
          ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE, ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_LINKID },
        { "+ CLONEID + CLONE_REFCNT", ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID,
          ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
          ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_LINKID | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT },
        { "+ PRIVATESIZE (scalpel's full set)", ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID,
          ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
          ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_LINKID | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT | ATTR_CMNEXT_PRIVATESIZE },
        { "PRIVATESIZE alone", 0, ATTR_FILE_ALLOCSIZE, ATTR_CMNEXT_PRIVATESIZE },
    };
    walk(root, &sets[0], st.st_dev);  // warm the metadata cache
    for (size_t i = 0; i < sizeof sets / sizeof *sets; i++) {
        entries = 0;
        double w = now(), u = cpu(0), s = cpu(1);
        walk(root, &sets[i], st.st_dev);
        printf("%-38s %8llu entries  wall %6.2f s  user %5.2f s  sys %6.2f s\n", sets[i].label, entries, now() - w, cpu(0) - u, cpu(1) - s);
    }
    return 0;
}
