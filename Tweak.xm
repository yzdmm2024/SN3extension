//
//  Tweak.xm — 独立插件 v3.06：截屏 → 浮动菜单 + 控制中心触发
//  所有功能模块通过运行时调用，避免编译时强依赖导致崩溃
//
//  触发源：
//    1. 系统截屏通知（com.apple.springboard.screenshot / UIApplicationUserDidTakeScreenshotNotification）
//    2. 控制中心模块 SN3CCModule 发出的 darwin 通知 com.axs.snapper3zhext.cc.capture
//
//  设置面板（com.axs.snapper3zhext 域）：
//    Menu_Enabled 总开关在此生效；其余功能开关由 FloatingMenu 内部实时读取。
//

#import <UIKit/UIKit.h>
#import "Common.h"
#import "FloatingMenu.h"
#import "ImageUtils.h"

#pragma mark - 工具

static void xz_showMenu(void) {
    // 总开关（设置面板里的 Menu_Enabled，默认开）
    if (![Common boolPref:XZ_KEY_MENU_ENABLED default:YES]) return;
    @try {
        UIImage *screenshot = [ImageUtils captureScreen];
        if (screenshot) {
            [FloatingMenu showWithImage:screenshot];
        }
    } @catch (NSException *e) {
        NSLog(@"[SN3] showMenu crashed: %@ %@", e.name, e.reason);
    }
}

#pragma mark - 事件回调

static void xz_screenshotDetected(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        xz_showMenu();
    });
}

// 控制中心按钮点按（SN3CCModule 发来）
static void xz_ccCapture(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[SN3] CC capture triggered");
        xz_showMenu();
    });
}

#pragma mark - 初始化

static void xz_init() {
    // 1. 系统截屏通知
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &xz_screenshotDetected,
        CFSTR("com.apple.springboard.screenshot"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 2. 控制中心模块通知
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &xz_ccCapture,
        CFSTR("com.axs.snapper3zhext.cc.capture"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 3. 备选通知
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            xz_showMenu();
        });
    }];
}

// 构造函数
__attribute__((constructor)) static void xz_ctor() {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if (![procName isEqualToString:@"SpringBoard"]) return;
        NSLog(@"[SN3] v3.06 loaded in SpringBoard");
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                xz_init();
            } @catch (NSException *e) {
                NSLog(@"[SN3] init crashed: %@ %@", e.name, e.reason);
            }
        });
    }
}
