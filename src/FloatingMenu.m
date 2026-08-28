//
//  FloatingMenu.m — 浮动操作菜单（v3.11 重构）
//
//  流程：
//    控制中心 / 系统截屏 → 截屏 → 显示选择器（2 图标：长截图 / 自由截图）
//      · 长截图  → 抓当前可滚动内容拼接（无则回退整屏）→ 操作行
//      · 自由截图 → 进入交互裁剪（手绘/拖动/缩放选区）→ 确认 → 操作行
//    操作行（一行）：OCR / 翻译 / 问AI / 保存 / 复制 / 分享 / 悬浮贴图
//
//  引擎类（VisionOCR / TranslateEngine / AskAIEngine / LongShotController）
//  已编译进 dylib，通过 NSClassFromString 运行时调用。
//

#import "FloatingMenu.h"
#import "Common.h"
#import <objc/runtime.h>

// 操作行动作
typedef NS_ENUM(NSUInteger, XZRowAction) {
    XZRowOCR = 0,
    XZRowTranslate,
    XZRowAskAI,
    XZRowSave,
    XZRowCopy,
    XZRowShare,
    XZRowFloating,
    XZRowCount
};

static UIWindow *_menuWindow = nil;     // 选择器
static UIWindow *_cropWindow = nil;     // 裁剪
static UIWindow *_actionWindow = nil;   // 操作行
static UIWindow *_floatingWindow = nil; // 悬浮贴图
static UIImage *_currentImage = nil;

// 裁剪手势状态
static CGPoint _cropStart;
static CGPoint _cropGrab;
static NSInteger _cropMode; // 0 无 / 1 手绘 / 2 移动

@implementation FloatingMenu

#pragma mark - 入口：选择器

+ (void)showChooser:(UIImage *)screenshot {
    if (!screenshot) return;
    _currentImage = screenshot;
    [self dismissAll];

    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.96];
    card.layer.cornerRadius = 24;
    card.clipsToBounds = YES;
    [win addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"SN3 延伸板";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    NSArray *choices = @[
        @{@"icon": @"rectangle.compress.vertical", @"label": @"长截图", @"color": @0xFF9500},
        @{@"icon": @"crop", @"label": @"自由截图", @"color": @0xFF2D55},
    ];

    NSMutableArray *btns = [NSMutableArray array];
    for (NSInteger i = 0; i < choices.count; i++) {
        NSDictionary *c = choices[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.tag = i;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        b.layer.cornerRadius = 18;
        [b addTarget:self action:@selector(chooseTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *iv = [[UIImageView alloc] init];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.image = [UIImage systemImageNamed:c[@"icon"]];
        iv.tintColor = [self colorFromHex:[c[@"color"] unsignedIntegerValue]];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [b addSubview:iv];

        UILabel *lb = [[UILabel alloc] init];
        lb.translatesAutoresizingMaskIntoConstraints = NO;
        lb.text = c[@"label"];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        lb.textAlignment = NSTextAlignmentCenter;
        [b addSubview:lb];

        [iv.widthAnchor constraintEqualToConstant:42].active = YES;
        [iv.heightAnchor constraintEqualToConstant:42].active = YES;
        [iv.centerXAnchor constraintEqualToAnchor:b.centerXAnchor].active = YES;
        [iv.topAnchor constraintEqualToAnchor:b.topAnchor constant:18].active = YES;
        [lb.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:8].active = YES;
        [lb.centerXAnchor constraintEqualToAnchor:b.centerXAnchor].active = YES;
        [lb.bottomAnchor constraintEqualToAnchor:b.bottomAnchor constant:-14].active = YES;

        [card addSubview:b];
        [btns addObject:b];
    }

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor lightGrayColor];
    [closeBtn addTarget:self action:@selector(dismissAll) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];

    UIView *b0 = btns[0];
    UIView *b1 = btns[1];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:win.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:win.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],
        [card.heightAnchor constraintEqualToConstant:240],

        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [closeBtn.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        [closeBtn.widthAnchor constraintEqualToConstant:32],
        [closeBtn.heightAnchor constraintEqualToConstant:32],

        [b0.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24],
        [b0.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:34],
        [b0.widthAnchor constraintEqualToConstant:110],
        [b0.heightAnchor constraintEqualToConstant:110],

        [b1.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24],
        [b1.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-34],
        [b1.widthAnchor constraintEqualToConstant:110],
        [b1.heightAnchor constraintEqualToConstant:110],
    ]];

    _menuWindow = win;
    win.hidden = NO;

    card.transform = CGAffineTransformMakeScale(0.85, 0.85);
    card.alpha = 0;
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8
                     options:UIViewAnimationOptionCurveEaseOut
                  animations:^{
        card.transform = CGAffineTransformIdentity;
        card.alpha = 1;
    } completion:nil];
}

