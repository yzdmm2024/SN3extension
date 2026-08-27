//
//  Snapper3ZhExtPrefs.m — 设置面板控制器
//
//  自定义 PSListController 子类，PreferenceLoader 加载本 bundle 后
//  实例化此类，自动读取 Root.plist 渲染设置项。
//
//  v1.1.6 — 修复：PSListController 内部使用 _specifiers ivar 驱动 tableView，
//  必须同时设置父类的 _specifiers 和 reloadSpecifiers 才能正确渲染。
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface PSListController : UIViewController
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@property (nonatomic, retain, readonly) NSArray *specifiers;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (void)reloadSpecifiers;
@end

@interface PSViewController : UIViewController
@end

@interface Snapper3ZhExtPrefsController : PSListController
@end

@implementation Snapper3ZhExtPrefsController {
    NSArray *_mySpecifiers;
}

- (id)specifiers {
    if (!_mySpecifiers) {
        _mySpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        // PSListController 的 tableView 数据源方法直接访问 _specifiers ivar，
        // 而不是通过 self.specifiers getter，所以必须同步设置父类的 ivar。
        // 使用 KVC 或 ivar 直接赋值来确保父类也能访问到 specifiers。
        if (_mySpecifiers) {
            object_setIvar(self, class_getInstanceVariable([PSListController class], "_specifiers"), _mySpecifiers);
        }
    }
    return _mySpecifiers;
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 强制刷新 tableView，确保 specifiers 变更被应用到 table view
    [self reloadSpecifiers];
}

@end