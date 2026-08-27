//
//  Snapper3ZhExtPrefs.m — 设置面板控制器
//
//  自定义 PSListController 子类，PreferenceLoader 加载本 bundle 后
//  实例化此类，自动读取 Root.plist 渲染设置项。
//
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@property (nonatomic, retain, readonly) NSArray *specifiers;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
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
    }
    return _mySpecifiers;
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 调试用：如果 specifiers 为空，显示一个提示
    if (!self.specifiers || [self.specifiers count] == 0) {
        UILabel *label = [[UILabel alloc] init];
        label.text = @"正在加载设置项...";
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor grayColor];
        label.frame = self.view.bounds;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:label];
    }
}

@end