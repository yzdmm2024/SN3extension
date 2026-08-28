//
//  Tweak.xm — 超级截图 v5.3 入口（SpringBoard + 聊天 App 双注入）
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
//  进程分流：只在 SpringBoard 注册与响应。
//    （v3.14 的教训：cc.capture 是广播，若 App 进程也响应会同时弹两套窗口，
//      两边窗口状态互相干扰导致确认裁剪时闪退。）
//
//  注入范围：layout/.../Snapper3ZhExt.plist 的 Filter 写 com.apple.springboard（主逻辑）
//    + com.tencent.mqq / com.tencent.xin（v5.3 精确长截图：读真实 UIScrollView contentOffset）。
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
            NSLog(@"[SN3] 超级截图 v5.3 loaded in SpringBoard");
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
            // v5.3：精确长截图 —— 仅对目标聊天 App 注入，读真实 UIScrollView contentOffset
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
            if ([bid isEqualToString:@"com.tencent.mqq"] ||
                [bid isEqualToString:@"com.tencent.xin"]) {
                [AppScrollReporter setup];
                NSLog(@"[SN3] v5.3 AppScrollReporter enabled in %@", bid);
            }
        }
    }
}
