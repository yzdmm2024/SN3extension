//
//  Snapper3ZhExtPrefs.m — 设置面板控制器
//
//  自定义 PSListController 子类，PreferenceLoader 加载本 bundle 后
//  实例化此类，自动读取 Root.plist 渲染设置项。
//
//  v1.1.7 — 修复：PSListController 提供 setSpecifiers: 方法，
//  调用该方法可正确设置 _specifiers ivar 并刷新 tableView。
//  比起直接操作 ivar，使用 KVC 调用 setSpecifiers: 更安全可靠。
//
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@property (nonatomic, retain, readonly) NSArray *specifiers;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (void)reloadSpecifiers;
@end

@interface Snapper3ZhExtPrefsController : PSListController
@end

@implementation Snapper3ZhExtPrefsController {
    NSArray *_mySpecifiers;
}

- (id)specifiers {
    if (!_mySpecifiers) {
        _mySpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        // PSListController 的 tableView 数据源直接访问 _specifiers ivar，
        // 直接调用 setSpecifiers: 方法让父类更新 ivar 并刷新 tableView。
        // 注意：不能用 setValue:forKey:@"specifiers" 因为 readonly 属性
        // 可能导致 KVC 不触发 setter。
        if (_mySpecifiers) {
            [self performSelector:@selector(setSpecifiers:) withObject:_mySpecifiers];
        }
    }
    return _mySpecifiers;
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadSpecifiers];
}

@end