#import "CGSModeHelper.h"
#import <dlfcn.h>

// CGS struct layout on macOS 26 (reverse-engineered):
//  [0] int32  modeNumber
//  [1] uint32 flags
//  [2] uint32 width  (logical)
//  [3] uint32 height (logical)
//  [4] uint32 bytesPerPixel (4 or 8)
//  [5] uint32 rowBytes (pixelWidth * bytesPerPixel)
//  [6] uint32 bitDepth (32)
//  [7..8]     unknown
//  [9] uint32 refreshRate (Hz)
typedef struct { uint32_t data[48]; } RawModeDesc;

typedef int (*GetNumModesFn)(uint32_t display, int *count);
typedef int (*GetModeDescFn)(uint32_t display, int idx, RawModeDesc *desc, int len);
typedef int (*ConfigDispModeFn)(void *config, uint32_t display, int modeIdx);

static GetNumModesFn  _getNumModes;
static GetModeDescFn  _getModeDesc;
static ConfigDispModeFn _configMode;

@implementation DisplayModeInfo
@end

@implementation CGSModeHelper

+ (void)initialize {
    void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    if (!h) return;
    _getNumModes = dlsym(h, "CGSGetNumberOfDisplayModes");
    _getModeDesc = dlsym(h, "CGSGetDisplayModeDescriptionOfLength");
    _configMode  = dlsym(h, "CGSConfigureDisplayMode");
}

+ (NSArray<DisplayModeInfo *> *)modesForDisplay:(CGDirectDisplayID)displayID {
    if (!_getNumModes || !_getModeDesc) return @[];

    int numModes = 0;
    _getNumModes(displayID, &numModes);

    NSMutableArray<DisplayModeInfo *> *result = [NSMutableArray new];
    for (int i = 0; i < numModes; i++) {
        RawModeDesc raw = {0};
        _getModeDesc(displayID, i, &raw, sizeof(raw));

        uint32_t width  = raw.data[2];
        uint32_t height = raw.data[3];
        uint32_t bpp    = raw.data[4];
        uint32_t rowB   = raw.data[5];
        uint32_t hz     = raw.data[9];

        if (width == 0 || height == 0 || bpp == 0) continue;

        uint32_t pixelWidth  = rowB / bpp;
        uint32_t pixelHeight = (pixelWidth > width)
            ? height * (pixelWidth / width)
            : height;

        DisplayModeInfo *info = [DisplayModeInfo new];
        info.modeNumber  = (int32_t)raw.data[0];
        info.width       = width;
        info.height      = height;
        info.pixelWidth  = pixelWidth;
        info.pixelHeight = pixelHeight;
        info.refreshRate = hz;
        info.isHiDPI     = (pixelWidth > width);
        [result addObject:info];
    }
    return result;
}

+ (BOOL)switchDisplay:(CGDirectDisplayID)displayID toMode:(int32_t)modeNumber {
    if (!_configMode) {
        fprintf(stderr, "OpenDisplay: CGSConfigureDisplayMode not available\n");
        return NO;
    }

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) return NO;

    int result = _configMode(config, displayID, modeNumber);
    fprintf(stderr, "OpenDisplay: CGSConfigureDisplayMode(%u, %d) = %d\n",
            displayID, modeNumber, result);

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    return err == kCGErrorSuccess;
}

@end
