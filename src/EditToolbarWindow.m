//
//  EditToolbarWindow.m — 窗口B：截图编辑两排工具栏（v4.0 超级截图架构）
//
//  规格书对照：
//   - 第一排（识别编辑）：OCR / 翻译 / 画图 / 识码 / 打码
//   - 第二排（输出操作）：复制 / 贴图 / 保存 / 分享 / 更多
//   - 「更多」二级弹窗：长截图 / 导出PDF / 压缩 / 去状态栏 / 取色器
//   - 各功能逻辑集中在 SuperTools 里实现（本窗口只负责 UI 与分发）。
//

#import "EditToolbarWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "SuperTools.h"
#import "LongShotCapture.h"

typedef NS_ENUM(NSInteger, ETBTag) {
    ETBTagOCR = 1, ETBTagTranslate, ETBTagDraw, ETBTagCodeScan, ETBTagMosaic,
    ETBTagCopy, ETBTagFloating, ETBTagSave, ETBTagShare, ETBTagMore,
    // 更多二级
    ETBTagLongShot, ETBTagPDF, ETBTagCompress, ETBTagStripBar, ETBTagColorPicker,
};

// 「更多」内长截图入口桥接
@interface MaskCropLongShotBridge : NSObject
+ (void)startWithBase:(UIImage *)base;
@end

@implementation EditToolbarWindow {
    UIWindow *_win;
    UIImageView *_imageView;     // 显示裁剪结果（居中，aspectFit）
    UIView *_toolbar;            // 底部两排工具栏
}

static EditToolbarWindow *_shared;

#pragma mark - 生命周期

+ (void)showWithImage:(UIImage *)image {
    if (!image) return;
    EditToolbarWindow *w = [EditToolbarWindow new];
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
    if (_win) { _win.hidden = YES; _win = nil; }
    _imageView = nil;
    _toolbar = nil;
}

- (void)buildWindowWithImage:(UIImage *)image {
    _win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _win.windowLevel = UIWindowLevelAlert + 200;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    _win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    // 裁剪结果展示（可点击空白关闭）
    _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 60,
                                        _win.bounds.size.width, _win.bounds.size.height - 260)];
    _imageView.image = image;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.userInteractionEnabled = YES;
    [_win addSubview:_imageView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(onTapClose)];
    [_win addGestureRecognizer:tap];

    [self installToolbar];
    _win.hidden = NO;
}

- (void)onTapClose {
    [EditToolbarWindow dismiss];
}

#pragma mark - 工具栏

- (void)installToolbar {
    CGRect scr = UIScreen.mainScreen.bounds;
    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - 168, scr.size.width, 168)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_win addSubview:_toolbar];

    // 第一排（识别编辑）
    NSArray *row1 = @[
        @{@"icon":@"text.viewfinder",  @"label":@"OCR",   @"tag":@(ETBTagOCR)},
        @{@"icon":@"translate",        @"label":@"翻译", @"tag":@(ETBTagTranslate)},
        @{@"icon":@"pencil.tip",       @"label":@"画图", @"tag":@(ETBTagDraw)},
        @{@"icon":@"qrcode.viewfinder",@"label":@"识码", @"tag":@(ETBTagCodeScan)},
        @{@"icon":@"rectangle.dashed", @"label":@"打码", @"tag":@(ETBTagMosaic)},
    ];
    // 第二排（输出操作）
    NSArray *row2 = @[
        @{@"icon":@"doc.on.doc",       @"label":@"复制", @"tag":@(ETBTagCopy)},
        @{@"icon":@"pin",              @"label":@"贴图", @"tag":@(ETBTagFloating)},
        @{@"icon":@"square.and.arrow.down", @"label":@"保存", @"tag":@(ETBTagSave)},
        @{@"icon":@"square.and.arrow.up",   @"label":@"分享", @"tag":@(ETBTagShare)},
        @{@"icon":@"ellipsis",         @"label":@"更多", @"tag":@(ETBTagMore)},
    ];

    CGFloat bw = 62, bh = 68, gap = 10;
    CGFloat rowW = 5 * bw + 4 * gap;
    CGFloat x = (_toolbar.bounds.size.width - rowW) / 2;
    for (NSInteger i = 0; i < row1.count; i++) {
        UIButton *b = [self makeToolButton:row1[i]];
        b.frame = CGRectMake(x + i * (bw + gap), 10, bw, bh);
        [_toolbar addSubview:b];
    }
    for (NSInteger i = 0; i < row2.count; i++) {
        UIButton *b = [self makeToolButton:row2[i]];
        b.frame = CGRectMake(x + i * (bw + gap), 10 + bh + 8, bw, bh);
        [_toolbar addSubview:b];
    }
}

