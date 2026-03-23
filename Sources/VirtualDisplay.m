#import "VirtualDisplay.h"
#import <objc/runtime.h>

// ---------- Forward-declare private CoreGraphics classes ----------

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (CGDirectDisplayID)displayID;
- (CGError)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// ---------- Implementation ----------

/// Map: physicalID -> CGVirtualDisplay*
static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *_vdMap;
/// Map: physicalID -> original display name
static NSMutableDictionary<NSNumber *, NSString *> *_nameMap;

@implementation VirtualDisplayHelper

+ (void)initialize {
    _vdMap  = [NSMutableDictionary new];
    _nameMap = [NSMutableDictionary new];
}

+ (BOOL)isAvailable {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil;
}

+ (CGDirectDisplayID)enableHiDPIForDisplay:(CGDirectDisplayID)physicalID
                                  maxWidth:(uint32_t)width
                                 maxHeight:(uint32_t)height
                               displayName:(NSString *)name {
    if (![self isAvailable]) {
        fprintf(stderr, "MyDisplay: CGVirtualDisplay API not available\n");
        return kCGNullDirectDisplay;
    }

    // Remove existing one first
    [self disableHiDPIForDisplay:physicalID];

    // Remember the name
    _nameMap[@(physicalID)] = name;

    // ---- Descriptor ----
    CGVirtualDisplayDescriptor *desc =
        [(CGVirtualDisplayDescriptor *)[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    desc.queue           = dispatch_get_main_queue();
    desc.name            = [NSString stringWithFormat:@"%@ (HiDPI)", name];
    desc.maxPixelsWide   = width;
    desc.maxPixelsHigh   = height;
    desc.sizeInMillimeters = CGSizeMake(600, 340);   // ~27"
    desc.productID       = 0xF0F0;
    desc.vendorID        = 0xE0E0;
    desc.serialNum       = physicalID;

    // ---- Create virtual display ----
    CGVirtualDisplay *vd =
        [(CGVirtualDisplay *)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    if (!vd) {
        fprintf(stderr, "MyDisplay: CGVirtualDisplay init failed\n");
        return kCGNullDirectDisplay;
    }

    // ---- Build modes ----
    double ratio = (double)width / (double)height;
    // "Looks-like" logical widths; modes are at 2x for HiDPI
    unsigned int logicalWidths[] = { 1920, 1680, 1600, 1440, 1280, 1024 };
    int count = sizeof(logicalWidths) / sizeof(logicalWidths[0]);

    NSMutableArray *modes = [NSMutableArray new];
    for (int i = 0; i < count; i++) {
        unsigned int mw = logicalWidths[i] * 2;
        unsigned int mh = (unsigned int)round((double)(logicalWidths[i] * 2) / ratio);
        if (mw > width) continue;   // skip modes larger than max
        CGVirtualDisplayMode *m =
            [(CGVirtualDisplayMode *)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:mw height:mh refreshRate:60.0];
        if (m) [modes addObject:m];
    }
    // Also add native-2x mode (e.g. 2560x1440 → 1280x720 HiDPI)
    CGVirtualDisplayMode *nativeMode =
        [(CGVirtualDisplayMode *)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
            initWithWidth:width height:height refreshRate:60.0];
    if (nativeMode) [modes addObject:nativeMode];

    // ---- Apply settings ----
    CGVirtualDisplaySettings *settings =
        [(CGVirtualDisplaySettings *)[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = YES;
    settings.modes = modes;

    CGError err = [vd applySettings:settings];
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "MyDisplay: applySettings error %d\n", err);
    }

    _vdMap[@(physicalID)] = vd;

    CGDirectDisplayID virtualID = [vd displayID];
    fprintf(stderr, "MyDisplay: virtual display %u created for physical %u (%ux%u)\n",
            virtualID, physicalID, width, height);

    // Delay mirroring — the system needs time to register the virtual display
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CGDirectDisplayID vid = [vd displayID];
        fprintf(stderr, "MyDisplay: setting up mirror physical=%u -> virtual=%u\n", physicalID, vid);

        CGDisplayConfigRef config = NULL;
        CGError err = CGBeginDisplayConfiguration(&config);
        if (err != kCGErrorSuccess) {
            fprintf(stderr, "MyDisplay: CGBeginDisplayConfiguration failed: %d\n", err);
            return;
        }
        CGConfigureDisplayMirrorOfDisplay(config, physicalID, vid);

        // Try kCGConfigureForSession first (less restrictive)
        err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        fprintf(stderr, "MyDisplay: mirror config result: %d\n", err);

        if (err != kCGErrorSuccess) {
            // Fallback: try permanently
            CGBeginDisplayConfiguration(&config);
            CGConfigureDisplayMirrorOfDisplay(config, physicalID, vid);
            err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
            fprintf(stderr, "MyDisplay: mirror config (permanent) result: %d\n", err);
        }
    });

    return virtualID;
}

+ (void)disableHiDPIForDisplay:(CGDirectDisplayID)physicalID {
    if (!_vdMap[@(physicalID)]) return;

    // Un-mirror
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    CGConfigureDisplayMirrorOfDisplay(config, physicalID, kCGNullDirectDisplay);
    CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);

    // Release virtual display (ARC will dealloc it)
    [_vdMap removeObjectForKey:@(physicalID)];
    [_nameMap removeObjectForKey:@(physicalID)];
    NSLog(@"MyDisplay: HiDPI disabled for physical %u", physicalID);
}

+ (BOOL)isHiDPIEnabledForDisplay:(CGDirectDisplayID)physicalID {
    return _vdMap[@(physicalID)] != nil;
}

+ (nullable NSString *)storedNameForPhysical:(CGDirectDisplayID)physicalID {
    return _nameMap[@(physicalID)];
}

+ (CGDirectDisplayID)virtualIDForPhysical:(CGDirectDisplayID)physicalID {
    CGVirtualDisplay *vd = _vdMap[@(physicalID)];
    return vd ? [vd displayID] : kCGNullDirectDisplay;
}

+ (CGDirectDisplayID)physicalIDForVirtual:(CGDirectDisplayID)virtualID {
    for (NSNumber *key in _vdMap) {
        CGVirtualDisplay *vd = _vdMap[key];
        if ([vd displayID] == virtualID) {
            return key.unsignedIntValue;
        }
    }
    return kCGNullDirectDisplay;
}

+ (void)removeAll {
    for (NSNumber *key in [_vdMap allKeys]) {
        [self disableHiDPIForDisplay:key.unsignedIntValue];
    }
}

@end
