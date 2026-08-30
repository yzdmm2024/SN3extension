//
//  SN3ModelLibController.m — 大模型库管理（自包含，NSUserDefaults + UIKit）
//  列表 / 新建 / 从预设一键导入 / 编辑 / 删除。识别引擎 / 问AI / 翻译 在各自设置里选「使用模型」。
//
#import "SN3ModelStore.h"

@interface SN3ModelLibController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *models;
@property (nonatomic, strong) NSString *editingId;   // 编辑中模型的 id（新建为 nil）
@end

@implementation SN3ModelLibController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"大模型库";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    SN3MigrateIfNeeded();
    self.models = [SN3LoadModels() mutableCopy];

    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tv.delegate = self;
    self.tv.dataSource = self;
    [self.view addSubview:self.tv];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(onAdd)];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, self.view.bounds.size.width-32, 54)];
    tip.numberOfLines = 0;
    tip.font = [UIFont systemFontOfSize:13];
    tip.textColor = [UIColor secondaryLabelColor];
    tip.text = @"这里集中管理所有大模型（只需填一次 Key）。识别引擎 / 问AI / 翻译 在各自设置里点「使用模型」选一个即可。";
    self.tv.tableFooterView = tip;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.models = [SN3LoadModels() mutableCopy];
    [self.tv reloadData];
}

#pragma mark - table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.models.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"m"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"m"];
    NSDictionary *m = self.models[ip.row];
    c.textLabel.text = SN3ModelField(m, @"name", @"(未命名)");
    NSString *v = SN3ModelField(m, @"vendor", @"");
    NSString *md = SN3ModelField(m, @"model", @"");
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", v.length?v:@"自定义", md.length?md:@"未设模型"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *m = self.models[ip.row];
    self.editingId = m[@"id"];
    [self presentEditAlertWithName:SN3ModelField(m,@"name",@"") base:SN3ModelField(m,@"baseURL",@"")
                                key:SN3ModelField(m,@"apiKey",@"") model:SN3ModelField(m,@"model",@"")
                              vendor:SN3ModelField(m,@"vendor",@"")];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st != UITableViewCellEditingStyleDelete) return;
    NSString *mid = self.models[ip.row][@"id"];
    [self.models removeObjectAtIndex:ip.row];
    SN3SaveModels(self.models);
    // 若某功能正用着被删的模型，清空其选择
    NSUserDefaults *d = SN3Defs();
    for (NSString *k in @[SN3_K_AI, SN3_K_OCR, SN3_K_TRANS]) {
        if ([[d stringForKey:k] isEqualToString:mid]) [d setObject:@"" forKey:k];
    }
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - add / import

- (void)onAdd {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"添加模型"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"新建空白模型" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        self.editingId = nil;
        [self presentEditAlertWithName:@"" base:@"" key:@"" model:@"" vendor:@""];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从预设一键导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self presentPresetSheet];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPresetSheet {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择预设厂商"
                                                                  message:@"导入后填 API Key 即可用"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *p in SN3Presets()) {
        [sheet addAction:[UIAlertAction actionWithTitle:p[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            self.editingId = nil;
            [self presentEditAlertWithName:p[@"name"] base:p[@"baseURL"] key:@"" model:p[@"model"] vendor:p[@"vendor"]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - edit (new / existing share one alert)

- (void)presentEditAlertWithName:(NSString *)name base:(NSString *)base
                              key:(NSString *)key model:(NSString *)model vendor:(NSString *)vendor {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:self.editingId ? @"编辑模型" : @"新建模型"
                                                               message:@"各功能只需在这里填一次；点「使用模型」即可复用"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder=@"名称(如 我的DeepSeek)"; t.text=name; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder=@"Base URL"; t.text=base; t.autocapitalizationType=UITextAutocapitalizationTypeNone; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder=@"API Key"; t.text=key; t.secureTextEntry=YES; t.autocapitalizationType=UITextAutocapitalizationTypeNone; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder=@"模型名(如 deepseek-chat)"; t.text=model; t.autocapitalizationType=UITextAutocapitalizationTypeNone; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *n  = [ac.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *b  = [ac.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *k2 = [ac.textFields[2].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *m2 = [ac.textFields[3].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!n.length) n = @"未命名模型";
        if (!b.length) b = @"https://api.deepseek.com/v1";
        if (!m2.length) m2 = @"deepseek-chat";
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"id"]     = self.editingId ?: SN3NewUUID();
        dict[@"name"]   = n;
        dict[@"baseURL"]= b;
        dict[@"apiKey"] = k2;
        dict[@"model"]  = m2;
        dict[@"vendor"] = vendor.length ? vendor : @"custom";
        // 替换或新增
        NSInteger idx = -1;
        for (NSInteger i=0;i<self.models.count;i++) if ([self.models[i][@"id"] isEqualToString:dict[@"id"]]) { idx=i; break; }
        if (idx>=0) self.models[idx] = dict; else [self.models addObject:dict];
        SN3SaveModels(self.models);
        [self.tv reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
