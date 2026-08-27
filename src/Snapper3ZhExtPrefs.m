//
//  Snapper3ZhExtPrefs.m — 最小 PSListController 子类
//  PSListController 由 Preferences.framework 提供，系统自动读取 Root.plist 渲染 UI
//

#import <UIKit/UIKit.h>

// PSListController 声明（运行时查找，避免编译链接 Preferences.framework）
@interface PSListController : UIViewController
- (void)setSpecifiers:(NSArray *)specifiers;
- (NSArray *)specifiers;
- (id)readPreferenceValue:(id)specifier;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end

@interface Snapper3ZhExtPrefsController : PSListController
@end

@implementation Snapper3ZhExtPrefsController

- (NSArray *)specifiers {
    NSArray *specs = [self valueForKey:@"_specifiers"];
    if (specs) return specs;
    
    // 从 Root.plist 加载 specifiers
    NSString *plistPath = [[NSBundle bundleForClass:self.class] pathForResource:@"Root" ofType:@"plist"];
    if (plistPath) {
        NSDictionary *rootDict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSArray *items = rootDict[@"items"];
        if (items) {
            [self setSpecifiers:items];
            return items;
        }
    }
    return @[];
}

@end