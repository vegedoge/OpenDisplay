#import "BrightnessHelper.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <dlfcn.h>

// MARK: - CoreDisplay private API (built-in display brightness)

typedef double (*CD_GetBrightnessFn)(CGDirectDisplayID);
typedef void   (*CD_SetBrightnessFn)(CGDirectDisplayID, double);

static CD_GetBrightnessFn _cdGetBrightness;
static CD_SetBrightnessFn _cdSetBrightness;

// MARK: - IOAVService (DDC/CI for external displays on Apple Silicon)

#if __arm64__
typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*IOAVServiceCreateWithServiceFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVServiceReadI2CFn)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*IOAVServiceWriteI2CFn)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static IOAVServiceCreateWithServiceFn _avCreate;
static IOAVServiceReadI2CFn  _avRead;
static IOAVServiceWriteI2CFn _avWrite;
#endif

static const uint8_t DDC_ADDR = 0x37;
static const uint8_t DDC_BRIGHTNESS_VCP = 0x10;

@implementation BrightnessHelper

+ (void)initialize {
    // CoreDisplay (for built-in)
    void *cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
    if (!cd) cd = dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
    if (cd) {
        _cdGetBrightness = dlsym(cd, "CoreDisplay_Display_GetUserBrightness");
        _cdSetBrightness = dlsym(cd, "CoreDisplay_Display_SetUserBrightness");
    }

#if __arm64__
    // IOAVService (for external DDC on Apple Silicon)
    void *iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokitHandle) {
        _avCreate = dlsym(iokitHandle, "IOAVServiceCreateWithService");
        _avRead   = dlsym(iokitHandle, "IOAVServiceReadI2C");
        _avWrite  = dlsym(iokitHandle, "IOAVServiceWriteI2C");
    }
#endif
}

// MARK: - Public API

+ (BOOL)isSupported:(CGDirectDisplayID)displayID {
    if (CGDisplayIsBuiltin(displayID)) {
        return _cdGetBrightness != NULL && _cdSetBrightness != NULL;
    }
#if __arm64__
    return _avCreate != NULL && _avRead != NULL && _avWrite != NULL;
#else
    return NO;
#endif
}

+ (double)getBrightness:(CGDirectDisplayID)displayID {
    if (CGDisplayIsBuiltin(displayID)) {
        return [self getBuiltinBrightness:displayID];
    }
    return [self getDDCBrightness:displayID];
}

+ (BOOL)setBrightness:(CGDirectDisplayID)displayID value:(double)value {
    double clamped = fmax(0.0, fmin(1.0, value));
    if (CGDisplayIsBuiltin(displayID)) {
        return [self setBuiltinBrightness:displayID value:clamped];
    }
    return [self setDDCBrightness:displayID value:clamped];
}

// MARK: - Built-in Display (CoreDisplay)

+ (double)getBuiltinBrightness:(CGDirectDisplayID)displayID {
    if (!_cdGetBrightness) return -1;
    return _cdGetBrightness(displayID);
}

+ (BOOL)setBuiltinBrightness:(CGDirectDisplayID)displayID value:(double)value {
    if (!_cdSetBrightness) return NO;
    _cdSetBrightness(displayID, value);
    return YES;
}

// MARK: - External Display (DDC/CI via IOAVService)

#if __arm64__

+ (IOAVServiceRef)avServiceForDisplay:(CGDirectDisplayID)displayID {
    if (!_avCreate) return NULL;

    io_iterator_t iter = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault,
                                 IOServiceMatching("DCPAVServiceProxy"), &iter);
    IOAVServiceRef found = NULL;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter)) != 0) {
        IOAVServiceRef av = _avCreate(kCFAllocatorDefault, svc);
        IOObjectRelease(svc);
        if (av) {
            // Try a DDC read to see if this service responds
            uint8_t probe[12] = {0};
            IOReturn ret = _avRead(av, DDC_ADDR, 0, probe, 1);
            if (ret == kIOReturnSuccess) {
                found = av;
                break;
            }
            CFRelease(av);
        }
    }
    IOObjectRelease(iter);
    return found;
}

