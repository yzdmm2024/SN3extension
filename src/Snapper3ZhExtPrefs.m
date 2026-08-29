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

// v5.15：从其他 app 切回设置后偶发空白 —— 兜底重建（object 还在但 specifiers 被清空/未重载时）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // v5.17：从其它 app 切回设置时 PSListController 常不自刷新/被清空导致整页白屏。
    //        每次回到前台都从 Root.plist 重建 specifiers 并强刷表格，保证一定有内容；
    //        各输入框的值存在 defaults，重建会自动回填，不会丢失已填的密钥。
    if (!self.specifiers || self.specifiers.count == 0) {
        self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
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
