//
//  Common.h
//  Snapper3ZhExt
//
//  共享常量与工具。偏好存放在默认域 com.axs.snapper3zhext
//
#import <UIKit/UIKit.h>

#define XZ_PREFS_DOMAIN     @"com.axs.snapper3zhext"

// 总开关（设置面板 Root.plist 第一项，Tweak.xm 中生效）
#define XZ_KEY_MENU_ENABLED     @"Menu_Enabled"

// 各插件开关
#define XZ_KEY_OCR_ENABLED      @"OCR_Enabled"
#define XZ_KEY_OCR_LANGS        @"OCR_Languages"
#define XZ_KEY_OCR_BD_APIKEY    @"OCR_Baidu_APIKey"       // v5.13：百度OCR(文字识别) 密钥（须与密钥成对填写才启用云端OCR）
#define XZ_KEY_OCR_BD_SECRET    @"OCR_Baidu_SecretKey"
#define XZ_KEY_LLM_OCR_ENABLED  @"LLM_OCR_Enabled"        // v5.17：用「AI 提问」里的多模态大模型(大模型OCR/豆包等)做免费OCR
#define XZ_KEY_TRANS_ENABLED    @"Translate_Enabled"
#define XZ_KEY_TRANS_APPID      @"Translate_APIAppID"
#define XZ_KEY_TRANS_KEY        @"Translate_APIKey"
#define XZ_KEY_TRANS_TARGET     @"Translate_TargetLang"
#define XZ_KEY_LONG_ENABLED     @"LongShot_Enabled"
#define XZ_KEY_LONG_OVERLAP     @"LongShot_Overlap"     // 帧重叠比例 (0~0.3)
#define XZ_KEY_LONG_MAXH        @"LongShot_MaxHeight"   // 最大拼接高度上限 (px)
#define XZ_KEY_LONG_INTERVAL    @"LongShot_Interval"    // 每帧滚动后的等待秒数
#define XZ_KEY_LONG_QUICK       @"LongShot_Quick"       // 长截图快速模式（更短间隔+更大步进）
#define XZ_KEY_AI_ENABLED       @"AskAI_Enabled"
#define XZ_KEY_AI_BASEURL       @"AskAI_BaseURL"
#define XZ_KEY_AI_KEY           @"AskAI_APIKey"
#define XZ_KEY_AI_MODEL         @"AskAI_Model"
#define XZ_KEY_AI_PROMPT        @"AskAI_Prompt"

// 长截图：帧间重叠比例（0~0.3），Vision 配准失败时的兜底值
#define XZ_LONG_OVERLAP_DEFAULT  0.50

@interface Common : NSObject
+ (BOOL)boolPref:(NSString *)key default:(BOOL)def;
+ (NSString *)stringPref:(NSString *)key default:(NSString *)def;
+ (void)setPref:(NSString *)key value:(id)value;
+ (NSArray<NSString *> *)ocrLanguages;      // 从偏好读取，默认 zh-Hans/zh-Hant/en-US
+ (UIImage *)systemIcon:(NSString *)name;   // SF Symbol 渲染成 UIImage（iOS>=13）
+ (void)toast:(NSString *)msg;              // 顶部轻量提示
+ (UIColor *)accentColor;
+ (UIWindow *)topWindow;
+ (UIWindowScene *)activeWindowScene;   // iOS 13+：弹窗必须挂到 scene 才能显示

#pragma mark - v4.1 新增

// 当前屏幕安全区（取 keyWindow 的 safeAreaInsets，取不到时按顶部 20pt 兜底）
+ (UIEdgeInsets)screenSafeInsets;

// 最上层可 present 的 ViewController（沿 presentedViewController 链走到最后）
// 窗口B 自带 rootViewController，present 一律走它，不再依赖 SpringBoard 的 keyWindow
+ (UIViewController *)topViewControllerFrom:(UIWindow *)win;

// 安全 present：找不到承载 VC 时降级为 toast，避免静默失败
+ (void)present:(UIViewController *)vc fromWindow:(UIWindow *)win;

// 主线程执行（darwin 通知回调不在主线程）
+ (void)runOnMain:(dispatch_block_t)block;

@end