//
//  TranslatePlugin.m — 先本地 OCR 中文识别，再送百度翻译
//
#import "TranslatePlugin.h"
#import "VisionOCR.h"
#import "TranslateEngine.h"
#import "ResultWindow.h"
#import "Common.h"

@implementation TranslatePlugin

- (NSString *)pluginIdentifier { return XZ_ID_TRANS; }
- (BOOL)shouldRegister { return YES; }
- (UIImage *)imageForMenuAndSettings { return [Common systemIcon:@"character.bubble"]; }

- (BOOL)configured {
    NSString *appid = [Common stringPref:XZ_KEY_TRANS_APPID default:@""];
    NSString *key = [Common stringPref:XZ_KEY_TRANS_KEY default:@""];
    return appid.length && key.length;
}

- (void)runWithImage:(UIImage *)image {
    if (![self configured]) {
        [Common toast:@"请先在设置中填写百度翻译 AppID / 密钥"];
        return;
    }
    [Common toast:@"识别并翻译…"];
    [VisionOCR recognizeImage:image languages:[Common ocrLanguages] completion:^(NSString *text) {
        if (!text.length) {
            [ResultWindow showWithTitle:@"翻译" text:@"未识别到文字" image:image];
            return;
        }
        NSString *appid = [Common stringPref:XZ_KEY_TRANS_APPID default:@""];
        NSString *key   = [Common stringPref:XZ_KEY_TRANS_KEY default:@""];
        NSString *to    = [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh"];
        [TranslateEngine translateText:text fromLang:@"auto" toLang:to
                                 appid:appid appKey:key completion:^(NSString *out, NSString *err) {
            if (err) {
                [ResultWindow showWithTitle:@"翻译失败" text:err image:image];
                return;
            }
            NSString *res = [NSString stringWithFormat:@"【原文】\n%@\n\n【译文】\n%@", text, out];
            [ResultWindow showWithTitle:@"翻译" text:res image:image];
        }];
    }];
}

@end