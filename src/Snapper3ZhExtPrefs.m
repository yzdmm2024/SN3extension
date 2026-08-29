#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>
#import "Common.h"

// 设置面板主控制器：iOS 设置 → 超级截图
@interface SN3PrefsController : PSListController
@end

@implementation SN3PrefsController

// 用框架自带的 setSpecifiers: 把 Root.plist 解析出的 specifiers 写入框架内部存储，
// 避免子类重复声明 _specifiers 与 PSListController 父类 ivar 冲突（那个冲突会让面板空白）。
- (void)viewDidLoad {
    [super viewDidLoad];
    self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
}

// v5.18：从其他 app 切回设置后偶发空白 —— 三层兜底：
//   (a) 每次回到前台无脑重建（specifiers 存了但 table 不刷、或内部状态错位时也能自愈）；
//   (b) 监听 UIApplicationDidBecomeActiveNotification，强行重新触发 reloadData；
//   (c) 监听 prefsChanged 通知（剪贴板一键粘贴等动作改键后刷新）。
// 各输入框的值存在 defaults，重建会自动回填，不会丢失已填的密钥。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    if ([self.view respondsToSelector:@selector(reloadData)]) {
        [(UITableView *)self.view reloadData];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleBecomeActive {
    self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    if ([self.view respondsToSelector:@selector(reloadData)]) {
        [(UITableView *)self.view reloadData];
    }
}

- (void)handlePrefsChanged {
    if ([self.view respondsToSelector:@selector(reloadData)]) {
        [(UITableView *)self.view reloadData];
    }
}

// v5.15：微信输入法等第三方键盘在设置里弹不出来 —— 提供「从剪贴板一键粘贴密钥」，
//        用户先在备忘录/别处复制好「API Key 和 Secret（换行/逗号/空格分隔）」，点此按钮一键填入。
//        只复制了一段则填到「百度OCR API Key」，再复制 Secret 再点一次即补上。
- (void)pasteClipboardKeys:(PSSpecifier *)spec {
    NSString *pb = [UIPasteboard generalPasteboard].string ?: @"";
    pb = [pb stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!pb.length) {
        [self _sn3Alert:@"剪贴板为空" msg:@"请先在别处复制好百度 OCR 的 API Key 和 Secret Key。"];
        return;
    }
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@"\n,;\t|/ "];
    NSArray *raw = [pb componentsSeparatedByCharactersInSet:sep];
    NSMutableArray *toks = [NSMutableArray array];
    for (NSString *t in raw) {
        NSString *tt = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (tt.length) [toks addObject:tt];
    }
    if (!toks.count) {
        [self _sn3Alert:@"解析失败" msg:@"剪贴板里没有可用的文本，请确认复制的是 API Key/Secret。"];
        return;
    }
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:XZ_PREFS_DOMAIN];
    [d setObject:toks[0] forKey:XZ_KEY_OCR_BD_APIKEY];
    if (toks.count > 1) [d setObject:toks[1] forKey:XZ_KEY_OCR_BD_SECRET];
    [d synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.axs.snapper3zhext.prefsChanged",
                                         NULL, NULL, YES);
    NSString *msg = toks.count > 1
        ? @"已填入百度OCR 的 API Key 和 Secret Key。返回主面板即可看到（若仍为空请退出设置重进）。"
        : @"已填入百度OCR API Key。再来一次、复制 Secret 后点此按钮即可补上第二段。";
    [self _sn3Alert:@"粘贴完成" msg:msg];
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

    PSSpecifier *gOcr = [PSSpecifier groupSpecifierWithName:@"百度智能云 · 文字识别 (PaddleOCR)"];
    [specs addObject:gOcr];
    [specs addObject:[self urlCell:@"打开 OCR 开通/控制台页"
                               url:@"https://console.bce.baidu.com/ai/#/ai/ocr/overview/index"]];
    [specs addObject:[self urlCell:@"打开 OCR API 说明文档"
                               url:@"https://cloud.baidu.com/doc/OCR/s/ik3h7y3db"]];

    PSSpecifier *gTr = [PSSpecifier groupSpecifierWithName:@"百度翻译开放平台"];
    [specs addObject:gTr];
    [specs addObject:[self urlCell:@"打开 翻译平台首页（通用文本翻译）"
                               url:@"https://fanyi-api.baidu.com/"]];
    [specs addObject:[self urlCell:@"打开 翻译开发者管理/控制台"
                               url:@"https://fanyi-api.baidu.com/manage/developer"]];

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

#pragma mark - v5.18 工具栏按钮排序/启用页
//
// 用法：系统设置 → 超级截图 → 工具栏按钮(排序/启用)
//   - 每行右侧开关控制是否在截图后工具栏显示该按钮
//   - 拖动右侧 ≡ 手柄可调整按钮顺序
//   - 数据落地：Toolbar_Disabled (逗号分隔的 tag) + Toolbar_Order (逗号分隔的 tag)

@interface SN3ToolbarController : PSListController
@end

@implementation SN3ToolbarController

