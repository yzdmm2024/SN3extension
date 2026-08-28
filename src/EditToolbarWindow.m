//
//  EditToolbarWindow.m — 窗口B：截图编辑两排工具栏（超级截图 v4.1）
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.1 修复 / 增强
//   1) 【致命 v4.0 缺陷】窗口没有 rootViewController，导致 UIAlertController
//      (OCR 结果、二维码结果、更多菜单) 和 UIActivityViewController (分享)
//      只能拿 SpringBoard 的 keyWindow.rootViewController 去 present，
//      在 SpringBoard 里经常静默失败或抛异常 —— 表现为「点了没反应」。
//      现补上 XZEditRootVC，所有 present 一律走它。
//   2) 两排工具栏统一为 5 + 5，按钮尺寸按屏宽自适应，不再写死 62pt。
//   3) 顶部增加关闭按钮 + 图片尺寸标签；去掉「点任意空白处关闭」的手势
//      （v4.0 里这个手势经常误触，尤其 OCR 弹窗关闭时顺手把窗口也关了）。
//   4) 图片区按安全区 + 工具栏高度自适应，长图也能完整显示（aspectFit）。
//  ────────────────────────────────────────────────────────────────────────
//

#import "EditToolbarWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "SuperTools.h"

typedef NS_ENUM(NSInteger, ETBTag) {
    // 第一排：识别编辑
    ETBTagOCR        = 1,
    ETBTagTranslate  = 2,
    ETBTagDraw       = 3,
    ETBTagCodeScan   = 4,
    ETBTagMosaic     = 5,
    // 第二排：输出操作
    ETBTagCopy       = 6,
    ETBTagFloating   = 7,
    ETBTagSave       = 8,
    ETBTagShare      = 9,
    ETBTagMore       = 10,
};

static const CGFloat kRowH    = 66.0;   // 单排按钮高
static const CGFloat kRowGap  = 8.0;
static const CGFloat kBarPad  = 10.0;

#pragma mark - 承载用 rootViewController

@interface XZEditRootVC : UIViewController
@property (nonatomic, weak) EditToolbarWindow *owner;
@end

@implementation XZEditRootVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return NO; }
@end

#pragma mark - EditToolbarWindow

@implementation EditToolbarWindow {
    UIWindow *_win;
    XZEditRootVC *_rootVC;
    UIImageView *_imageView;
    UIView *_toolbar;
    UILabel *_sizeLabel;
}

static EditToolbarWindow *_shared = nil;

#pragma mark - 生命周期

+ (void)showWithImage:(UIImage *)image {
    if (!image) { NSLog(@"[SN3] EditToolbarWindow: nil image"); return; }
    if (_shared) [_shared destroyWindow];     // 重入先销毁，避免叠加

    EditToolbarWindow *w = [[EditToolbarWindow alloc] init];
    _shared = w;
    [w buildWindowWithImage:image];
}

+ (void)dismiss {
    if (_shared) {
        [_shared destroyWindow];
        _shared = nil;
    }
}

- (void)destroyWindow {
    if (_win) {
        _win.hidden = YES;
        _win.rootViewController = nil;
        _win = nil;
    }
    _rootVC.owner = nil;
    _rootVC = nil;
    _imageView = nil;
    _toolbar = nil;
    _sizeLabel = nil;
    NSLog(@"[SN3] edit window B destroyed");
}

- (void)buildWindowWithImage:(UIImage *)image {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 200;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    _win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    // 关键：必须有 rootViewController，present 才有落点
    _rootVC = [[XZEditRootVC alloc] init];
    _rootVC.owner = self;
    _rootVC.view.backgroundColor = [UIColor clearColor];
    _rootVC.view.frame = scr;
    _win.rootViewController = _rootVC;

    // 图片显示区：上方留出关闭条，下方留出两排工具栏
    CGFloat barH = kBarPad * 2 + kRowH * 2 + kRowGap;
    CGFloat topY = safe.top + 44;
    CGFloat botY = scr.size.height - safe.bottom - barH - 8;
    _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(8, topY, scr.size.width - 16, MAX(60, botY - topY))];
    _imageView.image = image;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.userInteractionEnabled = YES;
    _imageView.layer.borderWidth = 1;
    _imageView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    [_rootVC.view addSubview:_imageView];

    // 顶部：关闭 + 尺寸信息
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(12, safe.top + 4, 72, 34);
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    close.layer.cornerRadius = 8;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [_rootVC.view addSubview:close];

    _sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(96, safe.top + 4, scr.size.width - 108, 34)];
    _sizeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _sizeLabel.font = [UIFont systemFontOfSize:12];
    _sizeLabel.textAlignment = NSTextAlignmentRight;
    _sizeLabel.text = [NSString stringWithFormat:@"%.0f × %.0f px", image.size.width, image.size.height];
    [_rootVC.view addSubview:_sizeLabel];

    [self installToolbar];
    _win.hidden = NO;
    NSLog(@"[SN3] edit window B shown, image=%.0fx%.0f", image.size.width, image.size.height);
}

