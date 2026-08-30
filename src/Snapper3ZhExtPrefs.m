#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>
#import "Common.h"
#import "AskAIEngine.h"
#import "ToolbarOrderController.h"

// 设置面板主控制器：iOS 设置 → 超级截图
@interface SN3PrefsController : PSListController
@end

@implementation SN3PrefsController

// v5.19：设置面板偶发空白（iOS 14 PSListController 在 viewWillAppear 同帧改 specifiers 时
//        会把 table 刷空）。把重建推到下一 runloop，并加 try/catch 兜底；监听
//        UIApplicationDidBecomeActiveNotification + prefsChanged 通知双保险。
// 各输入框的值存在 defaults，重建会自动回填，不会丢失已填的密钥。
- (void)viewDidLoad {
    [super viewDidLoad];
    @try { self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self]; }
    @catch (NSException *e) { NSLog(@"[SN3] prefs init failed: %@", e.reason); }
    [self _applyButtonActions];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(handleBecomeActive)
                                                  name:UIApplicationDidBecomeActiveNotification
                                                object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(handlePrefsChanged)
                                                  name:@"com.axs.snapper3zhext.prefsChanged"
                                                object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.specifiers || self.specifiers.count == 0) {
                self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
            }
            [self _applyButtonActions];
            if ([self.view respondsToSelector:@selector(reloadData)]) {
                [(UITableView *)self.view reloadData];
            }
        } @catch (NSException *e) { NSLog(@"[SN3] prefs reload failed: %@", e.reason); }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleBecomeActive {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.specifiers || self.specifiers.count == 0) {
                self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
            }
            [self _applyButtonActions];
            if ([self.view respondsToSelector:@selector(reloadData)]) {
                [(UITableView *)self.view reloadData];
            }
        } @catch (NSException *e) { NSLog(@"[SN3] prefs become-active failed: %@", e.reason); }
    });
}

- (void)handlePrefsChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.view respondsToSelector:@selector(reloadData)]) {
            [(UITableView *)self.view reloadData];
        }
    });
}

// v6.02: 修复「设置面板所有蓝色按钮（PSButtonCell）点击无反应」的根因。
// 根因：plist 里写的 action 是「testAskAIConnection / openArkPage / openToolbarOrder」这种
//       不带冒号的字符串，但实际方法签名是带冒号的 testAskAIConnection:(PSSpecifier*)、
//       openArkPage:(PSSpecifier*)（吃一个参数）。NSSelectorFromString(@"testAskAIConnection")
//       得到的是 0 参数的选择器，跟带冒号的方法不是同一个 → PSButtonCell 点上去找不到方法、
//       整组按钮（含 v5.23 的旧 测试连接/申请页）全部静默失效。
// 修复：用 propertyForKey:@"action" 取出字符串后，若本类没有该无冒号方法、但有「带冒号」版本，
//       则改用带冒号的选择器；并同时 setButtonAction: 与 setAction: 兼容框架两种写法。
- (void)_applyButtonActions {
    for (PSSpecifier *s in self.specifiers) {
        NSString *act = [s propertyForKey:@"action"];
        if (![act isKindOfClass:[NSString class]] || act.length == 0) continue;
        SEL sel = NSSelectorFromString(act);
        if (![self respondsToSelector:sel]) {
            NSString *alt = [act stringByAppendingString:@":"];
            if ([self respondsToSelector:NSSelectorFromString(alt)]) {
                sel = NSSelectorFromString(alt);
            }
        }
        if ([self respondsToSelector:sel]) {
            [s setButtonAction:sel];
        }
    }
}

// v6.01: 打开工具栏排序页（拖动排序 + 开关自定义按钮）
- (void)openToolbarOrder:(PSSpecifier *)spec {
    SN3ToolbarOrderController *vc = [[SN3ToolbarOrderController alloc] init];
    vc.title = @"工具栏排序";
    [self.navigationController pushViewController:vc animated:YES];
}

