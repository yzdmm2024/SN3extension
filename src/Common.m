//
//  Common.m
//
#import <CommonCrypto/CommonDigest.h>
#import "Common.h"

// v6.07: alert 关闭回调持有者（被 presentationController.delegate retain，防止提前释放）
@interface SN3AlertDismisser : NSObject <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) void (^onDismiss)(void);
@end
@implementation SN3AlertDismisser
- (void)presentationControllerDidDismiss:(UIPresentationController *)pc { if (_onDismiss) _onDismiss(); }
@end

// 顶层 alert 窗口 + 其 dismiss 回调对象的静态强引用。
// 关键点：UIPresentationController.delegate 是 weak，不会 retain 回调对象。
// 若不额外强引用，presentAlertOnTop: 返回后回调对象即被释放，
// 用户点「知道了」dismiss 时向僵尸对象发消息 → EXC_BAD_ACCESS → SpringBoard 崩 → 安全模式。
// 这里用静态强引用把对象撑到 dismiss 回调里再释放。
static __strong UIWindow *gSN3AlertWin = nil;
static __strong SN3AlertDismisser *gSN3AlertDismisser = nil;

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
// v6.07: 改为挂到独立顶层窗口(Alert+750)，稳盖过工具栏面板(≈2000)与选区窗(≈1990)，
//        彻底解决「OCR 失败提示框在选区/工具栏下面、点不了」的问题。
+ (void)sn3AlertError:(NSString *)title message:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentAlertOnTop:a];
    });
}

// v6.07/v6.08: 在独立 UIWindow(Alert+750) 上弹出 alert，保证位于所有截图 UI 之上、可点。
// v6.08 修复：delegate 是 weak，需用静态强引用 gSN3AlertDismisser 把回调对象撑到 dismiss 之后，
//            否则点「知道了」时回调对象已是僵尸 → 安全模式。
+ (void)presentAlertOnTop:(UIAlertController *)alert {
    if (!alert) return;
    UIWindowScene *scene = [self activeWindowScene];
    if (!scene) {
        // 兜底：挂到 keyWindow 的顶层 VC 上，至少把错误弹出来（不崩，只是可能仍被面板遮一点）
        UIWindow *kw = [self topWindow];
        UIViewController *host = kw ? [self topViewControllerFrom:kw] : nil;
        if (host && host.view.window) {
            [host presentViewController:alert animated:YES completion:nil];
        } else {
            NSLog(@"[SN3] presentAlertOnTop: 无 scene 且无 host，丢弃 alert");
        }
        return;
    }
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 750;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = root;
    gSN3AlertWin = w;
    SN3AlertDismisser *d = [SN3AlertDismisser new];
    d.onDismiss = ^{
        gSN3AlertWin = nil;
        gSN3AlertDismisser = nil;
    };
    alert.presentationController.delegate = d;
    gSN3AlertDismisser = d;        // 静态强引用，撑到 dismiss 回调
    [w makeKeyAndVisible];         // 关键：否则 alert 窗口不接收触摸，「知道了」点不了
    [root presentViewController:alert animated:YES completion:nil];
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
                // v5.25.6: 不再手动抬层。工具栏窗口已降到 Alert-10(1990) < 系统 alert(2000),
                // 弹窗由系统自然浮在工具栏之上, 且 dismiss 后正常清理, 无残留(修复「关不掉」)。
                [host presentViewController:vc animated:YES completion:nil];
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

#pragma mark - v6.07 大模型库解析

+ (NSArray<NSDictionary *> *)sn3ModelLibrary {
    NSString *json = [self stringPref:XZ_KEY_MODEL_LIB default:@""];
    if (!json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return @[];
    NSError *e = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:&e];
    if (![obj isKindOfClass:[NSArray class]]) return @[];
    return obj;
}

+ (void)sn3SetModelLibrary:(NSArray *)arr {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr ?: @[] options:0 error:&e];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    [self setPref:XZ_KEY_MODEL_LIB value:json];
}

+ (NSDictionary *)sn3ModelById:(NSString *)mid {
    if (!mid.length) return nil;
    for (NSDictionary *m in [self sn3ModelLibrary]) {
        if ([[m objectForKey:@"id"] isEqualToString:mid]) return m;
    }
    return nil;
}

+ (NSDictionary *)sn3AIConfig    { [self sn3MigrateModelsIfNeeded]; return [self sn3ModelById:[self stringPref:XZ_KEY_MODEL_AI    default:@""]]; }
+ (NSDictionary *)sn3OCRConfig   { [self sn3MigrateModelsIfNeeded]; return [self sn3ModelById:[self stringPref:XZ_KEY_MODEL_OCR   default:@""]]; }
+ (NSDictionary *)sn3TransConfig { [self sn3MigrateModelsIfNeeded]; return [self sn3ModelById:[self stringPref:XZ_KEY_MODEL_TRANS default:@""]]; }

+ (NSString *)sn3ModelField:(NSDictionary *)m key:(NSString *)k def:(NSString *)def {
    NSString *v = [m objectForKey:k];
    return (v && [v isKindOfClass:[NSString class]] && v.length) ? v : def;
}

// 一次性迁移：把旧的 AskAI_* / BigModel_* 配置并入模型库，老用户配置不丢，
// 也避免「三个功能各填一套、误点某项 BaseURL 就把 OCR/AI 一起带崩」。
+ (void)sn3MigrateModelsIfNeeded {
    if ([self boolPref:XZ_KEY_MODEL_MIGRATED default:NO]) return;
    [self setPref:XZ_KEY_MODEL_MIGRATED value:@YES];

    NSMutableArray *lib = [[self sn3ModelLibrary] mutableCopy];
    BOOL changed = NO;

    // 问 AI（OpenAI 兼容）
    NSString *aiKey  = [self stringPref:XZ_KEY_AI_KEY     default:@""];
    NSString *aiURL  = [self stringPref:XZ_KEY_AI_BASEURL default:@""];
    NSString *aiModel= [self stringPref:XZ_KEY_AI_MODEL   default:@""];
    if (aiKey.length || aiURL.length || aiModel.length) {
        if (![self sn3ModelById:@"mig_ai"]) {
            [lib addObject:@{@"id":@"mig_ai", @"name":@"我的对话模型",
                             @"baseURL":aiURL.length?aiURL:@"https://api.deepseek.com/v1",
                             @"apiKey":aiKey, @"model":aiModel.length?aiModel:@"deepseek-chat",
                             @"vendor":@"openai"}];
            [self setPref:XZ_KEY_MODEL_AI value:@"mig_ai"];
            changed = YES;
        }
    }

    // 识别引擎（智谱 BigModel）
    NSString *bmKey  = [self stringPref:XZ_KEY_BM_KEY     default:@""];
    NSString *bmURL  = [self stringPref:XZ_KEY_BM_BASEURL default:@""];
    NSString *bmModel= [self stringPref:XZ_KEY_BM_MODEL   default:@""];
    if (bmKey.length || bmURL.length || bmModel.length) {
        if (![self sn3ModelById:@"mig_ocr"]) {
            [lib addObject:@{@"id":@"mig_ocr", @"name":@"智谱 BigModel (识别)",
                             @"baseURL":bmURL.length?bmURL:@"https://open.bigmodel.cn/api/paas/v4",
                             @"apiKey":bmKey, @"model":bmModel.length?bmModel:@"glm-4v-flash",
                             @"vendor":@"zhipu"}];
            [self setPref:XZ_KEY_MODEL_OCR value:@"mig_ocr"];
            changed = YES;
        }
    }

    if (changed) [self sn3SetModelLibrary:lib];
}

@end