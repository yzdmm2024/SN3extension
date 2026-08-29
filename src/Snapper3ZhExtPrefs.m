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
    if (!self.specifiers || self.specifiers.count == 0) {
        self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
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

// v5.14：API 开通页面 —— 点击行直接打开 Safari 到「百度智能云·文字识别(OCR)」与「百度翻译开放平台」。
//         不用 PSListController 未公开的 specifierForIndexPath:（会导致编译失败），
//         直接按 (section,row) 从实例变量二维数组映射 URL，稳定可靠。
@interface SN3LinksController : PSListController {
    NSArray *_sectionURLs;   // [section][row] → url
}
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

    // 与上面的 group 顺序严格一致：[0]=OCR、[1]=翻译，每组内按行序对应 URL。
    _sectionURLs = @[
        @[ @"https://console.bce.baidu.com/ai/#/ai/ocr/overview/index",
           @"https://cloud.baidu.com/doc/OCR/s/ik3h7y3db" ],
        @[ @"https://fanyi-api.baidu.com/",
           @"https://fanyi-api.baidu.com/manage/developer" ],
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationItem) self.navigationItem.title = @"API 开通";
}

- (PSSpecifier *)urlCell:(NSString *)label url:(NSString *)url {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:nil
                                                       set:NULL
                                                       get:NULL
                                                    detail:nil
                                                      cell:PSLinkCell
                                                      edit:nil];
    [s setProperty:url forKey:@"url"];
    return s;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *rowURLs = (_sectionURLs.count > (NSUInteger)indexPath.section)
                        ? _sectionURLs[indexPath.section] : nil;
    NSString *url = (rowURLs.count > (NSUInteger)indexPath.row) ? rowURLs[indexPath.row] : nil;
    if ([url isKindOfClass:[NSString class]] && url.length) {
        NSURL *u = [NSURL URLWithString:url];
        if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }
}

@end