+ (void)chooseTapped:(UIButton *)sender {
    [self dismissAll];
    if (sender.tag == 0) {
        [self doLongShot];
    } else {
        [self doFreeCrop:_currentImage];
    }
}

#pragma mark - 长截图

+ (void)doLongShot {
    // 先收掉我们的窗口，让底层 App 成为 keyWindow，再抓可滚动内容
    UIImage *src = _currentImage;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [Common toast:@"正在生成长截图..."];
        Class longShot = NSClassFromString(@"LongShotController");
        if (!longShot) { [Common toast:@"长截图模块未加载"]; return; }

        SEL sel = @selector(captureFromKeyWindowCompletion:);
        void (*func)(id, SEL, void(^)(UIImage*)) = (void(*)(id, SEL, void(^)(UIImage*)))[longShot methodForSelector:sel];
        func(longShot, sel, ^(UIImage *stitched) {
            UIImage *result = (stitched && stitched.size.height > 10) ? stitched : src;
            _currentImage = result;
            [self showActionRow:result];
        });
    });
}

#pragma mark - 自由截图：交互裁剪

+ (void)doFreeCrop:(UIImage *)image {
    if (!image) return;

    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 200;
    win.backgroundColor = [UIColor blackColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    // 计算 fit 矩形（imageView 尺寸 = 显示区域，便于坐标换算）
    CGFloat ratio = image.size.width / image.size.height;
    CGFloat ivW = win.bounds.size.width - 20;
    CGFloat ivH = ivW / ratio;
    CGFloat maxH = win.bounds.size.height - 160;
    if (ivH > maxH) { ivH = maxH; ivW = ivH * ratio; }
    CGFloat ivX = (win.bounds.size.width - ivW) / 2;
    CGFloat ivY = (win.bounds.size.height - 120 - ivH) / 2;

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(ivX, ivY, ivW, ivH)];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = YES;
    [win addSubview:iv];

    // 裁剪框（imageView 坐标系）
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(ivW*0.12, ivH*0.12, ivW*0.76, ivH*0.76)];
    box.layer.borderColor = [UIColor systemYellowColor].CGColor;
    box.layer.borderWidth = 2;
    box.layer.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05].CGColor;
    [iv addSubview:box];

    // 四角把手（仅用右下角做缩放，符合单手习惯）
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(box.bounds.size.width - 22, box.bounds.size.height - 22, 24, 24)];
    handle.backgroundColor = [UIColor systemYellowColor];
    handle.layer.cornerRadius = 12;
    [box addSubview:handle];

    // 手势：imageView 上 手绘/移动；handle 上 缩放
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cropPan:)];
    [iv addGestureRecognizer:pan];
    UIPanGestureRecognizer *hpan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cropResize:)];
    [handle addGestureRecognizer:hpan];

    objc_setAssociatedObject(win, "cropIV", iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, "cropBox", box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, "cropImage", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(20, win.bounds.size.height - 70, 130, 46);
    cancel.backgroundColor = [UIColor systemGray3Color];
    cancel.layer.cornerRadius = 23;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [cancel addTarget:self action:@selector(dismissAll) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:cancel];

    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem];
    confirm.frame = CGRectMake(win.bounds.size.width - 150, win.bounds.size.height - 70, 130, 46);
    confirm.backgroundColor = [UIColor systemBlueColor];
    confirm.layer.cornerRadius = 23;
    [confirm setTitle:@"裁剪并继续" forState:UIControlStateNormal];
    [confirm setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    confirm.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [confirm addTarget:self action:@selector(cropConfirm:) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:confirm];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, ivY - 30, win.bounds.size.width, 20)];
    tip.text = @"拖动框移动 · 拖黄点缩放 · 框外拖动手绘";
    tip.textColor = [UIColor lightGrayColor];
    tip.font = [UIFont systemFontOfSize:12];
    tip.textAlignment = NSTextAlignmentCenter;
    [win addSubview:tip];

    _cropWindow = win;
    win.hidden = NO;
}

