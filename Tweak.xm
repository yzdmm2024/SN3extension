//
//  Tweak.xm — 独立插件 v3.13：控制中心收起后截屏 + 长截图滚动拼接（App 进程）
//
//  触发源：
//    1. 控制中心模块 SN3CCModule 发出的 darwin 通知 com.axs.snapper3zhext.cc.capture
//       （点按时已先关闭控制中心，Tweak 延迟截屏拿真实屏幕）
//    2. 系统截屏通知（com.apple.springboard.screenshot / UIApplicationUserDidTakeScreenshotNotification）
//    3. 长截图通知 com.axs.snapper3zhext.cc.longshot（选择器点「长截图」发出）
//
//  进程分流（本 tweak 注入所有进程，filter 见 Snapper3ZhExt.plist）：
//    - SpringBoard：处理 截屏 + 选择器 + 自由截图；收到 cc.longshot 忽略（App 来做）
//    - 普通 App：处理 滚动长截图拼接（App 内拿 scrollview 才安全）
//
//  设置面板（com.axs.snapper3zhext 域）：
//    Menu_Enabled 总开关在此生效；其余功能开关由 FloatingMenu 内部实时读取。
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Common.h"
#import "FloatingMenu.h"
#import "ImageUtils.h"

#pragma mark - 工具

static void xz_showMenu(void) {
    // 总开关（设置面板里的 Menu_Enabled，默认开）
    if (![Common boolPref:XZ_KEY_MENU_ENABLED default:YES]) return;
    @try {
        // 控制中心模块已 dismiss CC；这里再等 0.35s 确保收起动画完全结束，双保险
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIImage *screenshot = [ImageUtils captureScreen];
            if (screenshot) {
                [FloatingMenu showChooser:screenshot];
            }
        });
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

// 控制中心按钮点按（SN3CCModule 发来，此时 CC 已收起）
static void xz_ccCapture(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[SN3] CC capture triggered");
        xz_showMenu();
    });
}

// 长截图：选择器点「长截图」后发出。
// SpringBoard 进程忽略（App 进程负责滚动拼接）；普通 App 进程执行滚动拼接。
static void xz_ccLongShot(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *proc = [NSProcessInfo processInfo].processName;
    if ([proc isEqualToString:@"SpringBoard"]) {
        NSLog(@"[SN3] longshot: SB ignores (App will do)");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [Common toast:@"正在滚动生成长截图..."];
        Class longShot = NSClassFromString(@"LongShotController");
        if (!longShot) { [Common toast:@"长截图模块未加载"]; return; }
        SEL sel = NSSelectorFromString(@"captureStitchedInCurrentProcessCompletion:");
        if ([longShot respondsToSelector:sel]) {
            void (*func)(id, SEL, void(^)(UIImage*)) = (void(*)(id, SEL, void(^)(UIImage*)))[longShot methodForSelector:sel];
            func(longShot, sel, ^(UIImage *img) {
                if (img) {
                    [FloatingMenu showActionRow:img];
                } else {
                    [Common toast:@"长截图失败，请确认页面可滚动"];
                }
            });
        }
    });
}

#pragma mark - 初始化

static void xz_init() {
    NSString *proc = [NSProcessInfo processInfo].processName;
    BOOL isSB = [proc isEqualToString:@"SpringBoard"];

    // 1. 系统截屏通知：只在 SpringBoard 注册（App 内物理截图让 iOS 自带编辑 UI 处理，
    //    避免双 UI；App 内按 CC 或长截图通知才弹我们的菜单）
    if (isSB) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            &xz_screenshotDetected,
            CFSTR("com.apple.springboard.screenshot"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                xz_showMenu();
            });
        }];
    }

    // 2. 控制中心模块通知（CC 收起后发出；SB 弹选择器，App 内同样可用）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &xz_ccCapture,
        CFSTR("com.axs.snapper3zhext.cc.capture"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 3. 长截图通知（选择器点「长截图」发出；SB 忽略，App 进程滚动拼接）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &xz_ccLongShot,
        CFSTR("com.axs.snapper3zhext.cc.longshot"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

// 构造函数：注入所有进程，只初始化有 UI 的进程（SpringBoard 或普通 App）
__attribute__((constructor)) static void xz_ctor() {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        BOOL isSB = [procName isEqualToString:@"SpringBoard"];
        BOOL hasUI = [UIApplication sharedApplication] != nil;
        if (!isSB && !hasUI) return;
        NSLog(@"[SN3] v3.13 loaded in %@", procName);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                xz_init();
            } @catch (NSException *e) {
                NSLog(@"[SN3] init crashed: %@ %@", e.name, e.reason);
            }
        });
    }
}
