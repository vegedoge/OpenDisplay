#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGSDisplayHelper : NSObject
+ (BOOL)isAvailable;
+ (BOOL)setDisplay:(CGDirectDisplayID)displayID enabled:(BOOL)enabled;
@end
