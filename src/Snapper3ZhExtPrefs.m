//
//  Snapper3ZhExtPrefs.m — 设置面板（纯 UIViewController）
//
//  使用 NSUserDefaults 读写偏好，支持 API Key 配置
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define XZ_PREFS_DOMAIN @"com.axs.snapper3zhext"

@interface Snapper3ZhExtPrefsController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *sections;
@end

@implementation Snapper3ZhExtPrefsController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 44;
    [self.view addSubview:self.tableView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SN3延伸板";
    
    self.sections = @[
        @{@"header": @"百度翻译", @"rows": @[
            @{@"key": @"Translate_APIAppID", @"label": @"AppID", @"type": @"text", @"placeholder": @"输入百度翻译AppID"},
            @{@"key": @"Translate_APIKey", @"label": @"密钥", @"type": @"text", @"placeholder": @"输入百度翻译密钥"},
            @{@"key": @"Translate_TargetLang", @"label": @"目标语言", @"type": @"text", @"placeholder": @"zh(默认)"},
        ]},
        @{@"header": @"AI 对话", @"rows": @[
            @{@"key": @"AskAI_BaseURL", @"label": @"接口地址", @"type": @"text", @"placeholder": @"https://api.openai.com/v1"},
            @{@"key": @"AskAI_APIKey", @"label": @"API Key", @"type": @"text", @"placeholder": @"sk-..."},
            @{@"key": @"AskAI_Model", @"label": @"模型", @"type": @"text", @"placeholder": @"gpt-4o-mini"},
            @{@"key": @"AskAI_Prompt", @"label": @"提示词", @"type": @"text", @"placeholder": @"请描述这张图片中的内容"},
        ]},
        @{@"header": @"OCR 语言", @"rows": @[
            @{@"key": @"OCR_Languages", @"label": @"语言列表", @"type": @"text", @"placeholder": @"zh-Hans,zh-Hant,en-US"},
        ]},
    ];
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"header"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"PrefCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        tf.borderStyle = UITextBorderStyleNone;
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = [UIColor systemGrayColor];
        tf.font = [UIFont systemFontOfSize:15];
        tf.delegate = self;
        tf.tag = 999;
        tf.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        cell.accessoryView = tf;
    }
    
    NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    cell.textLabel.text = row[@"label"];
    
    UITextField *tf = (UITextField *)[cell viewWithTag:999];
    tf.placeholder = row[@"placeholder"];
    NSString *key = row[@"key"];
    id val = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if (!val) {
        val = [self performSelector:NSSelectorFromString([NSString stringWithFormat:@"default%@", key])];
    }
    #pragma clang diagnostic pop
    tf.text = [val isKindOfClass:[NSString class]] ? val : @"";
    objc_setAssociatedObject(tf, "prefKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tf addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    
    return cell;
}

- (void)textFieldChanged:(UITextField *)tf {
    NSString *key = objc_getAssociatedObject(tf, "prefKey");
    if (key) {
        [[NSUserDefaults standardUserDefaults] setObject:tf.text ?: @"" forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

@end