// v5.23.0: 智谱 BigModel API Key 一键粘贴 (单段, 没有 Secret 概念)
- (void)pasteBigModelKey:(PSSpecifier *)spec {
    NSString *pb = [UIPasteboard generalPasteboard].string ?: @"";
    pb = [pb stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!pb.length) {
        [self _sn3Alert:@"剪贴板为空" msg:@"请先在别处复制好智谱 BigModel 的 API Key。"];
        return;
    }
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    [d setObject:pb forKey:XZ_KEY_BM_KEY];
    [d synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.axs.snapper3zhext.prefsChanged",
                                         NULL, NULL, YES);
    [self _sn3Alert:@"粘贴完成" msg:[NSString stringWithFormat:@"已填入 API Key（前 8 位: %@…）。\n返回主面板即可看到。", [pb substringToIndex:MIN(8u, pb.length)]]];
}

// v5.23.0: 用当前配置打一发最小的 chat 请求验证 Key 是否有效
- (void)testBigModelConnection:(PSSpecifier *)spec {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    NSString *bu   = [d stringForKey:XZ_KEY_BM_BASEURL] ?: @"https://open.bigmodel.cn/api/paas/v4";
    NSString *key  = [d stringForKey:XZ_KEY_BM_KEY]     ?: @"";
    NSString *md   = [d stringForKey:XZ_KEY_BM_MODEL]   ?: @"glm-4v-flash";
    if (!key.length) {
        [self _sn3Alert:@"未配置 API Key" msg:@"请先在「API Key」项填写（也可点「从剪贴板粘贴」按钮一键填入）。"];
        return;
    }
    [self _sn3Alert:@"测试中" msg:@"正在用当前配置打一发请求，请稍候 3-5 秒…"];

    NSDictionary *txt = @{ @"type": @"text", @"text": @"ping, reply with one word: pong" };
    NSArray *messages = @[ @{ @"role": @"user", @"content": @[ txt ] } ];

    [AskAIEngine askMessages:messages baseURL:bu apiKey:key model:md
                  completion:^(NSString *answer, NSString *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err.length) {
                [self _sn3Alert:@"✗ 连接失败" msg:err];
            } else {
                [self _sn3Alert:@"✓ 连接成功" msg:[NSString stringWithFormat:@"模型 %@ 返回:\n\n%@", md, answer ?: @"(空)"]];
            }
        });
    }];
}

// v5.25.7: 用「问 AI」当前配置打一发最小 chat 请求，验证 OpenAI 兼容接口（含豆包 Ark）是否可用
- (void)testAskAIConnection:(PSSpecifier *)spec {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    NSString *bu   = [d stringForKey:XZ_KEY_AI_BASEURL] ?: @"https://api.openai.com";
    NSString *key  = [d stringForKey:XZ_KEY_AI_KEY]     ?: @"";
    NSString *md   = [d stringForKey:XZ_KEY_AI_MODEL]   ?: @"gpt-4o-mini";
    if (!key.length) {
        [self _sn3Alert:@"未配置 API Key"
                     msg:@"请先在「问 AI」段填写 API Key。\n接豆包：Base URL 填 https://ark.cn-beijing.volces.com/api/v3，模型名填接入点 ID（ep-xxxx，不是 doubao-xxx）。"];
        return;
    }
    [self _sn3Alert:@"测试中" msg:@"正在用「问 AI」当前配置打一发请求，请稍候 3-10 秒…"];

    NSDictionary *txt = @{ @"type": @"text", @"text": @"ping, reply with one word: pong" };
    NSArray *messages = @[ @{ @"role": @"user", @"content": @[ txt ] } ];

    [AskAIEngine askMessages:messages baseURL:bu apiKey:key model:md
                  completion:^(NSString *answer, NSString *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err.length) {
                [self _sn3Alert:@"✗ 连接失败" msg:err];
            } else {
                [self _sn3Alert:@"✓ 连接成功" msg:[NSString stringWithFormat:@"模型 %@ 返回:\n\n%@", md, answer ?: @"(空)"]];
            }
        });
    }];
}

