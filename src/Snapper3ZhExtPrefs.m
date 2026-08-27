//
//  Snapper3ZhExtPrefs.m — 设置面板（继承 PSListController，链接 Preferences.framework）
//  参考 Axon iOS 16 方案，正确链接 Preferences.framework 而非使用 dynamic_lookup
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SN3PrefsController : PSListController
@end

@implementation SN3PrefsController

- (NSArray *)specifiers {
    if (![self valueForKey:@"_specifiers"]) {
        NSArray *specs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self setValue:specs forKey:@"_specifiers"];
    }
    return [self valueForKey:@"_specifiers"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SN3延伸板";
}

@end