+ (double)getDDCBrightness:(CGDirectDisplayID)displayID {
    IOAVServiceRef av = [self avServiceForDisplay:displayID];
    if (!av) return -1;

    // DDC Get VCP Feature: write request then read response
    // Request: [0x51, 0x82, 0x01, vcp_code, checksum]
    uint8_t req[5];
    req[0] = 0x51;  // source
    req[1] = 0x82;  // length = 0x80 | 2
    req[2] = 0x01;  // Get VCP Feature
    req[3] = DDC_BRIGHTNESS_VCP;
    req[4] = DDC_ADDR ^ req[0] ^ req[1] ^ req[2] ^ req[3];

    IOReturn ret = _avWrite(av, DDC_ADDR, 0, req, sizeof(req));
    if (ret != kIOReturnSuccess) { CFRelease(av); return -1; }

    usleep(40000); // DDC needs ~40ms delay

    uint8_t resp[12] = {0};
    ret = _avRead(av, DDC_ADDR, 0, resp, sizeof(resp));
    CFRelease(av);
    if (ret != kIOReturnSuccess) return -1;

    // Response: [src, len, 0x02, result, vcp, type, max_h, max_l, cur_h, cur_l, checksum]
    if (resp[2] != 0x02 || resp[3] != 0x00) return -1;

    uint16_t maxVal = ((uint16_t)resp[6] << 8) | resp[7];
    uint16_t curVal = ((uint16_t)resp[8] << 8) | resp[9];

    if (maxVal == 0) return -1;
    return (double)curVal / (double)maxVal;
}

+ (BOOL)setDDCBrightness:(CGDirectDisplayID)displayID value:(double)value {
    // First read max value
    IOAVServiceRef av = [self avServiceForDisplay:displayID];
    if (!av) return NO;

    // Read current to get max
    uint8_t req[5];
    req[0] = 0x51;
    req[1] = 0x82;
    req[2] = 0x01;
    req[3] = DDC_BRIGHTNESS_VCP;
    req[4] = DDC_ADDR ^ req[0] ^ req[1] ^ req[2] ^ req[3];

    IOReturn ret = _avWrite(av, DDC_ADDR, 0, req, sizeof(req));
    if (ret != kIOReturnSuccess) { CFRelease(av); return NO; }

    usleep(40000);

    uint8_t resp[12] = {0};
    ret = _avRead(av, DDC_ADDR, 0, resp, sizeof(resp));
    if (ret != kIOReturnSuccess || resp[2] != 0x02) { CFRelease(av); return NO; }

    uint16_t maxVal = ((uint16_t)resp[6] << 8) | resp[7];
    if (maxVal == 0) maxVal = 100;

    uint16_t newVal = (uint16_t)(value * maxVal);

    // DDC Set VCP Feature: [0x51, 0x84, 0x03, vcp_code, val_h, val_l, checksum]
    uint8_t cmd[7];
    cmd[0] = 0x51;
    cmd[1] = 0x84;  // length = 0x80 | 4
    cmd[2] = 0x03;  // Set VCP Feature
    cmd[3] = DDC_BRIGHTNESS_VCP;
    cmd[4] = (newVal >> 8) & 0xFF;
    cmd[5] = newVal & 0xFF;
    cmd[6] = DDC_ADDR ^ cmd[0] ^ cmd[1] ^ cmd[2] ^ cmd[3] ^ cmd[4] ^ cmd[5];

    usleep(50000); // delay between DDC commands

    ret = _avWrite(av, DDC_ADDR, 0, cmd, sizeof(cmd));
    CFRelease(av);
    return ret == kIOReturnSuccess;
}

#else

+ (double)getDDCBrightness:(CGDirectDisplayID)displayID { return -1; }
+ (BOOL)setDDCBrightness:(CGDirectDisplayID)displayID value:(double)value { return NO; }

#endif

@end
