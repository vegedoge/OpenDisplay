#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrightnessHelper : NSObject

/// Get current brightness (0.0–1.0). Returns -1 if unsupported.
+ (double)getBrightness:(CGDirectDisplayID)displayID;

/// Set brightness (0.0–1.0). Returns YES on success.
+ (BOOL)setBrightness:(CGDirectDisplayID)displayID value:(double)value;

/// Whether brightness control is available for this display.
+ (BOOL)isSupported:(CGDirectDisplayID)displayID;

@end

NS_ASSUME_NONNULL_END
