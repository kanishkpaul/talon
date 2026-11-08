// Spike 3 — On a fanless MacBook Air, can we see heat and heat-throttling without admin?
//
//   1. Thermal pressure level (what macOS itself thinks: nominal → critical)
//   2. Temperature sensors (private IOHIDEventSystemClient)
//   3. CPU/GPU clock speeds + power (private IOReport, what `powermetrics` uses)
//      → under load, "average clock vs max clock" is the throttling signal.
//
// Runs 3 s idle, then N s (default 6) with every core busy, sampling once a second.
// Usage: thermal [loadSeconds]   e.g. `thermal 300` to watch a fanless Mac start throttling.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <notify.h>
#include <pthread.h>
#include <stdatomic.h>

// ---------- Private: IOHID temperature sensors ----------
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kIOHIDEventTypeTemperature 15

static IOHIDEventSystemClientRef hidClient;

static NSDictionary<NSString *, NSNumber *> *readTemps(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    CFArrayRef services = IOHIDEventSystemClientCopyServices(hidClient);
    if (!services) return out;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(sc, CFSTR("Product")));
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev || !name) { if (ev) CFRelease(ev); continue; }
        double t = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
        CFRelease(ev);
        if (t > 0 && t < 150) out[name] = @(t);
    }
    CFRelease(services);
    return out;
}

// ---------- Private: IOReport (clocks + energy) ----------
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);

