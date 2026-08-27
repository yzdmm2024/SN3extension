//
//  Tweak.xm — 独立插件 v2.05：截屏 → 浮动菜单
//  所有功能模块通过运行时调用，避免编译时强依赖导致崩溃
//

#import <UIKit/UIKit.h>
#import "Common.h"
#import "FloatingMenu.h"
#import "ImageUtils.h"

#pragma mark - 截屏检测

static void xz_screenshotDetected(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *screenshot = [ImageUtils captureScreen];
        if (screenshot) {
            [FloatingMenu showWithImage:screenshot];
        }
    });
}

#pragma mark - 初始化

static void xz_init() {
    // 注册截屏通知
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &xz_screenshotDetected,
        CFSTR("com.apple.springboard.screenshot"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    
    // 备选通知
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        UIImage *screenshot = [ImageUtils captureScreen];
        if (screenshot) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [FloatingMenu showWithImage:screenshot];
            });
        }
    }];
}

// 构造函数
__attribute__((constructor)) static void xz_ctor() {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if (![procName isEqualToString:@"SpringBoard"]) return;
        NSLog(@"[SN3] v2.05 loaded in SpringBoard");
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                xz_init();
            } @catch (NSException *e) {
                NSLog(@"[SN3] init crashed: %@ %@", e.name, e.reason);
            }
        });
    }
}