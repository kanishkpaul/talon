// Thermal pressure, HID temperature sensors, NVMe SMART.

#include "TalonPrivate.h"

#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <string.h>

// MARK: - Thermal pressure

int talon_thermal_pressure(uint64_t *level) {
    static int token;
    static bool ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK;
    });
    if (!ok) return -1;
    return notify_get_state(token, level) == NOTIFY_STATUS_OK ? 0 : -1;
}

// MARK: - HID temperature sensors (private IOHIDEventSystemClient)

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

static IOHIDEventSystemClientRef hid_client(void) {
    static IOHIDEventSystemClientRef client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return;
        int page = 0xff00, usage = 5; // Apple vendor page, temperature sensors
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
        const void *vals[] = {p, u};
        CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match);
        CFRelease(p);
        CFRelease(u);
    });
    return client;
}

CFDictionaryRef talon_copy_temperatures(void) {
    IOHIDEventSystemClientRef client = hid_client();
    if (!client) return NULL;
    CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                           &kCFTypeDictionaryValueCallBacks);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return out;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (ev && name && CFGetTypeID(name) == CFStringGetTypeID()) {
            double t = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
            if (t > 0 && t < 150) {
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &t);
                CFDictionarySetValue(out, name, n);
                CFRelease(n);
            }
        }
        if (ev) CFRelease(ev);
        if (name) CFRelease(name);
    }
    CFRelease(services);
    return out;
}

// MARK: - NVMe SMART

#define kIONVMeSMARTUserClientTypeID                                                                        \
    CFUUIDGetConstantUUIDWithBytes(NULL, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, \
                                   0xA1, 0x32, 0x53, 0x29, 0x2F)
#define kIONVMeSMARTInterfaceID                                                                             \
    CFUUIDGetConstantUUIDWithBytes(NULL, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, \
                                   0x45, 0x4B, 0x23, 0x0A, 0xB6)

typedef struct IONVMeSMARTInterface {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *self, uint8_t *smartLog512);
    IOReturn (*GetIdentifyData)(void *self, uint8_t *identify4096, unsigned int ns);
} IONVMeSMARTInterface;

static uint64_t le64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = v << 8 | p[i];
    return v;
}

int talon_smart_read(talon_smart_t *out) {
    memset(out, 0, sizeof *out);
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it) !=
        KERN_SUCCESS)
        return -1;
    int result = -1;
    io_object_t svc;
    while (result != 0 && (svc = IOIteratorNext(it))) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(svc, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        bool isCapable = capable == kCFBooleanTrue;
        if (capable) CFRelease(capable);
        if (!isCapable) { IOObjectRelease(svc); continue; }

        CFTypeRef chars = IORegistryEntryCreateCFProperty(svc, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
        if (chars && CFGetTypeID(chars) == CFDictionaryGetTypeID()) {
            CFTypeRef model = CFDictionaryGetValue(chars, CFSTR("Product Name"));
            if (model && CFGetTypeID(model) == CFStringGetTypeID())
                CFStringGetCString(model, out->model, sizeof out->model, kCFStringEncodingUTF8);
        }
        if (chars) CFRelease(chars);

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score;
        kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIONVMeSMARTUserClientTypeID,
                                                             kIOCFPlugInInterfaceID, &plugin, &score);
        if (kr != KERN_SUCCESS || !plugin) { result = kr ? kr : -1; IOObjectRelease(svc); continue; }
        IONVMeSMARTInterface **smart = NULL;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
        if (!smart) { result = -1; IODestroyPlugInInterface(plugin); IOObjectRelease(svc); continue; }

        uint8_t log[512] = {0};
        IOReturn r = (*smart)->SMARTReadData(smart, log);
        if (r == kIOReturnSuccess) {
            out->critical_warning = log[0];
            out->temperature_c = (int16_t)((log[1] | log[2] << 8) - 273);
            out->available_spare = log[3];
            out->spare_threshold = log[4];
            out->percent_used = log[5];
            out->data_units_read = le64(log + 32);
            out->data_units_written = le64(log + 48);
            out->power_cycles = le64(log + 112);
            out->power_on_hours = le64(log + 128);
            out->unsafe_shutdowns = le64(log + 144);
            out->media_errors = le64(log + 160);
            result = 0;
        } else {
            result = r;
        }
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return result;
}
