//
//  Snapper3ZhExtPrefs.m — 设置面板控制器（旧子工程副本，保持与 src/ 版本一致）
//
//  注意：顶层 Makefile 实际使用的是 src/Snapper3ZhExtPrefs.m，本文件是历史遗留的
//  独立子工程（PreferenceBundles/Snapper3ZhExtPrefs/Makefile）源文件，并不参与构建。
//  两份必须保持同步，类名统一为 SN3PrefsController，且必须用懒加载 specifiers getter。
//
//  v3.08 修正：父类前向声明补 specifiers 属性，去掉子类重复 ivar _specifiers
//  （否则生成第二个 _specifiers ivar 与父类错开 → 表格数据源读父类 nil → 空白面板）。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

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