+ (void)cropPan:(UIPanGestureRecognizer *)pan {
    UIImageView *iv = nil;
    UIView *box = nil;
    for (UIWindow *w in @[_cropWindow]) {
        if (w) { iv = objc_getAssociatedObject(w, "cropIV"); box = objc_getAssociatedObject(w, "cropBox"); }
    }
    if (!iv || !box) return;
    CGPoint loc = [pan locationInView:iv];

    if (pan.state == UIGestureRecognizerStateBegan) {
        CGRect bf = box.frame;
        if (CGRectContainsPoint(bf, loc)) {
            _cropMode = 2; // 移动
            _cropGrab = CGPointMake(loc.x - bf.origin.x, loc.y - bf.origin.y);
        } else {
            _cropMode = 1; // 手绘
            _cropStart = loc;
            box.frame = CGRectMake(loc.x, loc.y, 0, 0);
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGRect b = iv.bounds;
        if (_cropMode == 1) {
            CGFloat x = MIN(_cropStart.x, loc.x);
            CGFloat y = MIN(_cropStart.y, loc.y);
            CGFloat w = fabs(loc.x - _cropStart.x);
            CGFloat h = fabs(loc.y - _cropStart.y);
            box.frame = CGRectMake(MAX(0, x), MAX(0, y), MIN(w, b.size.width), MIN(h, b.size.height));
        } else if (_cropMode == 2) {
            CGFloat x = loc.x - _cropGrab.x;
            CGFloat y = loc.y - _cropGrab.y;
            x = MAX(0, MIN(x, b.size.width - box.frame.size.width));
            y = MAX(0, MIN(y, b.size.height - box.frame.size.height));
            box.frame = CGRectMake(x, y, box.frame.size.width, box.frame.size.height);
        }
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        [self clampBox:box inView:iv];
        _cropMode = 0;
    }
}

+ (void)cropResize:(UIPanGestureRecognizer *)pan {
    UIView *handle = (UIView *)pan.view;
    UIView *box = handle.superview;
    UIImageView *iv = (UIImageView *)box.superview;
    if (!box || !iv) return;
    CGPoint loc = [pan locationInView:iv];

    if (pan.state == UIGestureRecognizerStateChanged || pan.state == UIGestureRecognizerStateBegan) {
        CGFloat w = MAX(30, loc.x - box.frame.origin.x);
        CGFloat h = MAX(30, loc.y - box.frame.origin.y);
        w = MIN(w, iv.bounds.size.width - box.frame.origin.x);
        h = MIN(h, iv.bounds.size.height - box.frame.origin.y);
        box.frame = CGRectMake(box.frame.origin.x, box.frame.origin.y, w, h);
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        [self clampBox:box inView:iv];
    }
}

+ (void)clampBox:(UIView *)box inView:(UIImageView *)iv {
    CGRect b = iv.bounds;
    CGFloat x = MAX(0, box.frame.origin.x);
    CGFloat y = MAX(0, box.frame.origin.y);
    CGFloat w = MIN(box.frame.size.width, b.size.width - x);
    CGFloat h = MIN(box.frame.size.height, b.size.height - y);
    box.frame = CGRectMake(x, y, MAX(20, w), MAX(20, h));
}

+ (void)cropConfirm:(UIButton *)btn {
    UIWindow *win = _cropWindow;
    UIImageView *iv = objc_getAssociatedObject(win, "cropIV");
    UIView *box = objc_getAssociatedObject(win, "cropBox");
    UIImage *image = objc_getAssociatedObject(win, "cropImage");
    if (!iv || !box || !image) { [self dismissAll]; return; }

    CGRect boxInIV = box.frame;
    CGFloat sx = image.size.width / iv.bounds.size.width;
    CGFloat sy = image.size.height / iv.bounds.size.height;
    CGRect cropRect = CGRectMake(boxInIV.origin.x * sx, boxInIV.origin.y * sy,
                                 boxInIV.size.width * sx, boxInIV.size.height * sy);
    cropRect = CGRectIntersection(cropRect, CGRectMake(0, 0, image.size.width, image.size.height));
    if (cropRect.size.width < 4 || cropRect.size.height < 4) { [Common toast:@"选区太小"]; return; }

    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    UIImage *cropped = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);

    [self dismissAll];
    if (cropped) {
        _currentImage = cropped;
        [self showActionRow:cropped];
    }
}

