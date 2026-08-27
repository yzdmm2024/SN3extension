//
//  Tweak.xm — 独立插件：截屏 → 浮动菜单 → 全功能操作
//
//  不再依赖 Snapper3，独立检测截屏并弹出浮动操作菜单。
//  所有功能：OCR / 翻译 / AI对话 / 长截图 / 自由截图 /
//  保存相册 / 复制粘贴 / 悬浮贴图 / 分享
//

#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

// 功能插件
#import "VisionOCR.h"
#import "TranslateEngine.h"
#import "AskAIEngine.h"
#import "LongShotController.h"
#import "Common.h"
#import "FloatingMenu.h"
#import "ImageUtils.h"

// Snapper3PluginManager 声明（兼容 Snapper3 用户）
@interface Snapper3PluginManager : NSObject
+ (id)sharedInstance;
- (void)registerPlugin:(id)plugin;
@end

#pragma mark - 截屏检测

// 监听系统截屏通知，弹出浮动菜单
static void xz_screenshotDetected(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // 延迟 0.5 秒确保截屏已完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 获取当前屏幕截图
        UIImage *screenshot = [ImageUtils captureScreen];
        if (!screenshot) return;
        
        // 显示浮动菜单
        [FloatingMenu showWithImage:screenshot];
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
    
    // 备选：监听 UIApplicationUserDidTakeScreenshotNotification
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        UIImage *screenshot = [ImageUtils captureScreen];
        if (screenshot) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [FloatingMenu showWithImage:screenshot];
            });
        }
    }];
    
    // 继续作为 Snapper3 插件注册（兼容已安装 Snapper3 的用户）
    // 延迟 5 秒确保 Snapper3 已加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id mgr = [objc_getClass("Snapper3PluginManager") sharedInstance];
        if (mgr && [mgr respondsToSelector:@selector(registerPlugin:)]) {
            NSArray *plugins = @[
                @"ZhOCRPlugin",
                @"TranslatePlugin",
                @"LongScreenshotPlugin",
                @"AskAIPlugin"
            ];
            for (NSString *cn in plugins) {
                id p = [objc_getClass([cn UTF8String]) new];
                if (p) [mgr registerPlugin:p];
            }
        }
    });
}

// 构造函数
__attribute__((constructor)) static void xz_ctor() {
    // 仅 SpringBoard 中初始化，防止后台进程崩溃进安全模式
    NSString *procName = [NSProcessInfo processInfo].processName;
    if (![procName isEqualToString:@"SpringBoard"]) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        xz_init();
    });
}