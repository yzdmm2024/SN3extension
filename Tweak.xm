//
//  Tweak.xm — 极简版 v2.04：仅截屏检测 + 弹窗，定位崩溃原因
//

#import <UIKit/UIKit.h>

#pragma mark - 截屏检测

static void xz_screenshotDetected(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 弹一个简单的提示框
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SN3延伸板"
                                                                       message:@"截屏已检测到"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        
        UIWindow *keyWin = nil;
        if (@available(iOS 15.0, *)) {
            UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
            keyWin = scene.keyWindow;
        } else {
            keyWin = [UIApplication sharedApplication].keyWindow;
        }
        if (keyWin && keyWin.rootViewController) {
            [keyWin.rootViewController presentViewController:alert animated:YES completion:nil];
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
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SN3延伸板"
                                                                           message:@"截屏已检测到 (备选)"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            
            UIWindow *keyWin = nil;
            if (@available(iOS 15.0, *)) {
                UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
                keyWin = scene.keyWindow;
            } else {
                keyWin = [UIApplication sharedApplication].keyWindow;
            }
            if (keyWin && keyWin.rootViewController) {
                [keyWin.rootViewController presentViewController:alert animated:YES completion:nil];
            }
        });
    }];
}

// 构造函数
__attribute__((constructor)) static void xz_ctor() {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if (![procName isEqualToString:@"SpringBoard"]) return;
        NSLog(@"[SN3] v2.04 minimal tweak loaded in SpringBoard");
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                xz_init();
            } @catch (NSException *e) {
                NSLog(@"[SN3] init crashed: %@ %@", e.name, e.reason);
            }
        });
    }
}