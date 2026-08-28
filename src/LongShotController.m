//
//  LongShotController.m
//  Snapper3ZhExt
//
//  [v3.12 历史教训] 旧的自动滚动拼接实现会在 SpringBoard / 控制中心上下文里
//  递归 collectScrollViewsInView: 找到 SB 私有 scrollview，然后
//  [sv setContentOffset:] + [sv.layer renderInContext:] 触碰 SB 内部不变量，
//  触发 MobileSubstrate Safe Mode。
//
//  v3.12 起：
//    - 长截图改为手动选 4 边界（FloatingMenu.showLongShotPicker:），不再做
//      自动滚动拼接，彻底绕开 SB 内部状态；
//    - 本类只保留一个安全兜底方法 captureSafeScreen（走 ImageUtils 整屏截图）
//      供其它模块调用，不再执行任何 scrollview 操作。
//

#import "LongShotController.h"
#import "Common.h"
#import <objc/runtime.h>

@implementation LongShotController

// 旧接口 stub：自动滚动拼接已废弃（SB/CC 上下文会触发 Safe Mode），
// 统一回退为整屏截图，交由调用方走 4 边界手动长截图（FloatingMenu.showLongShotPicker:）。
+ (void)captureFromKeyWindowCompletion:(void (^)(UIImage *stitched))completion {
    if (completion) completion([self captureSafeScreen]);
}

// 安全兜底：纯整屏截图（不再触碰任何 scrollview / layer.render）
+ (UIImage *)captureSafeScreen {
    Class imgUtils = NSClassFromString(@"ImageUtils");
    SEL sel = @selector(captureScreen);
    if (imgUtils && [imgUtils respondsToSelector:sel]) {
        return ((UIImage *(*)(id, SEL))[imgUtils methodForSelector:sel])(imgUtils, sel);
    }
    return nil;
}

@end