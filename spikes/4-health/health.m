// Spike 4 — Can we read SSD wear and battery health directly (no smartctl, no admin)?
//
//   SSD:     NVMe SMART log via Apple's private IONVMeSMART CFPlugIn (what smartmontools uses)
//   Battery: AppleSmartBattery in the IORegistry, incl. live system power draw

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>

// ---------- Private: NVMe SMART plug-in ----------
#define kIONVMeSMARTUserClientTypeID CFUUIDGetConstantUUIDWithBytes(NULL, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
#define kIONVMeSMARTInterfaceID      CFUUIDGetConstantUUIDWithBytes(NULL, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

typedef struct IONVMeSMARTInterface {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *self, uint8_t *smartLog512);
    IOReturn (*GetIdentifyData)(void *self, uint8_t *identify4096, unsigned int ns);
} IONVMeSMARTInterface;

static uint64_t le64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }

static void readSSD(void) {
    printf("SSD (NVMe SMART)\n");
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it);
    io_object_t svc;
    BOOL found = NO;
    while ((svc = IOIteratorNext(it))) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(svc, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        if (capable != kCFBooleanTrue) { if (capable) CFRelease(capable); IOObjectRelease(svc); continue; }
        CFRelease(capable);
        found = YES;
        NSDictionary *chars = CFBridgingRelease(IORegistryEntryCreateCFProperty(svc, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0));
        printf("  Drive:                 %s\n", [chars[@"Product Name"] UTF8String] ?: "?");

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score;
        kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        if (kr != KERN_SUCCESS || !plugin) { printf("  ❌ plug-in failed: 0x%x\n", kr); IOObjectRelease(svc); continue; }
        IONVMeSMARTInterface **smart = NULL;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
        if (!smart) { printf("  ❌ QueryInterface failed\n"); IODestroyPlugInInterface(plugin); IOObjectRelease(svc); continue; }

        uint8_t log[512] = {0};
        IOReturn r = (*smart)->SMARTReadData(smart, log);
        if (r != kIOReturnSuccess) {
            printf("  ❌ SMARTReadData failed: 0x%x\n", r);
        } else {
            double tbW = le64(log + 48) * 512000.0 / 1e12, tbR = le64(log + 32) * 512000.0 / 1e12;
            printf("  Critical warning:      0x%02x %s\n", log[0], log[0] ? "⚠️" : "(none)");
            printf("  Temperature:           %d °C\n", (log[1] | log[2] << 8) - 273);
            printf("  Wear (percent used):   %d %%   ← main SSD lifespan number\n", log[5]);
            printf("  Available spare:       %d %% (threshold %d %%)\n", log[3], log[4]);
            printf("  Data written / read:   %.2f TB / %.2f TB\n", tbW, tbR);
            printf("  Power-on hours:        %llu\n", le64(log + 128));
            printf("  Power cycles:          %llu\n", le64(log + 112));
            printf("  Unsafe shutdowns:      %llu\n", le64(log + 144));
            printf("  Media errors:          %llu\n", le64(log + 160));
        }
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (!found) printf("  ❌ no NVMe SMART-capable device found\n");
}

static void readBattery(void) {
    printf("\nBattery (AppleSmartBattery)\n");
    io_service_t b = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!b) { printf("  ❌ not found\n"); return; }
    CFMutableDictionaryRef cf = NULL;
    IORegistryEntryCreateCFProperties(b, &cf, kCFAllocatorDefault, 0);
    NSDictionary *p = CFBridgingRelease(cf);
    IOObjectRelease(b);

    // macOS 27: capacities live in the BatteryData sub-dictionary (top-level values read 0)
    NSDictionary *bd = p[@"BatteryData"];
    double design = [bd[@"DesignCapacity"] doubleValue], nominal = [bd[@"NominalChargeCapacity"] doubleValue];
    double full = [bd[@"FullChargeCapacity"] doubleValue];
    printf("  Cycle count:           %ld (design life ~1000)\n", (long)[p[@"CycleCount"] integerValue]);
    printf("  Design capacity:       %.0f mAh\n", design);
    printf("  Nominal capacity now:  %.0f mAh  → %.1f %% of design\n", nominal, design ? 100 * nominal / design : 0);
    printf("  Full-charge capacity:  %.0f mAh  → %.1f %% of design (temperature-compensated)\n", full, design ? 100 * full / design : 0);
    printf("  Charge:                %ld %%  %s%s\n", (long)[p[@"CurrentCapacity"] integerValue],
           [p[@"ExternalConnected"] boolValue] ? "plugged in" : "on battery",
           [p[@"IsCharging"] boolValue] ? ", charging" : "");
    printf("  Voltage / current:     %.2f V / %ld mA\n", [p[@"Voltage"] doubleValue] / 1000, (long)[p[@"InstantAmperage"] integerValue]);
    NSDictionary *tele = p[@"PowerTelemetryData"];
    if (tele) {
        printf("  System power draw:     %.2f W", [tele[@"SystemLoad"] doubleValue] / 1000);
        if (tele[@"SystemPowerIn"]) printf("   (from charger: %.2f W)", [tele[@"SystemPowerIn"] doubleValue] / 1000);
        printf("\n");
    } else {
        printf("  System power draw:     PowerTelemetryData not present\n");
    }
    NSArray *interesting = @[@"ChargerData", @"BatteryData", @"PowerTelemetryData"];
    for (NSString *k in interesting) {
        id v = p[k];
        if ([v isKindOfClass:NSDictionary.class])
            printf("  [%s keys] %s\n", k.UTF8String, [[[v allKeys] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "].UTF8String);
    }
}

int main(void) {
    @autoreleasepool {
        readSSD();
        readBattery();
    }
    return 0;
}
