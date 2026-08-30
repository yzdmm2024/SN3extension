//
//  SN3License.m — 设备授权（UDID 解锁码验证）实现
//
#import "SN3License.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>

static NSString * const kSN3LicDomain  = @"com.axs.snapper3zhext";
static NSString * const kSN3LicUnlocked = @"License_Unlocked";
// 56 字符集（去掉易混淆的 0 O 1 l I）
static NSString * const kSN3Charset = @"23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz";

@implementation SN3License

+ (NSUserDefaults *)_defs {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:kSN3LicDomain];
    });
    return d;
}

#pragma mark - UDID

+ (NSString *)deviceUDID {
    static NSString *uid = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 私有 API：MGCopyAnswer("UniqueDeviceID")，经 dlopen MobileKeyBag 取符号
        void *h = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_LAZY);
        if (h) {
            NSString *(*mg)(NSString *) = dlsym(h, "MGCopyAnswer");
            if (mg) {
                @try { uid = mg(@"UniqueDeviceID"); } @catch (NSException *e) { uid = nil; }
            }
        }
        // 降级 1：老私有 API uniqueIdentifier
        if (!uid || !uid.length) {
            id dev = [UIDevice currentDevice];
            SEL s = NSSelectorFromString(@"uniqueIdentifier");
            if ([dev respondsToSelector:s]) {
                IMP imp = [dev methodForSelector:s];
                uid = ((id (*)(id, SEL))imp)(dev, s);
            }
        }
        // 降级 2：vendor id
        if (!uid || !uid.length) uid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        if (!uid || !uid.length) uid = @"unknown";
    });
    return uid;
}

#pragma mark - 解锁码

+ (NSString *)expectedCode {
    NSString *did = [self deviceUDID];
    const char *m = [did UTF8String];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)m, (CC_LONG)strlen(m), h);
    NSMutableString *code = [NSMutableString stringWithCapacity:15];
    for (int i = 0; i < 15; i++) {
        unsigned int v = ((unsigned int)h[i * 2 % CC_SHA256_DIGEST_LENGTH] << 8)
                        | (unsigned int)h[(i * 2 + 1) % CC_SHA256_DIGEST_LENGTH];
        [code appendFormat:@"%C", (unichar)kSN3Charset[v % kSN3Charset.length]];
    }
    return code;
}

+ (BOOL)verifyCode:(NSString *)code {
    if (!code) return NO;
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) return NO;
    return [code isEqualToString:[self expectedCode]];
}

#pragma mark - 状态

+ (BOOL)isUnlocked { return [[self _defs] boolForKey:kSN3LicUnlocked]; }
+ (void)setUnlocked:(BOOL)v {
    [[self _defs] setBool:v forKey:kSN3LicUnlocked];
    [[self _defs] synchronize];
}
+ (void)markUnlocked { [self setUnlocked:YES]; }
+ (void)revoke { [self setUnlocked:NO]; }

#pragma mark - 安全弹窗

+ (void)runOnMain:(dispatch_block_t)block {
    if (!block) return;
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// 自建非 key 窗口挂载 alert（SpringBoard 安全模式坑已避开：不 makeKeyAndVisible、hidden=NO、显式 frame）
+ (UIWindow *)_makeHostWindow {
    UIWindow *host = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)sc).activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)sc; break;
            }
        }
        if (!scene) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
            }
        }
        if (!scene) return nil;
        host = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        host = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    host.frame = [UIScreen mainScreen].bounds;
    host.windowLevel = UIWindowLevelAlert + 700;   // 高于 ResultWindow(≈2600)
    host.backgroundColor = [UIColor clearColor];
    host.rootViewController = [[UIViewController alloc] init];
    host.rootViewController.view.backgroundColor = [UIColor clearColor];
    host.hidden = NO;   // 关键：不抢 key window
    return host;
}

+ (void)toast:(NSString *)msg onHost:(UIWindow *)host {
    [self runOnMain:^{
        if (!host) return;
        CGFloat ww = host.bounds.size.width;
        CGFloat hgt = 40;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, host.bounds.size.height / 2 - hgt / 2, ww - 32, hgt)];
        l.text = msg;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        l.layer.cornerRadius = 10;
        l.layer.masksToBounds = YES;
        l.alpha = 0;
        [host addSubview:l];
        [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; }];
        [UIView animateWithDuration:0.2 delay:1.2 options:0
                         animations:^{ l.alpha = 0; }
                         completion:^(BOOL f) { [l removeFromSuperview]; }];
    }];
}

+ (void)presentVerificationFromWindow:(UIWindow *)win
                           completion:(void (^)(BOOL))completion {
    (void)win;  // 统一自建安全 host 窗口，不依赖传入窗口
    [self runOnMain:^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"设备授权验证"
                                                                   message:@"本插件已绑定设备 UDID，需输入解锁码才能使用。点「复制 UDID」把设备标识发给开发者生成解锁码。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"解锁码（15 位）";
            tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        UIWindow *host = [self _makeHostWindow];
        if (!host) {
            NSLog(@"[SN3] License: 无法创建 host 窗口，放弃弹窗");
            return;
        }

        __block BOOL resolved = NO;
        void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *toastMsg) {
            if (resolved) return;
            resolved = YES;
            [a dismissViewControllerAnimated:YES completion:^{
                if (toastMsg.length) [self toast:toastMsg onHost:host];
                // 弹窗关闭且 toast 显示期间保持 host 存活，之后释放
                [self performSelector:@selector(_releaseHost:) withObject:host afterDelay:1.6];
            }];
            if (completion) completion(ok);
        };

        [a addAction:[UIAlertAction actionWithTitle:@"复制 UDID"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            NSString *udid = [self deviceUDID];
            [[UIPasteboard generalPasteboard] setString:udid];
            // 直接把 UDID 显示到弹窗里（比在弹窗后加 toast 更可靠，toast 会被 alert 盖住）
            a.message = [NSString stringWithFormat:
                @"已复制本机 UDID 到剪贴板：\n%@\n\n把此标识发给开发者生成解锁码，再在下方输入。", udid];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"验证"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            NSString *input = a.textFields.firstObject.text ?: @"";
            if ([self verifyCode:input]) {
                [self markUnlocked];
                finish(YES, @"解锁成功，本机已授权");
            } else {
                [self toast:@"解锁码无效" onHost:host];   // 留在弹窗，等待正确输入
            }
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *act) {
            finish([self isUnlocked], nil);
        }]];

        if ([self isUnlocked]) {
            [a addAction:[UIAlertAction actionWithTitle:@"锁定本机"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *act) {
                [self revoke];
                finish(NO, @"已锁定本机，下次需重新验证");
            }]];
        }

        [host.rootViewController presentViewController:a animated:YES completion:nil];
    }];
}

+ (void)_releaseHost:(UIWindow *)host { (void)host; /* 释放引用，ARC 自动回收 */ }

@end
