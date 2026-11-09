// scalpel's filesystem primitives: getattrlistbulk parsing, metadata copy for clone-replace,
// and open-file lookup. The attribute buffer's packing rules (4-byte alignment, attributes
// present only when returned, extended-common attributes packed last) are easy to get wrong
// from Swift, so the parse lives here and hands Swift a flat struct per entry.

#include "TalonPrivate.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/proc_info.h>
#include <sys/vnode.h>
#include <unistd.h>

// MARK: - Bulk directory reads

static void request(struct attrlist *al) {
    memset(al, 0, sizeof(*al));
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE
                   | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
    al->dirattr = ATTR_DIR_LINKCOUNT | ATTR_DIR_MOUNTSTATUS;
    al->fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    // With FSOPT_ATTR_CMN_EXTENDED the fork slot carries the extended common attributes.
    al->forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_LINKID | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS
                 | ATTR_CMNEXT_CLONE_REFCNT;
}

#define TAKE(dst) do { memcpy(&(dst), p, sizeof(dst)); p += (sizeof(dst) + 3) & ~(size_t)3; } while (0)

/// Parses one packed entry starting at its length word. `base` is where name offsets are measured from.
static void parse_entry(const char *entry, const char *base, talon_dirent_t *e) {
    memset(e, 0, sizeof(*e));
    const char *p = entry + sizeof(uint32_t);
    attribute_set_t got;
    memcpy(&got, p, sizeof(got));
    p += sizeof(got);

    if (got.commonattr & ATTR_CMN_ERROR) TAKE(e->error);
    if (got.commonattr & ATTR_CMN_NAME) {
        attrreference_t ref;
        memcpy(&ref, p, sizeof(ref));
        e->name_offset = (uint32_t)((p + ref.attr_dataoffset) - base);
        p += sizeof(ref);
    } else {
        e->name_offset = UINT32_MAX;
    }
    if (got.commonattr & ATTR_CMN_DEVID) TAKE(e->dev);
    if (got.commonattr & ATTR_CMN_OBJTYPE) TAKE(e->obj_type);
    if (got.commonattr & ATTR_CMN_MODTIME) { struct timespec t; TAKE(t); e->mtime = t.tv_sec; }
    if (got.commonattr & ATTR_CMN_ACCTIME) { struct timespec t; TAKE(t); e->atime = t.tv_sec; }
    if (got.commonattr & ATTR_CMN_FLAGS) TAKE(e->flags);
    if (got.commonattr & ATTR_CMN_FILEID) { TAKE(e->file_id); e->has |= TALON_HAS_FILEID; }

    if (got.dirattr & ATTR_DIR_LINKCOUNT) TAKE(e->link_count);
    if (got.dirattr & ATTR_DIR_MOUNTSTATUS) TAKE(e->mount_status);

    if (got.fileattr & ATTR_FILE_LINKCOUNT) TAKE(e->link_count);
    if (got.fileattr & ATTR_FILE_TOTALSIZE) { off_t v; TAKE(v); e->logical = (uint64_t)v; }
    if (got.fileattr & ATTR_FILE_ALLOCSIZE) { off_t v; TAKE(v); e->allocated = (uint64_t)v; }

    if (got.forkattr & ATTR_CMNEXT_PRIVATESIZE) { off_t v; TAKE(v); e->private_size = (uint64_t)v; e->has |= TALON_HAS_PRIVATESIZE; }
    if (got.forkattr & ATTR_CMNEXT_LINKID) { TAKE(e->link_id); e->has |= TALON_HAS_LINKID; }
    if (got.forkattr & ATTR_CMNEXT_CLONEID) { TAKE(e->clone_id); e->has |= TALON_HAS_CLONEID; }
    if (got.forkattr & ATTR_CMNEXT_EXT_FLAGS) { TAKE(e->ext_flags); e->has |= TALON_HAS_EXTFLAGS; }
    if (got.forkattr & ATTR_CMNEXT_CLONE_REFCNT) { TAKE(e->clone_refcnt); e->has |= TALON_HAS_CLONEREFCNT; }
}