- (void)onClose {
    [EditToolbarWindow dismiss];
}

#pragma mark - 两排工具栏

- (void)installToolbar {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];
    CGFloat barH = kBarPad * 2 + kRowH * 2 + kRowGap;

    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - barH,
                                                        scr.size.width, barH)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_rootVC.view addSubview:_toolbar];

    NSArray *row1 = @[
        @{@"icon":@"text.viewfinder",   @"label":@"OCR",  @"tag":@(ETBTagOCR)},
        @{@"icon":@"translate",         @"label":@"翻译", @"tag":@(ETBTagTranslate)},
        @{@"icon":@"pencil.tip",        @"label":@"画图", @"tag":@(ETBTagDraw)},
        @{@"icon":@"qrcode.viewfinder", @"label":@"识码", @"tag":@(ETBTagCodeScan)},
        @{@"icon":@"rectangle.dashed",  @"label":@"打码", @"tag":@(ETBTagMosaic)},
    ];
    NSArray *row2 = @[
        @{@"icon":@"doc.on.doc",             @"label":@"复制", @"tag":@(ETBTagCopy)},
        @{@"icon":@"pin",                    @"label":@"贴图", @"tag":@(ETBTagFloating)},
        @{@"icon":@"square.and.arrow.down",  @"label":@"保存", @"tag":@(ETBTagSave)},
        @{@"icon":@"square.and.arrow.up",    @"label":@"分享", @"tag":@(ETBTagShare)},
        @{@"icon":@"ellipsis",               @"label":@"更多", @"tag":@(ETBTagMore)},
    ];

    CGFloat pad = 10.0, gap = 6.0;
    CGFloat bw = (scr.size.width - pad * 2 - gap * 4) / 5.0;

    for (NSInteger i = 0; i < row1.count; i++) {
        UIButton *b = [self makeToolButton:row1[i] width:bw];
        b.frame = CGRectMake(pad + i * (bw + gap), kBarPad, bw, kRowH);
        [_toolbar addSubview:b];
    }
    for (NSInteger i = 0; i < row2.count; i++) {
        UIButton *b = [self makeToolButton:row2[i] width:bw];
        b.frame = CGRectMake(pad + i * (bw + gap), kBarPad + kRowH + kRowGap, bw, kRowH);
        [_toolbar addSubview:b];
    }
}

- (UIButton *)makeToolButton:(NSDictionary *)spec width:(CGFloat)bw {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = [spec[@"tag"] integerValue];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:@selector(toolTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((bw - 24) / 2, 8, 24, 24)];
    iv.image = [Common systemIcon:spec[@"icon"]];
    if (!iv.image) iv.image = [Common systemIcon:@"circle"];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [b addSubview:iv];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 38, bw, 18)];
    lb.text = spec[@"label"];
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];
    return b;
}

