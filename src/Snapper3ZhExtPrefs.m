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
//  ★ 标准 theos 懒加载 specifiers getter（v3.08 修正空白面板）：
//    - 父类 PSListController 自带 `specifiers` 属性（其 ivar 名为 _specifiers）。
//    - 子类中【绝不可】再声明 `NSArray *_specifiers;`，否则会生成第二个
//      _specifiers ivar，与父类错开；父类表格数据源读的是它自己的（nil），
//      于是点进去一片空白（有入口、无内容）。
//    - 正确做法：在父类前向声明里补上 `specifiers` 属性，让编译器认识
//      _specifiers，子类只 override getter，不重声明 ivar。
//    - 不能在 viewDidLoad 里 loadSpecifiersFromPlistName: + setSpecifiers:，
//      因为那时 self.bundle 可能还没挂好，会从 Preferences.app 主 bundle
//      找 Root.plist 返回 nil。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// 父类前向声明：补上 specifiers 属性，使子类 getter 里的 _specifiers 可被编译器识别
@interface PSListController : UIViewController
@property (nonatomic, retain) NSArray *specifiers;
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SN3PrefsController : PSListController
@end

@implementation SN3PrefsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