#pragma mark - 操作行

+ (void)showActionRow:(UIImage *)image {
    if (!image) return;
    _currentImage = image;
    [self dismissAll];

    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 150;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    // 半透明遮罩，点空白处关闭
    UIButton *mask = [UIButton buttonWithType:UIButtonTypeCustom];
    mask.frame = win.bounds;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [mask addTarget:self action:@selector(dismissAll) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:mask];

    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    CGFloat barH = 104;
    bar.frame = CGRectMake(0, win.bounds.size.height - barH, win.bounds.size.width, barH);
    bar.layer.cornerRadius = 18;
    bar.clipsToBounds = YES;
    [win addSubview:bar];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 0, bar.bounds.size.width - 20, barH)];
    scroll.showsHorizontalScrollIndicator = NO;
    [bar addSubview:scroll];

    NSArray *acts = @[
        @{@"icon": @"text.viewfinder", @"label": @"OCR", @"color": @0x007AFF},
        @{@"icon": @"translate", @"label": @"翻译", @"color": @0x34C759},
        @{@"icon": @"brain", @"label": @"问AI", @"color": @0xAF52DE},
        @{@"icon": @"photo.badge.arrow.down", @"label": @"保存", @"color": @0x5AC8FA},
        @{@"icon": @"doc.on.doc", @"label": @"复制", @"color": @0x4CD964},
        @{@"icon": @"square.and.arrow.up", @"label": @"分享", @"color": @0x007AFF},
        @{@"icon": @"pin", @"label": @"悬浮贴图", @"color": @0xFF9500},
    ];

    CGFloat bw = 72, gap = 8;
    for (NSInteger i = 0; i < acts.count; i++) {
        NSDictionary *a = acts[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8 + i * (bw + gap), 8, bw, barH - 16);
        b.tag = i;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        b.layer.cornerRadius = 14;
        [b addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(bw/2 - 16, 10, 32, 32)];
        iv.image = [UIImage systemImageNamed:a[@"icon"]];
        iv.tintColor = [self colorFromHex:[a[@"color"] unsignedIntegerValue]];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [b addSubview:iv];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 46, bw, 18)];
        lb.text = a[@"label"];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:11];
        lb.textAlignment = NSTextAlignmentCenter;
        [b addSubview:lb];

        [scroll addSubview:b];
    }
    scroll.contentSize = CGSizeMake(8 + acts.count * (bw + gap) + 8, barH);

    _actionWindow = win;
    win.hidden = NO;

    bar.transform = CGAffineTransformMakeTranslation(0, barH);
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.6
                     options:UIViewAnimationOptionCurveEaseOut
                  animations:^{ bar.transform = CGAffineTransformIdentity; } completion:nil];
}

+ (void)rowTapped:(UIButton *)sender {
    UIImage *img = _currentImage;
    if (!img) return;
    switch (sender.tag) {
        case XZRowOCR:      [self dismissAll]; [self doOCR:img]; break;
        case XZRowTranslate: [self dismissAll]; [self doTranslate:img]; break;
        case XZRowAskAI:     [self dismissAll]; [self doAskAI:img]; break;
        case XZRowSave:      [self dismissAll]; [self doSaveAlbum:img]; break;
        case XZRowCopy:      [self dismissAll]; [self doCopy:img]; break;
        case XZRowShare:     [self dismissAll]; [self doShare:img]; break;
        case XZRowFloating:  [self dismissAll]; [self doFloating:img]; break;
    }
}

#pragma mark - 功能实现

+ (void)doOCR:(UIImage *)image {
    [Common toast:@"正在OCR识别中..."];
    Class visionOCR = NSClassFromString(@"VisionOCR");
    if (!visionOCR) { [Common toast:@"OCR模块未加载"]; return; }

    SEL sel = @selector(recognizeImage:languages:completion:);
    if ([visionOCR respondsToSelector:sel]) {
        void (*func)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)) = (void(*)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)))[visionOCR methodForSelector:sel];
        func(visionOCR, sel, image, [Common ocrLanguages], ^(NSString *text) {
            if (text.length) {
                [UIPasteboard generalPasteboard].string = text;
                [Common toast:[NSString stringWithFormat:@"OCR完成，已复制\n%@", [text substringToIndex:MIN(60, text.length)]]];
            } else {
                [Common toast:@"OCR未识别到文字"];
            }
        });
    }
}

