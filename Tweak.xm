//
//  Tweak.xm — 超级截图 v4.0 入口（SpringBoard Tweak）
//
//  触发链：
//   控制中心「超级截图」按钮(SN3CCModule) → darwin 通知 com.axs.snapper3zhext.cc.capture
//   → 本文件收到 → 弹【窗口A】遮罩镂空框选（MaskCropWindow）
//   → 正常截图/长截图完成 → 弹【窗口B】编辑工具栏（EditToolbarWindow）
//
//  进程分流：只 SpringBoard 响应；App 进程不注册（App 内不弹）。
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Common.h"
#import "MaskCropWindow.h"

// 控制中心按钮点按（CC 已收起）
static void xz_ccCapture(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *proc = [NSProcessInfo processInfo].processName;
    if (![proc isEqualToString:@"SpringBoard"]) return;   // 只 SB 弹窗口
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[SN3] CC -> show mask crop window");
        @try {
            [MaskCropWindow.sharedInstance show];   // 窗口A：遮罩 + 框选 + 底部3按钮
        } @catch (NSException *e) {
            NSLog(@"[SN3] show mask failed: %@ %@", e.name, e.reason);
        }
    });
}

// 构造函数：只 SpringBoard 注册通知
__attribute__((constructor)) static void xz_ctor() {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if (![procName isEqualToString:@"SpringBoard"]) return;
        NSLog(@"[SN3] supershot v4.0 loaded in SpringBoard");
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
    }
}
