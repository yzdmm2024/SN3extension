#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>

// 设置面板主控制器：iOS 设置 → SN3延伸板
@interface SN3PrefsController : PSListController
@end

@implementation SN3PrefsController

// 用框架自带的 setSpecifiers: 把 Root.plist 解析出的 specifiers 写入框架内部存储，
// 避免子类重复声明 _specifiers 与 PSListController 父类 ivar 冲突（那个冲突会让面板空白）。
- (void)viewDidLoad {
    [super viewDidLoad];
    self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
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
