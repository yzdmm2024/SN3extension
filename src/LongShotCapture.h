//
//  LongShotCapture.h — 长截图：分段抓帧 + Vision 特征配准 + 垂直拼接
//
//  【规格书对应】生成长图 ②：
//    以固定左右范围 + 两条标尺划定的 Y 轴垂直区间，自动分段多次抓取屏幕画面，
//    Vision 特征匹配，帧与帧保留重叠，自动拼接生成完整长图；做最大高度限制防 OOM。
//
//  【关于「不做 App 自动滚动」】
//    本 tweak 只注入 SpringBoard（Bundles = com.apple.springboard），
//    无法访问前台 App 的 UIScrollView，因此严格遵循规格书第 4 条：
//    不自动滚动页面，由用户手动滑动；MaskCropWindow 按固定节拍采样抓帧，
//    本类负责「去重 + 配准 + 重叠裁剪 + 拼接」。
//
//  调用关系：
//    MaskCropWindow.captureTick
//        └─> [LongShotCapture addFrame:]        每帧一张（按采集带裁剪好的图）
//        └─> [LongShotCapture isOverHeightLimit] 到顶就停
//    MaskCropWindow.finishCapture
//        └─> [LongShotCapture stitchWithCompletion:] → 窗口B
//

#import <UIKit/UIKit.h>

@interface LongShotCapture : NSObject

+ (instancetype)sharedInstance;

// 已采集并保留的帧数
@property (nonatomic, readonly) NSInteger frameCount;

// 按当前重叠量估算出的最终长图高度（单位：点）
@property (nonatomic, readonly) CGFloat estimatedHeight;

// 清空已采集帧（进入新采集 / 取消 / 退出时调用）
- (void)reset;

// 追加一帧；若与上一帧相比几乎没有位移（用户没滑动）返回 NO 并丢弃该帧
- (BOOL)addFrame:(UIImage *)frame;

// v5.2：手动长截图模式追加一帧（用户滑完一屏后主动点【下一屏】）。
//   有可靠 SAD 接缝则用之；配不准时按极小保守重叠(10%)拼入，避免重复堆叠。
- (BOOL)addManualFrame:(UIImage *)frame;

// 是否已达最大高度上限（到顶即停止采集，防 OOM）
- (BOOL)isOverHeightLimit;

// Vision 配准 + 垂直拼接；result = nil 表示失败
- (void)stitchWithCompletion:(void (^)(UIImage *result))completion;

// 拼接兜底（finishCapture 拼接失败分支调用）：复跑 stitchSync，绝不返回 nil
- (UIImage *)stitchFallback;

@end
