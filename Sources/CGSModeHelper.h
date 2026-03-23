#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DisplayModeInfo : NSObject
@property int32_t  modeNumber;
@property uint32_t width;
@property uint32_t height;
@property uint32_t pixelWidth;
@property uint32_t pixelHeight;
@property uint32_t refreshRate;
@property BOOL     isHiDPI;
@end

@interface CGSModeHelper : NSObject
/// Enumerate all display modes (including HiDPI) via private CGS API.
+ (NSArray<DisplayModeInfo *> *)modesForDisplay:(CGDirectDisplayID)displayID;
/// Switch display to the given CGS mode number.
+ (BOOL)switchDisplay:(CGDirectDisplayID)displayID toMode:(int32_t)modeNumber;
@end

NS_ASSUME_NONNULL_END
