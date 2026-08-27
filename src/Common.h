//
//  Common.h
//  Snapper3ZhExt
//
//  共享常量与工具。偏好存放在默认域 com.axs.snapper3zhext
//
#import <UIKit/UIKit.h>

#define XZ_PREFS_DOMAIN     @"com.axs.snapper3zhext"

// 各插件开关
#define XZ_KEY_OCR_ENABLED      @"OCR_Enabled"
#define XZ_KEY_OCR_LANGS        @"OCR_Languages"
#define XZ_KEY_TRANS_ENABLED    @"Translate_Enabled"
#define XZ_KEY_TRANS_APPID      @"Translate_APIAppID"
#define XZ_KEY_TRANS_KEY        @"Translate_APIKey"
#define XZ_KEY_TRANS_TARGET     @"Translate_TargetLang"
#define XZ_KEY_LONG_ENABLED     @"LongShot_Enabled"
#define XZ_KEY_LONG_OVERLAP     @"LongShot_Overlap"     // 帧重叠比例 (0~0.3)
#define XZ_KEY_LONG_MAXH        @"LongShot_MaxHeight"   // 最大拼接高度上限 (px)
#define XZ_KEY_LONG_INTERVAL    @"LongShot_Interval"    // 每帧滚动后的等待秒数
#define XZ_KEY_AI_ENABLED       @"AskAI_Enabled"
#define XZ_KEY_AI_BASEURL       @"AskAI_BaseURL"
#define XZ_KEY_AI_KEY           @"AskAI_APIKey"
#define XZ_KEY_AI_MODEL         @"AskAI_Model"
#define XZ_KEY_AI_PROMPT        @"AskAI_Prompt"

// 各插件注册到 Snapper3 的 pluginIdentifier
#define XZ_ID_OCR      @"com.axs.snapper3zhext.zhocr"
#define XZ_ID_TRANS    @"com.axs.snapper3zhext.translate"
#define XZ_ID_LONG     @"com.axs.snapper3zhext.longshot"
#define XZ_ID_AI       @"com.axs.snapper3zhext.askai"

@interface Common : NSObject
+ (BOOL)boolPref:(NSString *)key default:(BOOL)def;
+ (NSString *)stringPref:(NSString *)key default:(NSString *)def;
+ (void)setPref:(NSString *)key value:(id)value;
+ (NSArray<NSString *> *)ocrLanguages;      // 从偏好读取，默认 zh-Hans/zh-Hant/en-US
+ (UIImage *)systemIcon:(NSString *)name;   // SF Symbol 渲染成 UIImage（iOS>=13）
+ (void)toast:(NSString *)msg;              // 顶部轻量提示
+ (UIColor *)accentColor;
+ (UIWindow *)topWindow;
@end