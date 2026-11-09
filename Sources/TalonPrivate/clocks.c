// Per-cluster CPU clocks from IOReport ("CPU Stats" / "CPU Complex Performance States") — what
// powermetrics reads. Residency in each performance state, weighted by that state's frequency from the
// pmgr voltage tables, gives the average active clock; ÷ max clock is the throttling signal on a
// fanless Mac. Energy channels read zero on macOS 27 and are not used.

#include "TalonPrivate.h"

#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <string.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

#define MAX_TABLES 8
#define MAX_STEPS 32

static struct {
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
    int ntables;
    int steps[MAX_TABLES];
    double mhz[MAX_TABLES][MAX_STEPS];
    bool ok;
} st;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

static void load_tables(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) != KERN_SUCCESS) return;
    io_object_t s;
    while ((s = IOIteratorNext(it))) {
        io_name_t name;
        IORegistryEntryGetName(s, name);
        if (strcmp(name, "pmgr") == 0) {
            CFMutableDictionaryRef props = NULL;
            IORegistryEntryCreateCFProperties(s, &props, NULL, 0);
            if (props) {
                CFIndex n = CFDictionaryGetCount(props);
                const void **keys = calloc((size_t)n, sizeof *keys), **vals = calloc((size_t)n, sizeof *vals);
                CFDictionaryGetKeysAndValues(props, keys, vals);
                for (CFIndex i = 0; i < n && st.ntables < MAX_TABLES; i++) {
                    char k[128];
                    if (!CFStringGetCString(keys[i], k, sizeof k, kCFStringEncodingUTF8)) continue;
                    size_t kl = strlen(k);
                    if (strncmp(k, "voltage-states", 14) != 0 || kl < 5 || strcmp(k + kl - 5, "-sram") != 0) continue;
                    if (CFGetTypeID(vals[i]) != CFDataGetTypeID()) continue;
                    CFDataRef d = vals[i];
                    const uint32_t *v = (const uint32_t *)CFDataGetBytePtr(d);
                    CFIndex pairs = CFDataGetLength(d) / 8;
                    uint32_t maxRaw = 0;
                    for (CFIndex j = 0; j < pairs; j++) if (v[j * 2] > maxRaw) maxRaw = v[j * 2];
                    double scale = maxRaw > 100000000 ? 1e6 : (maxRaw > 100000 ? 1e3 : 1);
                    int t = st.ntables, c = 0;
                    for (CFIndex j = 0; j < pairs && c < MAX_STEPS; j++) if (v[j * 2]) st.mhz[t][c++] = v[j * 2] / scale;
                    st.steps[t] = c;
                    st.ntables++;
                }
                free(keys);
                free(vals);
                CFRelease(props);
            }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
}

static void setup(void) {
    load_tables();
    CFDictionaryRef cpu = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"), 0, 0, 0);
    if (!cpu) return;
    CFMutableDictionaryRef chans = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(cpu), cpu);
    CFRelease(cpu);
    st.sub = IOReportCreateSubscription(NULL, chans, &st.subbed, 0, NULL);
    CFRelease(chans);
    st.ok = st.sub != NULL && st.ntables > 0;
}

static bool inactive(CFStringRef s) {
    return s && (CFStringCompare(s, CFSTR("IDLE"), 0) == kCFCompareEqualTo ||
                 CFStringCompare(s, CFSTR("OFF"), 0) == kCFCompareEqualTo ||
                 CFStringCompare(s, CFSTR("DOWN"), 0) == kCFCompareEqualTo);
}

int talon_clocks_read(talon_cluster_t *out, int max, int *count) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ setup(); });
    *count = 0;
    if (!st.ok) return -1;

    os_unfair_lock_lock(&lock);
    CFDictionaryRef cur = IOReportCreateSamples(st.sub, st.subbed, NULL);
    if (!cur) { os_unfair_lock_unlock(&lock); return -1; }
    if (!st.prev) { st.prev = cur; os_unfair_lock_unlock(&lock); return 0; }  // first call primes
    CFDictionaryRef delta = IOReportCreateSamplesDelta(st.prev, cur, NULL);
    CFRelease(st.prev);
    st.prev = cur;
    os_unfair_lock_unlock(&lock);
    if (!delta) return -1;

    CFArrayRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; channels && i < CFArrayGetCount(channels) && *count < max; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(channels, i);
        CFStringRef name = IOReportChannelGetChannelName(ch);
        char cname[16] = {0};
        if (!name || !CFStringGetCString(name, cname, sizeof cname, kCFStringEncodingUTF8)) continue;
        if (strstr(cname, "_IDLE") || strncmp(cname, "GPU", 3) == 0) continue;
        int32_t n = IOReportStateGetCount(ch);
        int64_t res[MAX_STEPS * 2] = {0};
        int active = 0;
        int64_t total = 0, act = 0;
        for (int32_t s = 0; s < n; s++) {
            int64_t r = IOReportStateGetResidency(ch, s);
            total += r;
            if (!inactive(IOReportStateGetNameForIndex(ch, s)) && active < MAX_STEPS * 2) { res[active++] = r; act += r; }
        }
        if (total == 0) continue;
        int table = -1;  // the frequency table whose length matches the number of active states
        for (int t = 0; t < st.ntables; t++) if (st.steps[t] == active) { table = t; break; }
        if (table < 0) continue;
        double f = 0;
        for (int s = 0; s < active; s++) f += (double)res[s] * st.mhz[table][s];
        talon_cluster_t *c = &out[(*count)++];
        strncpy(c->name, cname, sizeof c->name - 1);
        c->avg_mhz = act ? f / (double)act : 0;
        c->max_mhz = st.mhz[table][st.steps[table] - 1];
        c->busy = (double)act / (double)total;
    }
    CFRelease(delta);
    return 0;
}
