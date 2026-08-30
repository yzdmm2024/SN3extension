//
//  SN3AppDelegate.m — 超级截图「套壳」companion App（v6.17）
//
//  职责：主屏图标 + snapper:// URL Scheme 入口。
//    · 点图标               → 显示一个极简 UI（开始截图 / 打开设置）
//    · snapper://capture    → notify_post 唤醒 Tweak.xm 的 xz_ccCapture，拉起截图浮层
//    · snapper://settings   → 打开本插件设置面板
//  截图浮层本身由 tweak（注入 SpringBoard 的 MaskCropWindow）提供，
//  App 退出/后台化后浮层显示在 SpringBoard 主屏之上。
//
#import "SN3AppDelegate.h"
#import "SN3ViewController.h"
#include <notify.h>
#include <stdlib.h>

#define SN3_NOTIFY_NAME "com.axs.snapper3zhext.cc.capture"

@implementation SN3AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    SN3ViewController *vc = [[SN3ViewController alloc] init];
    vc.delegate = self;
    self.window.rootViewController = vc;
    self.window.backgroundColor = [UIColor colorWithRed:0.0/255.0 green:122.0/255.0 blue:255.0/255.0 alpha:1.0];
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    if ([[url scheme] isEqualToString:@"snapper"]) {
        NSString *host = [url host];
        if ([host isEqualToString:@"capture"]) {
            [self triggerCapture];
        } else if ([host isEqualToString:@"settings"]) {
            [self openSettings];
        }
    }
    return YES;
}

- (void)triggerCapture {
    // 与控制中心按钮完全相同的通知名：Tweak.xm 已在 SpringBoard 注册监听。
    notify_post(SN3_NOTIFY_NAME);
    // 短暂延时后退出 App，让 SpringBoard 上的截图浮层可见（App 不再盖住浮层）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(0);
    });
}

- (void)openSettings {
    NSURL *u = [NSURL URLWithString:@"prefs:root=com.axs.snapper3zhext"];
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

@end
