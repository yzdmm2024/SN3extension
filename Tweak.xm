//
//  Tweak.xm — 超级截图 v5.8 入口（SpringBoard + 聊天 App 双注入）
//
//  ────────────────────────────────────────────────────────────────────────
//  触发链：
//    控制中心「超级截图」按钮 (SN3CCModule，靠 CCSupport 加载)
//        └─ 先收起控制中心（见 SN3CCModule.setSelected:）
//        └─ 发 darwin 通知 com.axs.snapper3zhext.cc.capture
//            └─> 本文件收到 → [MaskCropWindow.sharedInstance show]   ← 窗口A
//                    ├─ 正常截图 → 抓屏裁剪 → 销毁A → [EditToolbarWindow showWithImage:] ← 窗口B
//                    └─ 长截图   → 双标尺调节 → 分段抓帧 → 拼接 → 销毁A → 窗口B
//
//  进程分流：SpringBoard 注册与响应；QQ/微信仅注册 AppScrollReporter（自动滚动驱动）。
//
//  注入范围：layout/.../Snapper3ZhExt.plist 的 Filter 写 com.apple.springboard（主逻辑）
//    + com.tencent.mqq / com.tencent.xin（v5.8 自动滚动长截图：驱动 UIScrollView 上报精确偏移）。
//    仍不要加 "*"——只注入必要的聊天 App，避免拖慢启动 / 触发安全模式。
//  ────────────────────────────────────────────────────────────────────────
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <notify.h>
#import "Common.h"
#import "MaskCropWindow.h"
#import "EditToolbarWindow.h"
#import "SN3Notify.h"
#import "AppScrollReporter.h"

// 控制中心点按 → 拉起窗口A（遮罩镂空框选）
static void xz_ccCapture(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // 双保险：进程名判断（Filter 已经限制 SB，这里再挡一层）
    NSString *proc = [NSProcessInfo processInfo].processName;
    if (![proc isEqualToString:@"SpringBoard"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 总开关（设置面板第一项，默认开）
            if (![Common boolPref:XZ_KEY_MENU_ENABLED default:YES]) {
                NSLog(@"[SN3] disabled by pref");
                return;
            }
            NSLog(@"[SN3] CC tapped -> show mask crop window (A)");
            [[MaskCropWindow sharedInstance] show];
        } @catch (NSException *e) {
            NSLog(@"[SN3] show mask failed: %@ %@", e.name, e.reason);
        }
    });
}

// 构造函数：SpringBoard 侧注册控制中心通知；QQ/微信侧注册精确滚动监听
__attribute__((constructor)) static void xz_ctor() {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if ([procName isEqualToString:@"SpringBoard"]) {
            NSLog(@"[SN3] 超级截图 v5.8 loaded in SpringBoard");
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CFNotificationCenterAddObserver(
                        CFNotificationCenterGetDarwinNotifyCenter(),
                        NULL,
                        &xz_ccCapture,
                        CFSTR("com.axs.snapper3zhext.cc.capture"),
                        NULL,
                        CFNotificationSuspensionBehaviorDeliverImmediately
                    );
                } @catch (NSException *e) {
                    NSLog(@"[SN3] init failed: %@ %@", e.name, e.reason);
                }
            });
        } else {
            // v5.8：自动滚动长截图 —— 仅对目标聊天 App 注入，驱动 UIScrollView 上报精确偏移
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
            if ([bid isEqualToString:@"com.tencent.mqq"] ||
                [bid isEqualToString:@"com.tencent.xin"]) {
                [AppScrollReporter setup];
                NSLog(@"[SN3] v5.8 AppScrollReporter enabled in %@", bid);
            }
        }
    }
}

// ────────────────────────────────────────────────────────────────────────
// v6.06：触发方式 —— 音量+电源键 拦截系统截图，改为拉起「超级截图」(实验性, 默认关)
//
// 原理：iOS 13–16 的系统截屏（音量+电源）由 BackBoardServices 的 SBScreenShotter
//       服务执行捕获。我们 %hook 它的 saveScreenshot / saveScreenshotWithOptions:
//       （iOS 16.5+ 改名带 Options，两个都 hook，运行时只生效存在的那个，另一个安全 no-op）。
//       当「音量+电源键触发」开关开启、且当前没有超级截图面板时，直接拉起 MaskCropWindow
//       并 return 跳过 %orig —— 即抑制原生截图，改用超级截图 UI。
// 风险：实验性。关闭后完全走系统原生截图，不影响其它功能。
// ────────────────────────────────────────────────────────────────────────
%hook SBScreenShotter

- (void)saveScreenshot {
    if ([Common boolPref:XZ_KEY_SS_TRIGGER default:NO] && ![MaskCropWindow isShowing]) {
        NSLog(@"[SN3] 音量+电源键 已拦截 -> 拉起超级截图");
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [[MaskCropWindow sharedInstance] show]; }
            @catch (NSException *e) { NSLog(@"[SN3] show on SS trigger failed: %@", e.reason); }
        });
        return; // 抑制原生截图
    }
    %orig;
}

- (void)saveScreenshotWithOptions:(id)options {
    if ([Common boolPref:XZ_KEY_SS_TRIGGER default:NO] && ![MaskCropWindow isShowing]) {
        NSLog(@"[SN3] 音量+电源键(opts) 已拦截 -> 拉起超级截图");
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [[MaskCropWindow sharedInstance] show]; }
            @catch (NSException *e) { NSLog(@"[SN3] show on SS trigger failed: %@", e.reason); }
        });
        return;
    }
    %orig;
}

%end
