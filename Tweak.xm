//
//  Tweak.xm — 把自己注册进 Snapper3 的插件系统
//
//  Snapper3 本体自带插件管理器 Snapper3PluginManager，提供 registerPlugin:。
//  我们像 Snapper3 Expand 一样，在注入 SpringBoard 后把 4 个功能插件注册进去，
//  就会出现在 Snapper3 截图动作菜单里。这里通过 hook Snapper3PluginManager 的
//  初始化入口做一次惰性注册，避免 dylib 加载顺序问题。
//
#import "PluginBase.h"
#import "ZhOCRPlugin.h"
#import "TranslatePlugin.h"
#import "LongScreenshotPlugin.h"
#import "AskAIPlugin.h"
#import "Common.h"

// Snapper3PluginManager 是私有类，未在本工程声明 @interface，
// 需先补一份声明，否则 clang 视其为 forward declaration，%hook 无法解析其方法。
@interface Snapper3PluginManager : NSObject
+ (id)sharedInstance;
+ (id)defaultManager;
- (instancetype)init;
- (void)registerPlugin:(id)plugin;
@end

// 同级静态函数承担注册逻辑，避免在 %hook 内自定义 _xz_ 前缀类方法
// （Logos 不会为这类自定义方法生成可见声明，直接调用会编译报错）。
//
// 崩溃背景：SN3延伸板 与本机同时安装的 Snapper3Expand 都 hook 了
// Snapper3PluginManager。Snapper3Expand 的 registerPlugin: 钩子会向插件对象发送
// 额外的 selector，若未实现则抛 "unrecognized selector" 异常；该异常若从本 dylib
// 的 dispatch_once 块逃逸，会直接 SIGABRT 进安全模式。因此把每个插件的实例化与
// 注册都单独用 @try/@catch 兜住，单个失败绝不影响 SpringBoard。
static void xz_registerPlugins(id manager) {
    if (!manager) return;
    if (![manager respondsToSelector:@selector(registerPlugin:)]) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<Class> *classes = @[
            [ZhOCRPlugin class],
            [TranslatePlugin class],
            [LongScreenshotPlugin class],
            [AskAIPlugin class],
        ];
        NSMutableArray *plugins = [NSMutableArray arrayWithCapacity:classes.count];
        for (Class c in classes) {
            id p = nil;
            @try { p = [c new]; }
            @catch (NSException *e) {
                NSLog(@"[Snapper3ZhExt] instantiate %@ failed: %@", NSStringFromClass(c), e);
                continue;
            }
            if (!p) continue;
            if ([p respondsToSelector:@selector(shouldRegister)] && ![p shouldRegister]) continue;
            [plugins addObject:p];
        }
        NSUInteger ok = 0;
        for (id p in plugins) {
            @try {
                [manager performSelector:@selector(registerPlugin:) withObject:p];
                ok++;
            } @catch (NSException *e) {
                NSLog(@"[Snapper3ZhExt] registerPlugin %@ failed: %@",
                      [p respondsToSelector:@selector(pluginIdentifier)] ? [p pluginIdentifier] : NSStringFromClass([p class]),
                      e);
            }
        }
        NSLog(@"[Snapper3ZhExt] registered %lu/%lu plugins", (unsigned long)ok, (unsigned long)plugins.count);
    });
}

%hook Snapper3PluginManager
// 覆盖 manager 的 class 工厂方法，保证在其首次创建时完成插件注册
+ (id)sharedInstance {
    id m = %orig;
    xz_registerPlugins(m);
    return m;
}
+ (id)defaultManager {
    id m = %orig;
    xz_registerPlugins(m);
    return m;
}
- (id)init {
    id m = %orig;
    xz_registerPlugins(m);
    return m;
}

%end