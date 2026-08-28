//
//  LongShotController.m — 滚动长截图（v3.13 重构）
//
//  [v3.12 教训] 旧实现（自动滚动拼接）在 SpringBoard / 控制中心上下文里执行：
//  递归 collectScrollViewsInView: 找到 SB 私有 scrollview，再 [sv setContentOffset:]
//  + [sv.layer renderInContext:] 触碰 SB 内部不变量 → MobileSubstrate Safe Mode。
//
//  [v3.13 正确架构] 滚动拼接只允许在【普通 App 进程】里执行：
//    - SpringBoard 点选择器里的「长截图」→ 发 darwin 通知 cc.longshot
//    - 前台 App（本 tweak 已注入）收到通知 → 本类在 App 进程滚动拼接 → 弹操作行
//    - App 进程的 scrollview 属于 App 自己，修改 contentOffset 是安全的
//  本类不再有在 SB 上下文执行的入口。
//

#import "LongShotController.h"
#import "Common.h"

@implementation LongShotController

// 递归收集给定视图内的所有 scrollview
+ (NSMutableArray<UIScrollView *> *)collectScrollViewsInView:(UIView *)v into:(NSMutableArray *)arr {
    if ([v isKindOfClass:[UIScrollView class]]) [arr addObject:(UIScrollView *)v];
    for (UIView *sub in v.subviews) {
        @try {
            [self collectScrollViewsInView:sub into:arr];
        } @catch (NSException *e) {
            NSLog(@"[SN3] collect exception: %@", e);
        }
    }
    return arr;
}

// 安全兜底：纯整屏截图（不触碰任何 scrollview / layer.render）
+ (UIImage *)captureSafeScreen {
    Class imgUtils = NSClassFromString(@"ImageUtils");
    SEL sel = @selector(captureScreen);
    if (imgUtils && [imgUtils respondsToSelector:sel]) {
        return ((UIImage *(*)(id, SEL))[imgUtils methodForSelector:sel])(imgUtils, sel);
    }
    return nil;
}

// 旧接口 stub：不再自动滚动拼接（SB 上下文会触发 Safe Mode），一律回退整屏截图。
+ (void)captureFromKeyWindowCompletion:(void (^)(UIImage *stitched))completion {
    if (completion) completion([self captureSafeScreen]);
}

// 滚动长截图（App 进程专用）：找到 rootViewController.view 子树中最大的可滚动
// scrollview，从顶部逐屏滚动、渲染、拼接成一张长图。
// 全程 @try 兜底；任何异常回退普通整屏截图。
+ (void)captureStitchedInCurrentProcessCompletion:(void (^)(UIImage *stitched))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = [Common topWindow];
            if (!win) { if (completion) completion([self captureSafeScreen]); return; }

            // 只在普通 App 上下文做：rootViewController 存在且不是 SB/CC/系统 UI
            UIViewController *root = win.rootViewController;
            NSString *cls = root ? NSStringFromClass([root class]) : @"";
            if (!root || [cls hasPrefix:@"SB"] || [cls hasPrefix:@"CC"] || [cls hasPrefix:@"UI"]) {
                NSLog(@"[SN3] longshot: not an app context (%@), fallback", cls);
                if (completion) completion([self captureSafeScreen]);
                return;
            }

            // 在 root.view 子树里找最大的可滚动视图
            NSMutableArray *scrolls = [NSMutableArray array];
            [self collectScrollViewsInView:root.view into:scrolls];
            UIScrollView *best = nil;
            CGFloat bestH = 0;
            for (UIScrollView *sv in scrolls) {
                if (!sv.scrollEnabled) continue;
                if (![sv isKindOfClass:[UIScrollView class]]) continue;
                CGFloat h = sv.contentSize.height;
                if (h > bestH) { bestH = h; best = sv; }
            }

            if (!best || bestH <= best.frame.size.height + 1) {
                if (completion) completion([self captureSafeScreen]);
                return;
            }

            // 尺寸与拼接高度（尊重偏好里的最大高度，硬上限 8000px 防内存爆炸）
            CGFloat fw = best.bounds.size.width;
            CGFloat fh = best.bounds.size.height;
            CGFloat totalH = MAX(bestH, fh);
            NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
            double maxHpref = [d doubleForKey:XZ_KEY_LONG_MAXH];
            if (maxHpref >= 400 && maxHpref < totalH) totalH = maxHpref;
            if (totalH > 8000) totalH = 8000;

            CGFloat step = fh;
            if (step < 1) step = 1;

            CGPoint savedOffset = best.contentOffset;

            UIGraphicsBeginImageContextWithOptions(CGSizeMake(fw, totalH), NO, 0);
            CGContextRef ctx = UIGraphicsGetCurrentContext();
            if (!ctx) {
                UIGraphicsEndImageContext();
                if (completion) completion([self captureSafeScreen]);
                return;
            }

            CGFloat y = 0;
            while (y < totalH) {
                [best setContentOffset:CGPointMake(0, y)];
                [CATransaction flush];
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
                CGContextSaveGState(ctx);
                CGContextTranslateCTM(ctx, 0, -y);
                [best.layer renderInContext:ctx];
                CGContextRestoreGState(ctx);
                CGContextTranslateCTM(ctx, 0, step);
                y += step;
            }

            [best setContentOffset:savedOffset];
            UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (completion) completion(result);
        } @catch (NSException *e) {
            NSLog(@"[SN3] longshot exception: %@ %@", e.name, e.reason);
            if (completion) completion([self captureSafeScreen]);
        }
    });
}

@end
