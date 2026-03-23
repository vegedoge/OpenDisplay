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
                              refreshRates:(NSArray<NSNumber *> *)refreshRates
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
    // Small physical size → high PPI → macOS auto-detects as Retina
    // 3840px / (295mm / 25.4) ≈ 330 PPI (well above retina threshold)
    desc.sizeInMillimeters = CGSizeMake(295, 166);
    desc.productID       = 0xF0F0;
    desc.vendorID        = 0xE0E0;
    desc.serialNum       = physicalID;

    // Try setting hiDPI on descriptor via KVC (some macOS versions support this)
    @try { [desc setValue:@YES forKey:@"hiDPI"]; }
    @catch (NSException *e) { /* property may not exist */ }

    // ---- Create virtual display ----
    CGVirtualDisplay *vd =
        [(CGVirtualDisplay *)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    if (!vd) {
        fprintf(stderr, "MyDisplay: CGVirtualDisplay init failed\n");
        return kCGNullDirectDisplay;
    }

    // ---- Build modes ----
    double ratio = (double)width / (double)height;
    unsigned int logicalWidths[] = { 1920, 1680, 1600, 1440, 1280, 1024 };
    int widthCount = sizeof(logicalWidths) / sizeof(logicalWidths[0]);

    // Use provided refresh rates, fallback to 60Hz
    NSArray<NSNumber *> *rates = refreshRates.count > 0 ? refreshRates : @[@60.0];

    NSMutableArray *modes = [NSMutableArray new];
    for (NSNumber *rateNum in rates) {
        double rate = rateNum.doubleValue;
        for (int i = 0; i < widthCount; i++) {
            unsigned int mw = logicalWidths[i] * 2;
            unsigned int mh = (unsigned int)round((double)(logicalWidths[i] * 2) / ratio);
            if (mw > width) continue;
            CGVirtualDisplayMode *m =
                [(CGVirtualDisplayMode *)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                    initWithWidth:mw height:mh refreshRate:rate];
            if (m) [modes addObject:m];
        }
        // Native-2x mode at this refresh rate
        CGVirtualDisplayMode *nativeMode =
            [(CGVirtualDisplayMode *)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:width height:height refreshRate:rate];
        if (nativeMode) [modes addObject:nativeMode];
    }
    fprintf(stderr, "MyDisplay: created %lu modes at %lu refresh rates\n",
            (unsigned long)modes.count, (unsigned long)rates.count);

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

        // Save all OTHER displays' origins so they don't move
        uint32_t dcount = 0;
        CGGetActiveDisplayList(0, NULL, &dcount);
        uint32_t *dids = calloc(dcount, sizeof(uint32_t));
        CGGetActiveDisplayList(dcount, dids, &dcount);

        typedef struct { uint32_t did; int32_t x, y; } SavedOrigin;
        SavedOrigin *origins = calloc(dcount, sizeof(SavedOrigin));
        for (uint32_t i = 0; i < dcount; i++) {
            CGRect bounds = CGDisplayBounds(dids[i]);
            origins[i] = (SavedOrigin){ dids[i], (int32_t)bounds.origin.x, (int32_t)bounds.origin.y };
        }

        CGDisplayConfigRef config = NULL;
        CGError err = CGBeginDisplayConfiguration(&config);
        if (err != kCGErrorSuccess) {
            fprintf(stderr, "MyDisplay: CGBeginDisplayConfiguration failed: %d\n", err);
            free(dids); free(origins);
            return;
        }

        CGConfigureDisplayMirrorOfDisplay(config, physicalID, vid);

        // Pin other displays to their current positions
        for (uint32_t i = 0; i < dcount; i++) {
            if (origins[i].did != physicalID && origins[i].did != vid) {
                CGConfigureDisplayOrigin(config, origins[i].did, origins[i].x, origins[i].y);
            }
        }

        err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        fprintf(stderr, "MyDisplay: mirror config result: %d\n", err);

        if (err != kCGErrorSuccess) {
            CGBeginDisplayConfiguration(&config);
            CGConfigureDisplayMirrorOfDisplay(config, physicalID, vid);
            for (uint32_t i = 0; i < dcount; i++) {
                if (origins[i].did != physicalID && origins[i].did != vid) {
                    CGConfigureDisplayOrigin(config, origins[i].did, origins[i].x, origins[i].y);
                }
            }
            err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
            fprintf(stderr, "MyDisplay: mirror config (permanent) result: %d\n", err);
        }

        free(dids); free(origins);
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
