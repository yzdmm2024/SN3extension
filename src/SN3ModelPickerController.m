//
//  SN3ModelPickerController.m — 为某个功能(问AI/识别引擎/翻译)选择「使用模型」(radio)
//
#import "SN3ModelStore.h"

@interface SN3ModelPickerController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSString *featureKey;
@property (nonatomic, strong) NSString *selId;
@property (nonatomic, strong) NSArray<NSDictionary *> *models;
@property (nonatomic, strong) UITableView *tv;
@end

@implementation SN3ModelPickerController

- (instancetype)initWithFeatureKey:(NSString *)key title:(NSString *)title {
    if (self = [super init]) {
        _featureKey = key;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    SN3MigrateIfNeeded();
    self.models = SN3LoadModels();
    self.selId = [SN3Defs() stringForKey:self.featureKey] ?: @"";

    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tv.delegate = self;
    self.tv.dataSource = self;
    [self.view addSubview:self.tv];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.models.count + 1; // +1 = 不使用(关闭)
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"p"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"p"];
    c.accessoryType = UITableViewCellAccessoryNone;
    if (ip.row == 0) {
        c.textLabel.text = @"不使用（关闭该功能）";
        c.detailTextLabel.text = @"选这个等于关闭 AI / 识别 / 翻译";
        if (self.selId.length == 0) c.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        NSDictionary *m = self.models[ip.row-1];
        c.textLabel.text = SN3ModelField(m, @"name", @"(未命名)");
        c.detailTextLabel.text = SN3ModelField(m, @"model", @"未设模型");
        if ([self.selId isEqualToString:m[@"id"]]) c.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *pick = (ip.row == 0) ? @"" : self.models[ip.row-1][@"id"];
    self.selId = pick;
    [SN3Defs() setObject:pick forKey:self.featureKey];
    [SN3Defs() synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.axs.snapper3zhext.prefsChanged", NULL, NULL, YES);
    [self.tv reloadData];
    // 延迟返回，让用户看到勾选
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self.navigationController popViewControllerAnimated:YES]; });
}

@end