// v5.25.7: 打开火山方舟 Ark 控制台（拿 API Key + 创建接入点取 ep-xxxx）
- (void)openArkPage:(PSSpecifier *)spec {
    NSURL *u = [NSURL URLWithString:@"https://console.volcengine.com/ark"];
    if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

// v5.25.0: PSButtonCell 打开外部链接 (替代 PSLinkCell+detail=类名, 那个写法会让 iOS 14+ PSListController
// 找不到 plist 文件而抛错, 整个 prefs bundle 被标记为损坏, 进设置报「未能载入软件包」).
- (void)openBigModelAPIPage:(PSSpecifier *)spec {
    NSURL *u = [NSURL URLWithString:@"https://bigmodel.cn/usercenter/apikeys"];
    if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

- (void)openAPIPage:(PSSpecifier *)spec {
    // 这里保留「打开 API 开通页面」总入口, 跳到智谱 BigModel 申请页 (后续要分两段可拆)
    NSURL *u = [NSURL URLWithString:@"https://bigmodel.cn/usercenter/apikeys"];
    if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

- (void)_sn3Alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

// v5.16：API 开通页面 —— 用 PSButtonCell（带 buttonAction），点行直接打开 Safari。
//         PSLinkCell 无 detail 时会被渲染成灰色禁用、点了没反应，这里改用可点的按钮行。
@interface SN3LinksController : PSListController
@end

@implementation SN3LinksController

- (void)viewDidLoad {
    [super viewDidLoad];

    NSMutableArray *specs = [NSMutableArray array];

    // v5.23.0: 砍掉百度 OCR 段 (不再支持), 保留翻译段, AI Studio 段改为智谱 BigModel
    PSSpecifier *gTr = [PSSpecifier groupSpecifierWithName:@"百度翻译开放平台"];
    [specs addObject:gTr];
    [specs addObject:[self urlCell:@"打开 翻译平台首页（通用文本翻译）"
                               url:@"https://fanyi-api.baidu.com/"]];
    [specs addObject:[self urlCell:@"打开 翻译开发者管理/控制台"
                               url:@"https://fanyi-api.baidu.com/manage/developer"]];

    PSSpecifier *gBM = [PSSpecifier groupSpecifierWithName:@"智谱 BigModel (glm-4v-flash, 永久免费额度)"];
    [specs addObject:gBM];
    [specs addObject:[self urlCell:@"打开 智谱 BigModel 控制台 (拿 API Key)"
                               url:@"https://bigmodel.cn/usercenter/apikeys"]];
    [specs addObject:[self urlCell:@"打开 智谱 BigModel · 模型广场 (选多模态模型)"
                               url:@"https://bigmodel.cn/console/modelsquare"]];
    [specs addObject:[self urlCell:@"打开 智谱 BigModel · 文档 (OpenAI 兼容协议说明)"
                               url:@"https://bigmodel.cn/dev/api/normal-model/glm-4v"]];

    self.specifiers = specs;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationItem) self.navigationItem.title = @"API 开通";
}

- (PSSpecifier *)urlCell:(NSString *)label url:(NSString *)url {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    [s setProperty:url forKey:@"url"];
    [s setButtonAction:@selector(openLink:)];
    return s;
}

- (void)openLink:(id)sender {
    // 不同 iOS 版本点击回调传的可能是 PSSpecifier，也可能是承载它的 cell，做兼容取 specifier。
    id spec = sender;
    if (![spec isKindOfClass:[PSSpecifier class]] && [spec respondsToSelector:@selector(specifier)]) {
        spec = [spec specifier];
    }
    NSString *url = [spec isKindOfClass:[PSSpecifier class]] ? [spec propertyForKey:@"url"] : nil;
    if ([url isKindOfClass:[NSString class]] && url.length) {
        NSURL *u = [NSURL URLWithString:url];
        if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }
}

@end

// v5.20：SN3ToolbarController 暂时下线, 避免 PSListController 内部状态在 iOS 14 加载时崩溃,
//        产生「未能载入软件包」错误。工具栏排版仍按 plist 里的 PSSwitchCell「单排滑动显示」+ 隐藏项。
//        下版用更兼容的 PSSpecifier 接口重写排序页。
