//
//  Snapper3ZhExtPrefs.m — 设置面板（继承 PSViewController，自定义 UI）
//  PSViewController 是 Preferences.framework 提供的 UIViewController 子类，
//  被 PreferenceLoader 识别且不会触发 "There appears to be an error" 检查。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// PSViewController 声明（Preferences.framework 私有类，运行时存在）
// 不需要实际链接，声明即可让编译器通过
@interface PSViewController : UIViewController
@end

// 简单偏好存储（使用 NSUserDefaults，与 tweak 共享）
static NSString *SN3Prefs_key(NSString *key) {
    return [NSString stringWithFormat:@"SN3_%@", key];
}
static NSUserDefaults *SN3Prefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.axs.snapper3zhext"];
    });
    return prefs;
}
static NSString *SN3Read(NSString *key) {
    return [SN3Prefs() stringForKey:SN3Prefs_key(key)] ?: @"";
}
static void SN3Write(NSString *key, NSString *val) {
    [SN3Prefs() setObject:val forKey:SN3Prefs_key(key)];
    [SN3Prefs() synchronize];
}

#pragma mark - 控制器

@interface SN3PrefsController : PSViewController <UITextFieldDelegate, UITableViewDelegate, UITableViewDataSource>
@end

@implementation SN3PrefsController {
    UITableView *_tableView;
    NSArray *_sections;
}

- (void)loadView {
    // 不要调用 super，PSViewController 的 loadView 可能做奇怪的事情
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SN3延伸板";
    
    // 构建数据
    _sections = @[
        @{@"title": @"API 配置", @"rows": @[
            @{@"label": @"百度翻译 APP ID", @"key": @"trans_appid", @"placeholder": @"输入百度翻译 APP ID"},
            @{@"label": @"百度翻译密钥", @"key": @"trans_key", @"placeholder": @"输入百度翻译密钥"},
            @{@"label": @"AI 接口地址", @"key": @"ai_baseurl", @"placeholder": @"如 https://api.openai.com/v1"},
            @{@"label": @"AI API Key", @"key": @"ai_apikey", @"placeholder": @"输入 API Key"},
            @{@"label": @"AI 模型", @"key": @"ai_model", @"placeholder": @"如 gpt-4o-mini"},
        ]},
        @{@"title": @"关于", @"rows": @[
            @{@"label": @"版本", @"key": @"version", @"placeholder": @"3.02"},
            @{@"label": @"说明", @"key": @"info", @"placeholder": @"截屏弹出浮动菜单，支持 OCR/翻译/AI/截图"},
        ]},
    ];
    
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_tableView];
}

#pragma mark - PSController 协议桩方法（必须实现，否则 PreferenceLoader 会崩溃）

- (void)setRootController:(id)rootController {}
- (void)setParentController:(id)parentController {}
- (void)setSpecifier:(id)specifier {}
- (void)setPreferenceLoader:(id)preferenceLoader {}
- (void)setParentController:(id)parentController specifier:(id)specifier {}

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
    
    if ([key isEqualToString:@"version"] || [key isEqualToString:@"info"]) {
        // 静态文本行
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.textLabel.text = row[@"label"];
        cell.detailTextLabel.text = row[@"placeholder"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor whiteColor];
        return cell;
    }
    
    // 带输入框的行
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = row[@"label"];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor whiteColor];
    
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    tf.placeholder = row[@"placeholder"];
    tf.text = SN3Read(key);
    tf.font = [UIFont systemFontOfSize:14];
    tf.textAlignment = NSTextAlignmentRight;
    tf.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    tf.delegate = self;
    tf.tag = indexPath.section * 100 + indexPath.row;
    tf.returnKeyType = UIReturnKeyDone;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    cell.accessoryView = tf;
    
    return cell;
}

#pragma mark - UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSInteger section = textField.tag / 100;
    NSInteger row = textField.tag % 100;
    if (section < _sections.count && row < [_sections[section][@"rows"] count]) {
        NSDictionary *rowData = _sections[section][@"rows"][row];
        SN3Write(rowData[@"key"], textField.text ?: @"");
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end