int talon_bulk_read(int dirfd, void *buffer, size_t size, talon_dirent_t *out, int capacity) {
    struct attrlist al;
    request(&al);
    int n = getattrlistbulk(dirfd, &al, buffer, size, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED);
    if (n < 0) return -errno;
    if (n > capacity) return -ENOBUFS;  // caller sized `out` too small for `buffer`
    const char *entry = buffer;
    for (int i = 0; i < n; i++) {
        uint32_t length;
        memcpy(&length, entry, sizeof(length));
        parse_entry(entry, buffer, &out[i]);
        entry += length;
    }
    return n;
}

int talon_stat_entry(const char *path, void *buffer, size_t size, talon_dirent_t *out) {
    struct attrlist al;
    request(&al);
    al.commonattr &= ~(attrgroup_t)ATTR_CMN_ERROR;  // bulk-only
    if (getattrlist(path, &al, buffer, size, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) != 0) return errno;
    parse_entry(buffer, buffer, out);
    return 0;
}

// MARK: - Dates for clone-replace

int talon_set_times(const char *path, int64_t created, int64_t created_ns, int64_t modified, int64_t modified_ns,
                    int64_t accessed, int64_t accessed_ns) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME;
    struct timespec times[3] = {
        { .tv_sec = created, .tv_nsec = created_ns },
        { .tv_sec = modified, .tv_nsec = modified_ns },
        { .tv_sec = accessed, .tv_nsec = accessed_ns },
    };
    return setattrlist(path, &al, times, sizeof(times), FSOPT_NOFOLLOW) == 0 ? 0 : errno;
}

int talon_get_added_time(const char *path, int64_t *seconds, int64_t *nanoseconds) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ADDEDTIME;
    struct __attribute__((packed)) { uint32_t length; attribute_set_t got; struct timespec added; } buf;
    memset(&buf, 0, sizeof(buf));
    if (getattrlist(path, &al, &buf, sizeof(buf), FSOPT_NOFOLLOW) != 0) return errno;
    if (!(buf.got.commonattr & ATTR_CMN_ADDEDTIME)) return ENOATTR;
    *seconds = buf.added.tv_sec;
    *nanoseconds = buf.added.tv_nsec;
    return 0;
}

int talon_set_added_time(const char *path, int64_t seconds, int64_t nanoseconds) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_ADDEDTIME;
    struct timespec t = { .tv_sec = seconds, .tv_nsec = nanoseconds };
    return setattrlist(path, &al, &t, sizeof(t), FSOPT_NOFOLLOW) == 0 ? 0 : errno;
}

// MARK: - Open files

int talon_pid_holds_path(pid_t pid, const char *prefix, char *found, size_t found_size) {
    size_t plen = strlen(prefix);
    #define MATCHES(p) (strncmp((p), prefix, plen) == 0 && ((p)[plen] == '\0' || (p)[plen] == '/'))

    // The working directory counts: a shell sitting inside the folder would be stranded.
    struct proc_vnodepathinfo vpi;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi)) == (int)sizeof(vpi)) {
        if (MATCHES(vpi.pvi_cdir.vip_path)) { strlcpy(found, vpi.pvi_cdir.vip_path, found_size); return 1; }
    }

    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return bytes < 0 ? -1 : 0;
    struct proc_fdinfo *fds = malloc((size_t)bytes);
    if (!fds) return -1;
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    int result = bytes > 0 ? 0 : -1;
    int count = bytes > 0 ? bytes / (int)sizeof(struct proc_fdinfo) : 0;
    for (int i = 0; i < count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath info;
        int got = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info));
        if (got != (int)sizeof(info)) continue;
        if (MATCHES(info.pvip.vip_path)) { strlcpy(found, info.pvip.vip_path, found_size); result = 1; break; }
    }
    free(fds);
    return result;
    #undef MATCHES
}