#pragma mark - 分发
//
// ⚠️ 用 if/else 链而不是 switch：ObjC++ 下 switch case 内声明带 block 捕获的变量
//    会直接编译报错（v4.0 踩过：cannot jump from switch statement）。
//
- (void)toolTapped:(UIButton *)btn {
    UIImage *img = _imageView.image;
    if (!img) return;
    NSInteger tag = btn.tag;

    if (tag == ETBTagOCR) {
        [Common toast:@"正在识别文字..."];
        [SuperTools ocr:img completion:^(NSString *text) {
            [self presentText:text title:@"OCR 识别结果"];
        }];
    } else if (tag == ETBTagTranslate) {
        [Common toast:@"正在识别并翻译..."];
        [SuperTools translate:img completion:^(NSString *src, NSString *dst) {
            [self presentTranslate:src dst:dst];
        }];
    } else if (tag == ETBTagDraw) {
        [SuperTools draw:img completion:^(UIImage *edited) {
            if (edited) [self replaceImage:edited];
        }];
    } else if (tag == ETBTagCodeScan) {
        [Common toast:@"正在识别二维码..."];
        [SuperTools codeScan:img completion:^(NSString *code) {
            [self presentCodeAction:code];
        }];
    } else if (tag == ETBTagMosaic) {
        [SuperTools mosaic:img completion:^(UIImage *edited) {
            if (edited) [self replaceImage:edited];
        }];
    } else if (tag == ETBTagCopy) {
        [SuperTools copy:img];
    } else if (tag == ETBTagFloating) {
        [SuperTools floating:img];
        [EditToolbarWindow dismiss];
    } else if (tag == ETBTagSave) {
        [SuperTools save:img completion:^(BOOL ok) {
            [Common toast:ok ? @"已保存到相册" : @"保存失败"];
        }];
    } else if (tag == ETBTagShare) {
        [SuperTools share:img fromWindow:_win];
    } else if (tag == ETBTagMore) {
        [self showMoreMenu:img];
    }
}

#pragma mark - 更多二级弹窗

- (void)showMoreMenu:(UIImage *)img {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更多功能"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction actionWithTitle:@"导出 PDF" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *p = [SuperTools exportPDF:img];
        if (p) {
            NSURL *url = [NSURL fileURLWithPath:p];
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                             applicationActivities:nil];
            [Common present:avc fromWindow:_win];
        } else {
            [Common toast:@"导出失败"];
        }
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"压缩图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSData *before = UIImagePNGRepresentation(img);
        UIImage *c = [SuperTools compress:img quality:0.6];
        if (c) {
            NSData *after = UIImageJPEGRepresentation(c, 0.6);
            [self replaceImage:c];
            [Common toast:[NSString stringWithFormat:@"已压缩：%.0fKB → %.0fKB",
                           before.length / 1024.0, after.length / 1024.0]];
        } else {
            [Common toast:@"压缩失败"];
        }
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"去除状态栏" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIImage *s = [SuperTools stripStatusBar:img];
        if (s) { [self replaceImage:s]; [Common toast:@"已去除顶部状态栏"]; }
        else [Common toast:@"处理失败"];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"取色器" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [SuperTools colorPicker:img fromWindow:_win];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        ac.popoverPresentationController.sourceView = _toolbar;
        ac.popoverPresentationController.sourceRect = _toolbar.bounds;
    }
    [Common present:ac fromWindow:_win];
}

#pragma mark - 展示辅助

- (void)presentText:(NSString *)text title:(NSString *)title {
    if (!text || text.length == 0) { [Common toast:@"没有识别到文字"]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = text;
        [Common toast:@"已复制文本"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

- (void)presentTranslate:(NSString *)src dst:(NSString *)dst {
    if (!dst || dst.length == 0) { [Common toast:@"翻译失败"]; return; }
    NSString *msg = [NSString stringWithFormat:@"原文：\n%@\n\n译文：\n%@",
                     src ?: @"", dst ?: @""];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"翻译结果"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制译文" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = dst;
        [Common toast:@"已复制译文"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制原文" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = src ?: @"";
        [Common toast:@"已复制原文"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

// 识码结果：复制链接 / 跳转 Safari
- (void)presentCodeAction:(NSString *)code {
    if (!code || code.length == 0) { [Common toast:@"未识别到二维码"]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"识别结果"
                                                               message:code
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = code;
        [Common toast:@"已复制"];
    }]];
    NSURL *url = [NSURL URLWithString:code];
    if (url && ([[code lowercaseString] hasPrefix:@"http://"] || [[code lowercaseString] hasPrefix:@"https://"])) {
        [ac addAction:[UIAlertAction actionWithTitle:@"用 Safari 打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [Common present:ac fromWindow:_win];
}

- (void)replaceImage:(UIImage *)img {
    if (!img) return;
    _imageView.image = img;
    _sizeLabel.text = [NSString stringWithFormat:@"%.0f × %.0f px", img.size.width, img.size.height];
}

@end
