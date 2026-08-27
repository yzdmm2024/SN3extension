//
//  LongShotController.m — 长截图实现：找到当前页面最大的滚动视图，按住帧步进
//  滚动并逐段渲染拼接。
//
#import "LongShotController.h"
#import "Common.h"

@implementation LongShotController

// 递归收集给定视图内的所有 scrollview
+ (NSMutableArray<UIScrollView *> *)collectScrollViewsInView:(UIView *)v into:(NSMutableArray *)arr {
    if ([v isKindOfClass:[UIScrollView class]]) [arr addObject:(UIScrollView *)v];
    for (UIView *sub in v.subviews) [self collectScrollViewsInView:sub into:arr];
    return arr;
}

+ (void)captureFromKeyWindowCompletion:(void (^)(UIImage *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [Common topWindow];
        if (!win) { if (completion) completion(nil); return; }

        NSMutableArray *scrolls = [self collectScrollViewsInView:win into:[NSMutableArray array]];
        UIScrollView *best = nil;
        CGFloat bestH = 0;
        for (UIScrollView *sv in scrolls) {
            CGFloat h = sv.contentSize.height;
            if (sv.scrollEnabled && h > bestH) { bestH = h; best = sv; }
        }

        if (!best || bestH <= best.frame.size.height + 1) {
            // 没有可滚动内容：退回普通截图
            UIGraphicsBeginImageContextWithOptions(win.bounds.size, NO, 0);
            [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (completion) completion(img);
            return;
        }

        UIScrollView *sv = best;
        CGFloat fw = sv.bounds.size.width;
        CGFloat fh = sv.bounds.size.height;
        CGFloat totalH = MAX(bestH, fh);

        // 用户可调：重叠比例 / 高度上限 / 帧间等待
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
        double overlapD = [d doubleForKey:XZ_KEY_LONG_OVERLAP];
        if (overlapD <= 0) overlapD = 0;
        if (overlapD > 0.3) overlapD = 0.3;
        double maxHpref = [d doubleForKey:XZ_KEY_LONG_MAXH];
        if (maxHpref >= 400 && maxHpref < totalH) totalH = maxHpref;
        double interval = [d doubleForKey:XZ_KEY_LONG_INTERVAL];
        if (interval <= 0) interval = 0.03;
        if (interval > 0.15) interval = 0.15;

        CGFloat step = fh * (1.0 - overlapD);
        if (step < 1) step = fh;

        CGPoint savedOffset = sv.contentOffset;

        UIGraphicsBeginImageContextWithOptions(CGSizeMake(fw, totalH), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();

        CGFloat y = 0;
        while (y < totalH) {
            [sv setContentOffset:CGPointMake(0, y)];
            if (interval > 0) {
                [CATransaction flush];
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, interval, false);
            }
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, 0, -y);
            [sv.layer renderInContext:ctx];
            CGContextRestoreGState(ctx);
            CGContextTranslateCTM(ctx, 0, step);
            y += step;
        }

        [sv setContentOffset:savedOffset];
        UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (completion) completion(result);
    });
}

@end