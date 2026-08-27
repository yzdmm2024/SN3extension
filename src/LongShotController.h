//
//  LongShotController.h — 长截图：滚动主 UIScrollView 逐帧拼接
//
#import <UIKit/UIKit.h>

@interface LongShotController : NSObject
+ (void)captureFromKeyWindowCompletion:(void (^)(UIImage *stitched))completion;
@end