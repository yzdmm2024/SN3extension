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
#import "AIChatWindow.h"

typedef NS_ENUM(NSInteger, ETBTag) {
    // 第 1 排：识别 / 编辑
    ETBTagOCR        = 1,
    ETBTagTranslate  = 2,
    ETBTagDraw       = 3,
    ETBTagCodeScan   = 4,
    ETBTagAI        = 17,   // 问 AI（大模型）
    // 第 2 排：输出操作
    ETBTagCopy       = 6,
    ETBTagFloating   = 7,
    ETBTagSave       = 8,
    ETBTagShare      = 9,
    ETBTagPhone      = 11,   // 加手机壳
    // 第 3 排：更多工具（直接平铺，不再进二级菜单）
    ETBTagPDF        = 12,   // 导出 PDF
    ETBTagCompress   = 13,   // 压缩
    ETBTagStrip      = 14,   // 去状态栏
    ETBTagColorPick  = 15,   // 取色器
    ETBTagReset      = 16,   // 还原原图
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
    UIImage *_originalImage;   // 还原用：保留最初传入的原图
}

static EditToolbarWindow *_shared = nil;

#pragma mark - 生命周期

+ (void)showWithImage:(UIImage *)image {
    if (!image) { NSLog(@"[SN3] EditToolbarWindow: nil image"); return; }
    if (_shared) [_shared destroyWindow];     // 重入先销毁，避免叠加

    EditToolbarWindow *w = [[EditToolbarWindow alloc] init];
    _shared = w;
    w->_originalImage = image;
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

    // 图片显示区：上方留出关闭条，下方留出三排工具栏
    CGFloat barH = kBarPad * 2 + kRowH * 3 + kRowGap * 2;
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

    // v5.18：从偏好读「按钮顺序 / 禁用集合 / 单/双排」。
    // 默认按 3 排顺序: 1 2 3 4 17 6 7 8 9 11 12 13 14 15 16。
    NSArray<NSNumber *> *defOrder = @[ @(ETBTagOCR), @(ETBTagTranslate), @(ETBTagDraw), @(ETBTagCodeScan), @(ETBTagAI),
                                       @(ETBTagCopy), @(ETBTagFloating), @(ETBTagSave), @(ETBTagShare), @(ETBTagPhone),
                                       @(ETBTagPDF), @(ETBTagCompress), @(ETBTagStrip), @(ETBTagColorPick), @(ETBTagReset) ];
    NSMutableArray<NSNumber *> *savedOrder = [NSMutableArray array];
    NSString *orderStr = [Common stringPref:XZ_KEY_TB_ORDER default:@""];
    if (orderStr.length) [savedOrder addObjectsFromArray:[orderStr componentsSeparatedByString:@","]];
    if (savedOrder.count == 0) [savedOrder addObjectsFromArray:defOrder];
    // 缺项补上 / 多余去掉
    NSMutableSet<NSNumber *> *orderSet = [NSMutableSet setWithArray:savedOrder];
    for (NSNumber *t in defOrder) if (![orderSet containsObject:t]) [savedOrder addObject:t];
    for (NSNumber *t in [savedOrder copy]) {
        if (![defOrder containsObject:t]) [savedOrder removeObject:t];
    }
    NSSet<NSNumber *> *disabled = [NSSet setWithArray:[[Common stringPref:XZ_KEY_TB_DISABLED default:@""] componentsSeparatedByString:@","]];

    // 按钮规格表（icon/label/tag）—— 整个工具栏统一从这里取，settings 排序也用这里
    NSDictionary<NSNumber *, NSDictionary *> *catalog = @{
        @(ETBTagOCR):       @{@"icon":@"text.viewfinder",       @"label":@"OCR"},
        @(ETBTagTranslate): @{@"icon":@"translate",             @"label":@"翻译"},
        @(ETBTagDraw):      @{@"icon":@"pencil.tip",            @"label":@"画图"},
        @(ETBTagCodeScan):  @{@"icon":@"qrcode.viewfinder",     @"label":@"识码"},
        @(ETBTagAI):        @{@"icon":@"sparkles",              @"label":@"AI"},
        @(ETBTagCopy):      @{@"icon":@"doc.on.doc",            @"label":@"复制"},
        @(ETBTagFloating):  @{@"icon":@"pin",                   @"label":@"贴图"},
        @(ETBTagSave):      @{@"icon":@"square.and.arrow.down", @"label":@"保存"},
        @(ETBTagShare):     @{@"icon":@"square.and.arrow.up",   @"label":@"分享"},
        @(ETBTagPhone):     @{@"icon":@"iphone",                @"label":@"加壳"},
        @(ETBTagPDF):       @{@"icon":@"doc.richtext",          @"label":@"PDF"},
        @(ETBTagCompress):  @{@"icon":@"arrow.down.circle",     @"label":@"压缩"},
        @(ETBTagStrip):     @{@"icon":@"menubar.rectangle",     @"label":@"去状态栏"},
        @(ETBTagColorPick): @{@"icon":@"eyedropper",            @"label":@"取色"},
        @(ETBTagReset):     @{@"icon":@"arrow.counterclockwise",@"label":@"还原"},
    };

    BOOL singleRow = ([Common intPref:XZ_KEY_TB_LAYOUT default:0] == 1);

    // 过滤掉禁用的按钮（按用户保存的顺序遍历）
    NSMutableArray<NSNumber *> *enabledTags = [NSMutableArray array];
    for (NSNumber *t in savedOrder) {
        if (![disabled containsObject:t]) [enabledTags addObject:t];
    }

    CGFloat barH = kBarPad * 2 + kRowH + (singleRow ? 0 : (kRowH + kRowGap) * 2);
    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - barH,
                                                        scr.size.width, barH)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_rootVC.view addSubview:_toolbar];

    if (singleRow) {
        // 单排 + 横向滑动：全部按钮放在 UIScrollView 内，避免单屏塞不下被压扁
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, kBarPad, scr.size.width, kRowH)];
        sv.showsHorizontalScrollIndicator = NO;
        sv.alwaysBounceHorizontal = YES;
        [_toolbar addSubview:sv];
        CGFloat bw = 64.0, gap = 8.0;
        CGFloat x = 10.0;
        for (NSNumber *t in enabledTags) {
            NSDictionary *spec = catalog[t];
            NSMutableDictionary *full = [spec mutableCopy];
            full[@"tag"] = t;
            UIButton *b = [self makeToolButton:full width:bw];
            b.frame = CGRectMake(x, 0, bw, kRowH);
            [sv addSubview:b];
            x += bw + gap;
        }
        sv.contentSize = CGSizeMake(x, kRowH);
    } else {
        // 双排（5 + 余下 5）：保留 v5.10 行为，按 5 切片
        NSArray<NSNumber *> *row1Tags = [enabledTags subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)5, enabledTags.count))];
        NSMutableArray<NSNumber *> *row2Tags = [NSMutableArray array];
        for (NSUInteger i = 5; i < enabledTags.count; i++) [row2Tags addObject:enabledTags[i]];

        CGFloat pad = 10.0, gap = 6.0;

        void (^placeRow)(NSArray<NSNumber *> *, CGFloat) = ^(NSArray<NSNumber *> *tags, CGFloat yOff) {
            if (!tags.count) return;
            CGFloat bw = (scr.size.width - pad * 2 - gap * (tags.count - 1)) / (CGFloat)tags.count;
            for (NSInteger i = 0; i < (NSInteger)tags.count; i++) {
                NSDictionary *spec = catalog[tags[i]];
                NSMutableDictionary *full = [spec mutableCopy];
                full[@"tag"] = tags[i];
                UIButton *b = [self makeToolButton:full width:bw];
                b.frame = CGRectMake(pad + i * (bw + gap), kBarPad + yOff, bw, kRowH);
                [_toolbar addSubview:b];
            }
        };
        placeRow(row1Tags, 0);
        placeRow(row2Tags, kRowH + kRowGap);
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
        [SuperTools translate:img completion:^(NSString *src, NSString *dst, NSString *err) {
            [self presentTranslate:src dst:dst err:err];
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
    } else if (tag == ETBTagAI) {
        NSString *key = [Common stringPref:XZ_KEY_AI_KEY default:@""];
        if (key.length == 0) {
            // v5.8：未配置密钥时给出明确指引，不再静默无反应
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"未配置 AI 接口"
                                                                       message:@"请先在「设置 → 超级截图 → AI/大模型」填写：\n• 接口地址（如 https://api.deepseek.com/v1）\n• API Key\n• 模型名（如 deepseek-chat）"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            [Common present:ac fromWindow:_win];
            return;
        }
        [Common toast:@"正在识别图中文字…"];
        [SuperTools ocr:img completion:^(NSString *text) {
            NSString *prompt = [Common stringPref:XZ_KEY_AI_PROMPT default:@""];
            NSString *sys = prompt.length ? prompt : @"请总结图片中的文字内容，并回答我的追问：";
            NSString *first = [NSString stringWithFormat:@"%@\n\n【图片中识别到的文字】\n%@",
                               sys, text.length ? text : @"(未识别到文字，你可直接描述图片)"];
            [AIChatWindow showWithTitle:@"AI 对话" firstText:first];
        }];
    } else if (tag == ETBTagCopy) {
        [SuperTools copy:img];
    } else if (tag == ETBTagFloating) {
        [SuperTools floating:img withScreenRect:_imageView.frame];
        [EditToolbarWindow dismiss];
    } else if (tag == ETBTagSave) {
        [SuperTools save:img completion:^(BOOL ok) {
            [Common toast:ok ? @"已保存到相册" : @"保存失败"];
        }];
    } else if (tag == ETBTagShare) {
        [SuperTools share:img fromWindow:_win];
    } else if (tag == ETBTagPhone) {
        UIImage *c = [SuperTools phoneCase:img];
        if (c) { [self replaceImage:c]; [Common toast:@"已加手机外壳"]; }
        else [Common toast:@"处理失败"];
    } else if (tag == ETBTagPDF) {
        NSString *p = [SuperTools exportPDF:img];
        if (p) {
            NSURL *url = [NSURL fileURLWithPath:p];
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                             applicationActivities:nil];
            [Common present:avc fromWindow:_win];
        } else {
            [Common toast:@"导出失败"];
        }
    } else if (tag == ETBTagCompress) {
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
    } else if (tag == ETBTagStrip) {
        UIImage *s = [SuperTools stripStatusBar:img];
        if (s) { [self replaceImage:s]; [Common toast:@"已去除顶部状态栏"]; }
        else [Common toast:@"处理失败"];
    } else if (tag == ETBTagColorPick) {
        [SuperTools colorPicker:img fromWindow:_win];
    } else if (tag == ETBTagReset) {
        if (_originalImage) { [self replaceImage:_originalImage]; [Common toast:@"已还原原图"]; }
        else [Common toast:@"无原图可还原"];
    }
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

- (void)presentTranslate:(NSString *)src dst:(NSString *)dst err:(NSString *)err {
    if (err && err.length) {
        // v5.8：翻译失败给出明确原因（多因密钥/网络），不再只弹「翻译失败」
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"翻译失败"
                                                                   message:err
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [Common present:ac fromWindow:_win];
        return;
    }
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
