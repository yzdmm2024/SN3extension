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
+ (void)setPref:(NSString *)key value:(id)value {
    [[self defaults] setObject:value forKey:key];
    [[self defaults] synchronize];
}

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
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

@end