+ (void)doTranslate:(UIImage *)image {
    NSString *appid = [Common stringPref:XZ_KEY_TRANS_APPID default:@""];
    NSString *key = [Common stringPref:XZ_KEY_TRANS_KEY default:@""];
    NSString *target = [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh"];

    if (!appid.length || !key.length) {
        [Common toast:@"翻译需先在「设置→SN3延伸板」填百度翻译 AppID/密钥"];
        return;
    }

    [Common toast:@"正在翻译中..."];
    Class visionOCR = NSClassFromString(@"VisionOCR");
    Class transEngine = NSClassFromString(@"TranslateEngine");
    if (!visionOCR || !transEngine) { [Common toast:@"翻译模块未加载"]; return; }

    SEL ocrSel = @selector(recognizeImage:languages:completion:);
    void (*ocrFunc)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)) = (void(*)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)))[visionOCR methodForSelector:ocrSel];
    ocrFunc(visionOCR, ocrSel, image, [Common ocrLanguages], ^(NSString *text) {
        if (!text.length) { [Common toast:@"未识别到文字"]; return; }

        SEL transSel = @selector(translateText:fromLang:toLang:appid:appKey:completion:);
        void (*transFunc)(id, SEL, NSString*, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)) = (void(*)(id, SEL, NSString*, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)))[transEngine methodForSelector:transSel];
        transFunc(transEngine, transSel, text, @"auto", target, appid, key, ^(NSString *translated, NSString *error) {
            if (translated.length) {
                [UIPasteboard generalPasteboard].string = translated;
                [Common toast:[NSString stringWithFormat:@"翻译完成：%@", [translated substringToIndex:MIN(50, translated.length)]]];
            } else {
                [Common toast:error ?: @"翻译失败"];
            }
        });
    });
}

+ (void)doAskAI:(UIImage *)image {
    NSString *baseURL = [Common stringPref:XZ_KEY_AI_BASEURL default:@""];
    NSString *apiKey = [Common stringPref:XZ_KEY_AI_KEY default:@""];
    NSString *model = [Common stringPref:XZ_KEY_AI_MODEL default:@""];
    NSString *prompt = [Common stringPref:XZ_KEY_AI_PROMPT default:@"请描述这张图片中的内容"];

    if (!baseURL.length || !apiKey.length) {
        [Common toast:@"AI需先在「设置→SN3延伸板」填接口地址和密钥"];
        return;
    }

    [Common toast:@"正在询问AI..."];
    Class aiEngine = NSClassFromString(@"AskAIEngine");
    if (!aiEngine) { [Common toast:@"AI模块未加载"]; return; }

    // 把图片转 base64 作为提示的一部分（兼容 OpenAI 多模态）
    NSString *b64 = @"";
    if (image) {
        NSData *d = UIImageJPEGRepresentation(image, 0.8);
        if (d) b64 = [d base64EncodedStringWithOptions:0];
    }
    NSString *fullPrompt = b64.length
        ? [NSString stringWithFormat:@"%@\n\n[图片 base64] %@", prompt, b64]
        : prompt;

    SEL sel = @selector(askText:baseURL:apiKey:model:completion:);
    void (*func)(id, SEL, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)) = (void(*)(id, SEL, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)))[aiEngine methodForSelector:sel];
    func(aiEngine, sel, fullPrompt, baseURL, apiKey, model, ^(NSString *answer, NSString *error) {
        if (answer.length) {
            [UIPasteboard generalPasteboard].string = answer;
            [Common toast:[NSString stringWithFormat:@"AI回复：%@", [answer substringToIndex:MIN(50, answer.length)]]];
        } else {
            [Common toast:error ?: @"AI请求失败"];
        }
    });
}

+ (void)doSaveAlbum:(UIImage *)image {
    [Common toast:@"正在保存到相册..."];
    Class imgUtils = NSClassFromString(@"ImageUtils");
    if (!imgUtils) { [Common toast:@"保存模块未加载"]; return; }

    SEL sel = @selector(saveToCustomAlbum:completion:);
    void (*func)(id, SEL, UIImage*, void(^)(BOOL, NSError*)) = (void(*)(id, SEL, UIImage*, void(^)(BOOL, NSError*)))[imgUtils methodForSelector:sel];
    func(imgUtils, sel, image, ^(BOOL success, NSError *error) {
        if (success) {
            [Common toast:@"已保存到「SN3截图」相册"];
        } else {
            [Common toast:[NSString stringWithFormat:@"保存失败: %@", error.localizedDescription ?: @"未知错误"]];
        }
    });
}