// 按钮规格表（必须与 EditToolbarWindow.m 的 catalog 一致）
- (NSArray<NSDictionary *> *)catalog {
    return @[
        @{@"tag": @1,  @"label": @"OCR"},
        @{@"tag": @2,  @"label": @"翻译"},
        @{@"tag": @3,  @"label": @"画图"},
        @{@"tag": @4,  @"label": @"识码"},
        @{@"tag": @17, @"label": @"AI"},
        @{@"tag": @6,  @"label": @"复制"},
        @{@"tag": @7,  @"label": @"贴图"},
        @{@"tag": @8,  @"label": @"保存"},
        @{@"tag": @9,  @"label": @"分享"},
        @{@"tag": @11, @"label": @"加壳"},
        @{@"tag": @12, @"label": @"PDF"},
        @{@"tag": @13, @"label": @"压缩"},
        @{@"tag": @14, @"label": @"去状态栏"},
        @{@"tag": @15, @"label": @"取色"},
        @{@"tag": @16, @"label": @"还原"},
    ];
}

// 把 15 个 tag 按 Toolbar_Order 排序；缺项补末尾、多余丢
- (NSArray<NSNumber *> *)orderedTags {
    NSMutableArray<NSNumber *> *all = [NSMutableArray array];
    for (NSDictionary *c in [self catalog]) [all addObject:c[@"tag"]];
    NSString *saved = [Common stringPref:@"Toolbar_Order" default:@""];
    NSMutableOrderedSet<NSNumber *> *res = [NSMutableOrderedSet orderedSet];
    if (saved.length) {
        for (NSString *t in [saved componentsSeparatedByString:@","]) {
            NSNumber *n = @([t integerValue]);
            if ([all containsObject:n]) [res addObject:n];
        }
    }
    for (NSNumber *t in all) if (![res containsObject:t]) [res addObject:t];
    return res.array;
}

- (void)persistOrder {
    NSMutableArray *strs = [NSMutableArray array];
    for (NSNumber *t in [self orderedTags]) [strs addObject:t.stringValue];
    [Common setPref:@"Toolbar_Order" value:[strs componentsJoinedByString:@","]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"工具栏按钮";

    UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit
                                                                          target:self action:@selector(toggleEdit)];
    self.navigationItem.rightBarButtonItem = edit;

    [self rebuildSpecs];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuildSpecs];
}

- (void)rebuildSpecs {
    NSMutableSet<NSNumber *> *disabled = [NSMutableSet setWithArray:[[Common stringPref:@"Toolbar_Disabled" default:@""] componentsSeparatedByString:@","]];

    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *grp = [PSSpecifier groupSpecifierWithName:@"拖动右侧 ≡ 调整顺序，点开关控制是否在工具栏显示"];
    [specs addObject:grp];

    for (NSNumber *tag in [self orderedTags]) {
        NSString *lbl = nil;
        for (NSDictionary *c in [self catalog]) if ([c[@"tag"] isEqual:tag]) { lbl = c[@"label"]; break; }

        PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:lbl
                                                        target:self
                                                           set:@selector(setEnabledValue:specifier:)
                                                           get:@selector(getEnabledValue:specifier:)
                                                        detail:nil
                                                          cell:PSSwitchCell
                                                          edit:nil];
        [s setProperty:tag forKey:@"tag"];
        [s setProperty:@"com.axs.snapper3zhext" forKey:@"defaults"];
        s.identifier = [NSString stringWithFormat:@"tb_%@", tag];
        [specs addObject:s];
    }
    self.specifiers = specs;
}

- (id)getEnabledValue:(id)value specifier:(PSSpecifier *)spec {
    NSNumber *tag = [spec propertyForKey:@"tag"];
    NSString *raw = [Common stringPref:@"Toolbar_Disabled" default:@""];
    BOOL inDisabled = [[raw componentsSeparatedByString:@","] containsObject:tag.stringValue];
    return @(! inDisabled);
}

- (void)setEnabledValue:(id)value specifier:(PSSpecifier *)spec {
    NSNumber *tag = [spec propertyForKey:@"tag"];
    NSMutableSet *disabled = [NSMutableSet setWithArray:[[Common stringPref:@"Toolbar_Disabled" default:@""] componentsSeparatedByString:@","]];
    if ([value boolValue]) [disabled removeObject:tag]; else [disabled addObject:tag];
    NSMutableArray *arr = [NSMutableArray array];
    for (id x in disabled) if (![x isEqual:@""]) [arr addObject:x];
    [Common setPref:@"Toolbar_Disabled" value:[arr componentsJoinedByString:@","]];
}

- (void)toggleEdit { self.table.editing = !self.table.editing; }

// 让所有行可拖动
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    // 第 0 行是 group header
    NSInteger f = from.row - 1, t = to.row - 1;
    if (f < 0 || t < 0) return;
    NSMutableArray<NSNumber *> *tags = [[self orderedTags] mutableCopy];
    if (f >= (NSInteger)tags.count || t >= (NSInteger)tags.count) return;
    NSNumber *moved = tags[f];
    [tags removeObjectAtIndex:f];
    [tags insertObject:moved atIndex:MIN(t, (NSInteger)tags.count - 1)];

    NSMutableArray *strs = [NSMutableArray array];
    for (NSNumber *n in tags) [strs addObject:n.stringValue];
    [Common setPref:@"Toolbar_Order" value:[strs componentsJoinedByString:@","]];

    [self rebuildSpecs];
}

@end
