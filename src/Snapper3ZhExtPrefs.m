//
//  Snapper3ZhExtPrefs.m — 设置面板控制器
//
//  关键约定（三处必须完全一致，缺一面板就不出现）：
//    1. 本文件编译出的类名            : SN3PrefsController
//    2. bundle Info.plist 的 NSPrincipalClass : SN3PrefsController
//    3. PreferenceLoader plist 的 detail      : SN3PrefsController
//
//  面板内容来自 bundle 内的 Root.plist（specifier 列表），
//  读写域为 com.axs.snapper3zhext（与 Tweak 的 Common.h 一致）。
//
//  ★ 必须用「懒加载 specifiers getter」而不能在 viewDidLoad 里
//    loadSpecifiersFromPlistName: + setSpecifiers: —— 后者在 bundle
//    还没挂到 self.bundle 时就执行，会从 Preferences.app 主 bundle
//    找 Root.plist，返回 nil，结果面板空白（有入口、点进去啥也没有）。
//

@interface PSListController : UIViewController
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SN3PrefsController : PSListController {
    NSArray *_specifiers;   // 与 PSListController 原生 _specifiers 同名但属本子类，由下方 getter 接管
}
@end

@implementation SN3PrefsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
