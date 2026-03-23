#import "CGSDisplayHelper.h"
#import <dlfcn.h>

// CGSConfigureDisplayEnabled uses CGDisplayConfigRef as first param (not connection ID).
// Same pattern as CGConfigureDisplayMirrorOfDisplay(config, display, master).
typedef int (*CGSConfigureDisplayEnabledFn)(CGDisplayConfigRef config, uint32_t display, int enabled);

static CGSConfigureDisplayEnabledFn _configDisplayEnabled;

@implementation CGSDisplayHelper

+ (void)initialize {
    _configDisplayEnabled = dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    if (!_configDisplayEnabled) {
        // Try the SLS variant (newer macOS)
        _configDisplayEnabled = dlsym(RTLD_DEFAULT, "SLSConfigureDisplayEnabled");
    }
    fprintf(stderr, "OpenDisplay: CGSConfigureDisplayEnabled = %p\n", _configDisplayEnabled);
}

+ (BOOL)isAvailable {
    return _configDisplayEnabled != NULL;
}

+ (BOOL)setDisplay:(CGDirectDisplayID)displayID enabled:(BOOL)enabled {
    if (!_configDisplayEnabled) return NO;

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "OpenDisplay: CGBeginDisplayConfiguration failed: %d\n", err);
        return NO;
    }

    int result = _configDisplayEnabled(config, displayID, enabled ? 1 : 0);
    fprintf(stderr, "OpenDisplay: CGSConfigureDisplayEnabled(%u, %d) = %d\n",
            displayID, enabled, result);

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "OpenDisplay: CGCompleteDisplayConfiguration failed: %d\n", err);
        return NO;
    }
    return YES;
}

@end
