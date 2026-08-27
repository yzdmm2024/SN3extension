// Snapper3ZhExtPrefs.m — 设置面板
// 继承 PSViewController 而非 PSListController，避免
// "There appears to be an error with these preferences!" 错误
// 完全参照通知管理插件 NotifyManager.m 的 NTMPrincipalController 实现方式：
// 编译期 @interface/@implementation，运行时通过 -Wl,-undefined,dynamic_lookup 解析符号

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// PSViewController 是 PreferenceLoader 控制器的正确基类，提供完整集成方法
@interface PSViewController : UIViewController
@end

@interface SN3PrefsController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@end

#pragma mark - 存储
static NSString *SN3_suite = @"com.axs.snapper3zhext";
static NSUserDefaults *SN3_prefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:SN3_suite];
    });
    return prefs;
}

#pragma mark - 实现
@implementation SN3PrefsController {
    UITableView *_tableView;
    NSArray *_sections;
}

// PSViewController 集成桩方法（避免 unrecognized selector 崩溃）
- (void)setRootController:(id)rootController {}
- (void)setParentController:(id)parentController {}
- (void)setSpecifier:(id)specifier {}
- (void)setPreferenceLoader:(id)preferenceLoader {}
- (void)setParentController:(id)parentController specifier:(id)specifier {}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SN3延伸板";
    self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1];

    // 构建数据
    _sections = @[
        @{@"title": @"API 配置", @"rows": @[
            @{@"label": @"百度翻译 AppID", @"key": @"trans_appid", @"placeholder": @"输入百度翻译 AppID"},
            @{@"label": @"百度翻译密钥", @"key": @"trans_key", @"placeholder": @"输入百度翻译密钥"},
            @{@"label": @"AI 接口地址", @"key": @"ai_baseurl", @"placeholder": @"如 https://api.openai.com/v1"},
            @{@"label": @"AI API Key", @"key": @"ai_apikey", @"placeholder": @"sk-..."},
            @{@"label": @"AI 模型", @"key": @"ai_model", @"placeholder": @"如 gpt-4o-mini"},
        ]},
        @{@"title": @"OCR 配置", @"rows": @[
            @{@"label": @"OCR 语言", @"key": @"ocr_lang", @"placeholder": @"zh-Hans,zh-Hant,en-US"},
        ]},
        @{@"title": @"关于", @"rows": @[
            @{@"label": @"版本", @"key": @"version", @"placeholder": @"3.05"},
            @{@"label": @"说明", @"key": @"info", @"placeholder": @"独立插件，截屏弹出浮动菜单"},
        ]},
    ];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    [self.view addSubview:_tableView];
}

#pragma mark - UITableViewDataSource
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[section][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = _sections[indexPath.section][@"rows"][indexPath.row];
    NSString *key = row[@"key"];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = row[@"label"];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor whiteColor];

    if ([key isEqualToString:@"version"] || [key isEqualToString:@"info"]) {
        cell.detailTextLabel.text = row[@"placeholder"];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    } else {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        tf.placeholder = row[@"placeholder"];
        tf.font = [UIFont systemFontOfSize:14];
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        tf.returnKeyType = UIReturnKeyDone;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.tag = indexPath.section * 100 + indexPath.row;

        // 读取已保存的值
        NSString *saved = [SN3_prefs() stringForKey:[NSString stringWithFormat:@"SN3_%@", key]] ?: @"";
        tf.text = saved;

        // 保存回调
        [tf addTarget:self action:@selector(textFieldDidEndEditing:) forControlEvents:UIControlEventEditingDidEnd];

        cell.accessoryView = tf;
    }

    return cell;
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSInteger sec = tf.tag / 100;
    NSInteger row = tf.tag % 100;
    if (sec < _sections.count && row < [_sections[sec][@"rows"] count]) {
        NSString *key = _sections[sec][@"rows"][row][@"key"];
        if (![key isEqualToString:@"version"] && ![key isEqualToString:@"info"]) {
            [SN3_prefs() setObject:tf.text ?: @"" forKey:[NSString stringWithFormat:@"SN3_%@", key]];
            [SN3_prefs() synchronize];
        }
    }
}

@end