// Frequency tables from the power manager node in the IORegistry: key → [MHz]
static NSDictionary<NSString *, NSArray<NSNumber *> *> *freqTables(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) != KERN_SUCCESS) return out;
    io_object_t s;
    while ((s = IOIteratorNext(it))) {
        io_name_t name;
        IORegistryEntryGetName(s, name);
        if (strcmp(name, "pmgr") == 0) {
            CFMutableDictionaryRef props = NULL;
            IORegistryEntryCreateCFProperties(s, &props, NULL, 0);
            for (NSString *k in (__bridge NSDictionary *)props) {
                if (![k hasPrefix:@"voltage-states"] || ![k hasSuffix:@"-sram"]) continue;
                NSData *d = ((__bridge NSDictionary *)props)[k];
                const uint32_t *v = d.bytes;
                NSUInteger n = d.length / 8;
                uint32_t maxRaw = 0;
                for (NSUInteger i = 0; i < n; i++) maxRaw = MAX(maxRaw, v[i * 2]);
                double scale = maxRaw > 100000000 ? 1e6 : (maxRaw > 100000 ? 1e3 : 1); // Hz or kHz → MHz
                NSMutableArray *mhz = [NSMutableArray array];
                for (NSUInteger i = 0; i < n; i++) if (v[i * 2]) [mhz addObject:@(v[i * 2] / scale)];
                out[k] = mhz;
            }
            if (props) CFRelease(props);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return out;
}

static BOOL isInactiveState(NSString *s) {
    return [s isEqualToString:@"IDLE"] || [s isEqualToString:@"OFF"] || [s isEqualToString:@"DOWN"];
}

// ---------- Load generator ----------
static atomic_bool burn = false;
static void *burner(void *arg) {
    volatile double x = 1;
    for (;;) { if (atomic_load(&burn)) for (int i = 0; i < 1000000; i++) x = x * 1.0000001 + 1e-9; else usleep(10000); }
    return NULL;
}

int main(int argc, char **argv) {
    int loadSecs = argc > 1 ? atoi(argv[1]) : 6;
    @autoreleasepool {
        // 1. Thermal pressure
        int token;
        BOOL notifyOK = notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK;
        NSArray *pressureNames = @[@"nominal", @"moderate", @"heavy", @"trapping", @"sleeping"];

        // 2. Temperatures
        hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        IOHIDEventSystemClientSetMatching(hidClient, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5});
        NSDictionary *t0 = readTemps();

        // 3. IOReport
        NSDictionary *tables = freqTables();
        CFDictionaryRef energy = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
        CFDictionaryRef cpu = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"), 0, 0, 0);
        CFDictionaryRef gpu = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
        BOOL ioreportOK = energy && cpu;
        CFMutableDictionaryRef chans = NULL, subbed = NULL;
        IOReportSubscriptionRef sub = NULL;
        if (ioreportOK) {
            if (cpu) IOReportMergeChannels(energy, cpu, NULL);
            if (gpu) IOReportMergeChannels(energy, gpu, NULL);
            chans = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(energy), energy);
            sub = IOReportCreateSubscription(NULL, chans, &subbed, 0, NULL);
            ioreportOK = sub != NULL;
        }

        printf("Thermal pressure API:  %s\n", notifyOK ? "available" : "NOT available");
        printf("Thermal state (public): %ld (0 nominal … 3 critical)\n", (long)NSProcessInfo.processInfo.thermalState);
        printf("Temperature sensors:   %lu found\n", (unsigned long)t0.count);
        for (NSString *k in [t0.allKeys sortedArrayUsingSelector:@selector(compare:)])
            printf("    %-28s %5.1f °C\n", k.UTF8String, [t0[k] doubleValue]);
        printf("Clock/power (IOReport): %s\n", ioreportOK ? "available" : "NOT available");
        for (NSString *k in [tables.allKeys sortedArrayUsingSelector:@selector(compare:)])
            printf("    freq table %-24s %2lu steps, max %4.0f MHz\n", k.UTF8String, (unsigned long)[tables[k] count], [[tables[k] valueForKeyPath:@"@max.self"] doubleValue]);

        int ncpu = (int)NSProcessInfo.processInfo.activeProcessorCount;
        for (int i = 0; i < ncpu; i++) { pthread_t th; pthread_create(&th, NULL, burner, NULL); }

        printf("\n  t   load   pressure   hottest sensor        clusters (avg active clock / max MHz · busy %%)\n");
        CFDictionaryRef prev = ioreportOK ? IOReportCreateSamples(sub, subbed, NULL) : NULL;
        for (int s = 1; s <= 3 + loadSecs; s++) {
            atomic_store(&burn, s > 3);
            sleep(1);
            uint64_t pl = 0;
            if (notifyOK) notify_get_state(token, &pl);
            NSDictionary *temps = readTemps();
            NSString *hotK = nil; double hot = 0;
            for (NSString *k in temps) if (![k hasSuffix:@"tcal"] && [temps[k] doubleValue] > hot) { hot = [temps[k] doubleValue]; hotK = k; }

            NSMutableString *clusters = [NSMutableString string];
            double cpuW = 0, gpuW = 0;
            if (ioreportOK) {
                CFDictionaryRef cur = IOReportCreateSamples(sub, subbed, NULL);
                CFDictionaryRef delta = IOReportCreateSamplesDelta(prev, cur, NULL);
                CFRelease(prev); prev = cur;
                for (id chObj in ((__bridge NSDictionary *)delta)[@"IOReportChannels"]) {
                    CFDictionaryRef ch = (__bridge CFDictionaryRef)chObj;
                    NSString *group = (__bridge NSString *)IOReportChannelGetGroup(ch);
                    NSString *name = (__bridge NSString *)IOReportChannelGetChannelName(ch);
                    if ([group isEqualToString:@"Energy Model"]) {
                        NSString *unit = (__bridge NSString *)IOReportChannelGetUnitLabel(ch);
                        double div = [unit isEqualToString:@"nJ"] ? 1e9 : [unit isEqualToString:@"uJ"] ? 1e6 : 1e3;
                        double w = IOReportSimpleGetIntegerValue(ch, 0) / div;
                        if ([name hasSuffix:@"CPU Energy"]) cpuW += w;
                        else if ([name isEqualToString:@"GPU Energy"] || [name isEqualToString:@"GPU"]) gpuW += w;
                        continue;
                    }
                    if ([name hasSuffix:@"_IDLE"] || [name hasPrefix:@"GPU"]) continue; // GPU clock table doesn't match on M5
                    // Performance-state channel: weight each active state's residency by its clock
                    int32_t n = IOReportStateGetCount(ch);
                    NSMutableArray *active = [NSMutableArray array];
                    int64_t total = 0, act = 0;
                    for (int32_t i = 0; i < n; i++) {
                        int64_t r = IOReportStateGetResidency(ch, i);
                        total += r;
                        if (!isInactiveState((__bridge NSString *)IOReportStateGetNameForIndex(ch, i))) { [active addObject:@(r)]; act += r; }
                    }
                    if (total == 0) continue;
                    NSArray *table = nil; // pick the frequency table whose length matches the active states
                    for (NSString *k in tables) if ([tables[k] count] == active.count) { table = tables[k]; break; }
                    if (table) {
                        double f = 0;
                        for (NSUInteger i = 0; i < active.count; i++) f += [active[i] doubleValue] * [table[i] doubleValue];
                        double avg = act ? f / act : 0, mx = [[table lastObject] doubleValue];
                        [clusters appendFormat:@"%@ %4.0f/%4.0f·%3.0f%%  ", name, avg, mx, 100.0 * act / total];
                    } else {
                        [clusters appendFormat:@"%@ ?(%lu states)·%3.0f%%  ", name, (unsigned long)active.count, 100.0 * act / total];
                    }
                }
                CFRelease(delta);
            }
            printf("%3ds  %-5s  %-9s  %-18s %5.1f°  %s\n", s, s > 3 ? "FULL" : "idle",
                   notifyOK ? [pressureNames[MIN(pl, 4)] UTF8String] : "?", hotK ? [hotK substringToIndex:MIN(18, hotK.length)].UTF8String : "-",
                   hot, clusters.UTF8String);
        }
        atomic_store(&burn, false);
    }
    return 0;
}