+ (void)doCopy:(UIImage *)image {
    [UIPasteboard generalPasteboard].image = image;
    [Common toast:@"图片已复制到剪贴板"];
}

+ (void)doShare:(UIImage *)image {
    UIWindow *keyWin = [Common topWindow];
    if (!keyWin) return;

    UIActivityViewController *avc = [[UIActivityViewController alloc]
                                      initWithActivityItems:@[image] applicationActivities:nil];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        avc.popoverPresentationController.sourceView = keyWin;
        avc.popoverPresentationController.sourceRect = CGRectMake(keyWin.bounds.size.width/2, keyWin.bounds.size.height/2, 0, 0);
    }

    UIViewController *presenter = keyWin.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:avc animated:YES completion:nil];
}

+ (void)doFloating:(UIImage *)image {
    if (_floatingWindow) { _floatingWindow.hidden = YES; _floatingWindow = nil; }

    CGFloat fw = 120, fh = 120 * image.size.height / image.size.width;
    if (fh > 200) { fh = 200; fw = 200 * image.size.width / image.size.height; }
    CGFloat fx = UIScreen.mainScreen.bounds.size.width - fw - 20;
    CGFloat fy = UIScreen.mainScreen.bounds.size.height / 2 - fh / 2;

    UIWindow *fwin = [[UIWindow alloc] initWithFrame:CGRectMake(fx, fy, fw, fh)];
    fwin.windowLevel = UIWindowLevelAlert + 300;
    fwin.backgroundColor = [UIColor clearColor];
    fwin.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) fwin.windowScene = [Common activeWindowScene];

    UIImageView *fiv = [[UIImageView alloc] initWithFrame:fwin.bounds];
    fiv.image = image;
    fiv.contentMode = UIViewContentModeScaleAspectFit;
    fiv.layer.cornerRadius = 12;
    fiv.clipsToBounds = YES;
    fiv.layer.borderColor = [UIColor whiteColor].CGColor;
    fiv.layer.borderWidth = 2;
    [fwin addSubview:fiv];

    UIButton *fb = [UIButton buttonWithType:UIButtonTypeSystem];
    fb.frame = CGRectMake(fw - 28, 0, 28, 28);
    [fb setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    fb.tintColor = [UIColor redColor];
    [fb addTarget:self action:@selector(closeFloating) forControlEvents:UIControlEventTouchUpInside];
    [fwin addSubview:fb];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloating:)];
    [fwin addGestureRecognizer:pan];

    _floatingWindow = fwin;
    fwin.hidden = NO;

    fwin.transform = CGAffineTransformMakeScale(0.3, 0.3);
    fwin.alpha = 0;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8
                     options:UIViewAnimationOptionCurveEaseOut
                  animations:^{
        fwin.transform = CGAffineTransformIdentity;
        fwin.alpha = 1;
    } completion:nil];
}

+ (void)closeFloating {
    if (_floatingWindow) {
        _floatingWindow.hidden = YES;
        _floatingWindow = nil;
    }
}

+ (void)panFloating:(UIPanGestureRecognizer *)pan {
    if (!_floatingWindow) return;
    CGPoint t = [pan translationInView:_floatingWindow.superview];
    _floatingWindow.center = CGPointMake(_floatingWindow.center.x + t.x, _floatingWindow.center.y + t.y);
    [pan setTranslation:CGPointZero inView:_floatingWindow.superview];
}

#pragma mark - 关闭

+ (void)dismissAll {
    if (_menuWindow)    { _menuWindow.hidden = YES;    _menuWindow = nil; }
    if (_cropWindow)    { _cropWindow.hidden = YES;    _cropWindow = nil; }
    if (_actionWindow)  { _actionWindow.hidden = YES;  _actionWindow = nil; }
    // 悬浮贴图保留，由用户手动关闭
}

#pragma mark - 辅助

+ (UIColor *)colorFromHex:(NSUInteger)hex {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

@end
