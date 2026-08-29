//
//  Common.m
//
#import <CommonCrypto/CommonDigest.h>
#import "Common.h"

@implementation Common

+ (NSUserDefaults *)defaults {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    });
    return d;
}

+ (BOOL)boolPref:(NSString *)key default:(BOOL)def {
    id v = [[self defaults] objectForKey:key];
    return v ? [v boolValue] : def;
}
+ (NSString *)stringPref:(NSString *)key default:(NSString *)def {
    NSString *v = [[self defaults] stringForKey:key];
    return v && v.length ? v : def;
}
+ (int)intPref:(NSString *)key default:(int)def {
    id v = [[self defaults] objectForKey:key];
    return v ? [v intValue] : def;
}
+ (void)setPref:(NSString *)key value:(id)value {
    [[self defaults] setObject:value forKey:key];
    [[self defaults] synchronize];
}

// v5.23.0: 此方法保留, 供 VisionOCR / 翻译/AskAI 三个 plugin 内部使用. 主 OCR 入口已改走智谱 BigModel, 不依赖此方法.
+ (NSArray<NSString *> *)ocrLanguages {
    id v = [[self defaults] objectForKey:XZ_KEY_OCR_LANGS];
    if ([v isKindOfClass:[NSArray class]] && [v count]) return v;
    if ([v isKindOfClass:[NSString class]]) {
        NSArray *parts = [v componentsSeparatedByString:@","];
        NSMutableArray *out_ = [NSMutableArray array];
        for (NSString *p in parts) {
            NSString *s = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (s.length) [out_ addObject:s];
        }
        if (out_.count) return out_;
    }
    return @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
}

+ (UIImage *)systemIcon:(NSString *)name {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

+ (UIColor *)accentColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemBlueColor];
    }
    return [UIColor blueColor];
}

+ (void)toast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [self topWindow];
        if (!w) return;
        CGFloat h = 46;
        CGFloat ww = w.bounds.size.width;
        CGFloat off = w.safeAreaInsets.top + 8;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, off - h, ww - 32, h)];
        l.text = msg;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        l.layer.cornerRadius = 12;
        l.layer.masksToBounds = YES;
        [w addSubview:l];
        [UIView animateWithDuration:0.25 delay:0.05 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ l.frame = CGRectMake(16, off, ww - 32, h); }
                         completion:^(BOOL fin){
            [UIView animateWithDuration:0.25 delay:1.6 options:UIViewAnimationOptionCurveEaseIn
                             animations:^{ l.alpha = 0; }
                             completion:^(BOOL f){ [l removeFromSuperview]; }];
        }];
    });
}

// v5.23.0: OCR/网络等失败时弹的 alert (不静默, 用户必须看到)
+ (void)sn3AlertError:(NSString *)title message:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [self topWindow];
        if (!w) return;
        UIViewController *root = w.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        if (!root) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        CGFloat baseLevel = w.windowLevel;
        [root presentViewController:a animated:YES completion:^{
            // v5.25.4: 同样抬到工具栏(windowLevel=Alert+200)之上, 否则错误提示也会被遮罩盖住
            if (a.view.window) a.view.window.windowLevel = baseLevel + 50;
        }];
    });
}

+ (UIWindow *)topWindow {
    NSArray *scenes;
    if (@available(iOS 13.0, *)) {
        NSSet *set = [UIApplication sharedApplication].connectedScenes;
        scenes = set.allObjects;
    }
    if (scenes.count) {
        id scene = scenes.firstObject;
        for (UIWindow *w in [scene valueForKey:@"windows"]) {
            if (w.isKeyWindow) return w;
        }
        id win = [scene valueForKey:@"keyWindow"];
        if (win) return win;
    }
    return [UIApplication sharedApplication].keyWindow;
}

+ (UIWindowScene *)activeWindowScene {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *active = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                active = (UIWindowScene *)scene;
                break;
            }
        }
        if (!active) {
            // 兜底：任意已连接的 window scene。SpringBoard 的激活态判定有时不稳，
            // 若 windowScene 取到 nil，UIWindow 在 iOS13+ 会因未挂到 scene 而不显示，
            // 表现为「截图完成但两排工具栏不弹」。这里兜底保证窗口一定能挂上场景。
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) { active = (UIWindowScene *)scene; break; }
            }
        }
        return active;
    }
    return nil;
}

#pragma mark - v4.1 新增

+ (UIEdgeInsets)screenSafeInsets {
    if (@available(iOS 11.0, *)) {
        UIWindow *w = [self topWindow];
        if (w) return w.safeAreaInsets;
    }
    return UIEdgeInsetsMake(20, 0, 0, 0);
}

+ (UIViewController *)topViewControllerFrom:(UIWindow *)win {
    UIViewController *root = win.rootViewController;
    NSInteger guard = 0;
    while (root.presentedViewController && guard++ < 16) {
        root = root.presentedViewController;
    }
    return root;
}

+ (void)present:(UIViewController *)vc fromWindow:(UIWindow *)win {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *host = [self topViewControllerFrom:win];
            if (!host) host = [self topViewControllerFrom:[self topWindow]];
            if (host && host.view.window) {
                CGFloat baseLevel = win.windowLevel;
                [host presentViewController:vc animated:YES completion:^{
                    // v5.25.4: OCR/翻译/识别结果弹窗必须盖在工具栏(windowLevel=Alert+200)之上。
                    // UIAlertController 默认 Alert 层级低于工具栏, 会被全屏半透明遮罩挡住, 导致看不清。
                    // 弹窗窗口滞后一级, 保证浮在工具栏上方。
                    if (vc.view.window) vc.view.window.windowLevel = baseLevel + 50;
                }];
            } else {
                NSLog(@"[SN3] present failed: no host view controller");
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] present exception: %@ %@", e.name, e.reason);
        }
    });
}

+ (void)runOnMain:(dispatch_block_t)block {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@end