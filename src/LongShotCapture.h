//
//  LongShotCapture.h — 长截图：用户手动采集模式 + Vision 配准拼接
//  规格书：不自动滚动页面，用户手动滑动 App，多次「采集下一屏」，
//  帧之间保证重叠，完成时用 Vision 特征匹配找重叠区裁剪后垂直拼接。
//

#import <UIKit/UIKit.h>

@interface LongShotCapture : NSObject

+ (instancetype)sharedInstance;

// 已采集帧数
@property (nonatomic, readonly) NSInteger frameCount;

// 清空已采集帧（进入新采集 / 取消时调用）
- (void)reset;

// 追加一帧（已按 cropRect 裁剪好的图片）
- (void)addFrame:(UIImage *)frame;

// Vision 配准 + 垂直拼接；result=nil 表示失败
- (void)stitchWithCompletion:(void (^)(UIImage *result))completion;

@end