- (UIButton *)makeToolButton:(NSDictionary *)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = [a[@"tag"] integerValue];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 12;
    [b addTarget:self action:@selector(toolTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((62-24)/2, 7, 24, 24)];
    iv.image = [UIImage systemImageNamed:a[@"icon"]];
    iv.tintColor = UIColor.whiteColor;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [b addSubview:iv];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 38, 62, 18)];
    lb.text = a[@"label"];
    lb.textColor = UIColor.whiteColor;
    lb.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];
    return b;
}

#pragma mark - 分发

- (void)toolTapped:(UIButton *)btn {
    UIImage *img = _imageView.image;
    if (!img) return;
    switch ((ETBTag)btn.tag) {
        case ETBTagOCR:      [SuperTools ocr:img completion:^(NSString *text) { [self presentText:text title:@"OCR 识别结果"]; }]; break;
        case ETBTagTranslate:[SuperTools translate:img completion:^(NSString *dst, NSString *src) { [self presentText:src title:@"翻译原文"]; [self presentText:dst title:@"翻译译文"]; }]; break;
        case ETBTagDraw:     [SuperTools draw:img completion:^(UIImage *edited) { if (edited) [self replaceImage:edited]; }]; break;
        case ETBTagCodeScan: [SuperTools codeScan:img completion:^(NSString *code) { [self presentCodeAction:code]; }]; break;
        case ETBTagMosaic:   [SuperTools mosaic:img completion:^(UIImage *edited) { if (edited) [self replaceImage:edited]; }]; break;

        case ETBTagCopy:     [SuperTools copy:img]; [EditToolbarWindow dismiss]; break;
        case ETBTagFloating: [SuperTools floating:img]; [EditToolbarWindow dismiss]; break;
        case ETBTagSave:     [SuperTools save:img completion:^(BOOL ok) { [Common toast:ok ? @"已保存到相册" : @"保存失败"]; }]; break;
        case ETBTagShare:    [SuperTools share:img fromWindow:_win]; break;
        case ETBTagMore:     [self showMoreMenu:img]; break;

        default: break;
    }
}

// 更多二级弹窗
- (void)showMoreMenu:(UIImage *)img {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更多功能"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"长截图" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        // 回窗口A长截图采集：以当前图为基础继续采集（规格书：更多内也含长截图）
        [MaskCropLongShotBridge startWithBase:img];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导出PDF" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *p = [SuperTools exportPDF:img];
        [Common toast:p ? @"已导出 PDF" : @"导出失败"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"压缩" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIImage *c = [SuperTools compress:img quality:0.6];
        if (c) [self replaceImage:c];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"去状态栏" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIImage *s = [SuperTools stripStatusBar:img];
        if (s) [self replaceImage:s];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取色器" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [SuperTools colorPicker:img];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIWindow *keyWin = [Common topWindow];
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (root) [root presentViewController:ac animated:YES completion:nil];
    else [Common toast:@"更多功能请在 App 内使用"];
}

#pragma mark - 展示辅助

- (void)presentText:(NSString *)text title:(NSString *)title {
    if (!text.length) { [Common toast:title]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:text
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    UIWindow *keyWin = [Common topWindow];
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (root) [root presentViewController:ac animated:YES completion:nil];
}

// 识码结果：复制链接 / 跳转 Safari
- (void)presentCodeAction:(NSString *)code {
    if (!code.length) { [Common toast:@"未识别到码"]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"识别到二维码"
                                                                message:code
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = code;
    }]];
    BOOL isURL = [code hasPrefix:@"http"];
    if (isURL) {
        [ac addAction:[UIAlertAction actionWithTitle:@"用 Safari 打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:code] options:@{} completionHandler:nil];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    UIWindow *keyWin = [Common topWindow];
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (root) [root presentViewController:ac animated:YES completion:nil];
}

- (void)replaceImage:(UIImage *)img {
    _imageView.image = img;
}

@end

// 更多内「长截图」桥接：把当前图作为第 1 帧，进入长截图采集
@implementation MaskCropLongShotBridge
+ (void)startWithBase:(UIImage *)base {
    if (!base) return;
    [LongShotCapture.sharedInstance reset];
    [LongShotCapture.sharedInstance addFrame:base];
    [EditToolbarWindow dismiss];
    // TODO: 复用 MaskCropWindow 进入长截图采集模式（v4.1）
    [Common toast:@"长截图采集：请在 App 内使用遮罩入口"];
}
@end
