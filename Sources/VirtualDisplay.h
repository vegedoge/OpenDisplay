#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps the private CGVirtualDisplay API to create HiDPI-capable virtual displays
/// and mirror physical displays to them.
@interface VirtualDisplayHelper : NSObject

/// Whether the private CGVirtualDisplay API exists on this OS version.
+ (BOOL)isAvailable;

/// Create a HiDPI virtual display and mirror the physical display to it.
/// Returns the virtual display ID, or kCGNullDirectDisplay on failure.
/// @param refreshRates Array of NSNumber (double) refresh rates the physical display supports.
+ (CGDirectDisplayID)enableHiDPIForDisplay:(CGDirectDisplayID)physicalID
                                  maxWidth:(uint32_t)width
                                 maxHeight:(uint32_t)height
                              refreshRates:(NSArray<NSNumber *> *)refreshRates
                               displayName:(NSString *)name;

/// Remove the virtual display and un-mirror the physical display.
+ (void)disableHiDPIForDisplay:(CGDirectDisplayID)physicalID;

/// Check whether we have a virtual display for the given physical display.
+ (BOOL)isHiDPIEnabledForDisplay:(CGDirectDisplayID)physicalID;

/// Physical display ID -> stored display name (saved before mirroring).
+ (nullable NSString *)storedNameForPhysical:(CGDirectDisplayID)physicalID;

/// Physical display ID -> virtual display ID (or 0 if none).
+ (CGDirectDisplayID)virtualIDForPhysical:(CGDirectDisplayID)physicalID;

/// Reverse lookup: is this active display one of our virtual displays?
/// If so, returns the corresponding physical display ID, otherwise 0.
+ (CGDirectDisplayID)physicalIDForVirtual:(CGDirectDisplayID)virtualID;

/// Remove virtual displays whose physical display is no longer connected.
/// Returns the physical display IDs that were cleaned up (empty if none).
+ (NSArray<NSNumber *> *)cleanupDisconnectedDisplays;

/// Tear down all virtual displays (call on app quit).
+ (void)removeAll;

@end

NS_ASSUME_NONNULL_END
