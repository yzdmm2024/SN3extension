//
//  FloatingMenu.m — 浮动操作菜单
//
//  截屏后弹出半透明覆盖层，展示功能按钮网格。
//  所有功能通过 NSClassFromString 运行时调用，避免编译时强依赖。
//

#import "FloatingMenu.h"
#import "Common.h"
#import <objc/runtime.h>

// 菜单按钮定义
typedef NS_ENUM(NSUInteger, XZAction) {
    XZActionOCR = 0,
    XZActionTranslate,
    XZActionAskAI,
    XZActionLongShot,
    XZActionCrop,
    XZActionSaveAlbum,
    XZActionCopy,
    XZActionShare,
    XZActionFloating,
    XZActionCount
};

static UIWindow *_menuWindow = nil;
static UIImage *_currentImage = nil;
static UIWindow *_floatingWindow = nil;

@implementation FloatingMenu

+ (void)showWithImage:(UIImage *)screenshot {
    if (!screenshot) return;
    _currentImage = screenshot;
    [self dismiss];
    
    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];
    
    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.95];
    content.layer.cornerRadius = 20;
    content.clipsToBounds = YES;
    [win addSubview:content];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"选择操作";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [content addSubview:title];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor lightGrayColor];
    [closeBtn addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:closeBtn];
    
    // 按钮网格
    CGFloat spacing = 16;
    CGFloat btnSize = 64;
    NSInteger cols = 3;
    CGFloat totalW = cols * btnSize + (cols - 1) * spacing;
    CGFloat startX = (UIScreen.mainScreen.bounds.size.width - 80 - totalW) / 2;
    
    NSArray *actions = @[
        @{@"icon": @"text.viewfinder", @"label": @"OCR识别", @"color": @0x007AFF},
        @{@"icon": @"translate", @"label": @"翻译", @"color": @0x34C759},
        @{@"icon": @"brain", @"label": @"问AI", @"color": @0xAF52DE},
        @{@"icon": @"rectangle.compress.vertical", @"label": @"长截图", @"color": @0xFF9500},
        @{@"icon": @"crop", @"label": @"自由截图", @"color": @0xFF2D55},
        @{@"icon": @"photo.badge.arrow.down", @"label": @"保存", @"color": @0x5AC8FA},
        @{@"icon": @"doc.on.doc", @"label": @"复制", @"color": @0x4CD964},
        @{@"icon": @"square.and.arrow.up", @"label": @"分享", @"color": @0x007AFF},
        @{@"icon": @"pin", @"label": @"悬浮贴图", @"color": @0xFF9500},
    ];
    
    for (NSInteger i = 0; i < actions.count; i++) {
        NSDictionary *a = actions[i];
        NSInteger row = i / cols;
        NSInteger col = i % cols;
        
        CGFloat x = startX + col * (btnSize + spacing);
        CGFloat y = 54 + row * (btnSize + spacing + 8);
        
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(x, y, btnSize, btnSize + 20);
        btn.tag = i;
        [btn addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
        
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(btnSize/2 - 16, 0, 32, 32)];
        iv.image = [UIImage systemImageNamed:a[@"icon"]];
        iv.tintColor = [self colorFromHex:[a[@"color"] unsignedIntegerValue]];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [btn addSubview:iv];
        
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(-8, 38, btnSize + 16, 18)];
        lb.text = a[@"label"];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:11];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.adjustsFontSizeToFitWidth = YES;
        [btn addSubview:lb];
        
        [content addSubview:btn];
    }
    
    NSInteger rows = (actions.count + cols - 1) / cols;
    CGFloat contentH = 54 + rows * (btnSize + spacing + 8) + 20;
    CGFloat contentW = UIScreen.mainScreen.bounds.size.width - 80;
    
    [NSLayoutConstraint activateConstraints:@[
        [content.centerXAnchor constraintEqualToAnchor:win.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:win.centerYAnchor],
        [content.widthAnchor constraintEqualToConstant:contentW],
        [content.heightAnchor constraintEqualToConstant:contentH],
        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [title.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [closeBtn.topAnchor constraintEqualToAnchor:content.topAnchor constant:8],
        [closeBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [closeBtn.widthAnchor constraintEqualToConstant:32],
        [closeBtn.heightAnchor constraintEqualToConstant:32],
    ]];
    
    _menuWindow = win;
    win.hidden = NO;
    
    content.transform = CGAffineTransformMakeScale(0.8, 0.8);
    content.alpha = 0;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8
                     options:UIViewAnimationOptionCurveEaseOut
                  animations:^{
        content.transform = CGAffineTransformIdentity;
        content.alpha = 1;
    } completion:nil];
}

+ (void)dismiss {
    if (_menuWindow) {
        _menuWindow.hidden = YES;
        _menuWindow = nil;
    }
}

+ (void)actionTapped:(UIButton *)sender {
    UIImage *img = _currentImage;
    if (!img) return;
    [self dismiss];
    
    switch (sender.tag) {
        case XZActionOCR:
            [self doOCR:img];
            break;
        case XZActionTranslate:
            [self doTranslate:img];
            break;
        case XZActionAskAI:
            [self doAskAI:img];
            break;
        case XZActionLongShot:
            [self doLongShot];
            break;
        case XZActionCrop:
            [self doCrop:img];
            break;
        case XZActionSaveAlbum:
            [self doSaveAlbum:img];
            break;
        case XZActionCopy:
            [self doCopy:img];
            break;
        case XZActionShare:
            [self doShare:img];
            break;
        case XZActionFloating:
            [self doFloating:img];
            break;
    }
}

#pragma mark - 功能实现

+ (void)doOCR:(UIImage *)image {
    [Common toast:@"正在OCR识别中..."];
    Class visionOCR = NSClassFromString(@"VisionOCR");
    if (!visionOCR) { [Common toast:@"OCR模块未加载"]; return; }
    
    // 运行时调用 VisionOCR
    SEL sel = @selector(recognizeImage:languages:completion:);
    if ([visionOCR respondsToSelector:sel]) {
        void (*func)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)) = (void(*)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)))[visionOCR methodForSelector:sel];
        func(visionOCR, sel, image, [Common ocrLanguages], ^(NSString *text) {
            if (text.length) {
                [UIPasteboard generalPasteboard].string = text;
                [Common toast:[NSString stringWithFormat:@"OCR完成，已复制到剪贴板\n%@", [text substringToIndex:MIN(50, text.length)]]];
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
        [Common toast:@"请先在设置中配置百度翻译 AppID 和密钥"];
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
                [Common toast:[NSString stringWithFormat:@"翻译完成：%@", [translated substringToIndex:MIN(40, translated.length)]]];
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
        [Common toast:@"请先在设置中配置 AI 接口地址和密钥"];
        return;
    }
    
    [Common toast:@"正在询问AI..."];
    Class aiEngine = NSClassFromString(@"AskAIEngine");
    if (!aiEngine) { [Common toast:@"AI模块未加载"]; return; }
    
    SEL sel = @selector(askText:baseURL:apiKey:model:completion:);
    void (*func)(id, SEL, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)) = (void(*)(id, SEL, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)))[aiEngine methodForSelector:sel];
    func(aiEngine, sel, prompt, baseURL, apiKey, model, ^(NSString *answer, NSString *error) {
        if (answer.length) {
            [UIPasteboard generalPasteboard].string = answer;
            [Common toast:[NSString stringWithFormat:@"AI回复：%@", [answer substringToIndex:MIN(40, answer.length)]]];
        } else {
            [Common toast:error ?: @"AI请求失败"];
        }
    });
}

+ (void)doLongShot {
    [Common toast:@"正在滚动截图..."];
    Class longShot = NSClassFromString(@"LongShotController");
    if (!longShot) { [Common toast:@"长截图模块未加载"]; return; }
    
    SEL sel = @selector(captureFromKeyWindowCompletion:);
    void (*func)(id, SEL, void(^)(UIImage*)) = (void(*)(id, SEL, void(^)(UIImage*)))[longShot methodForSelector:sel];
    func(longShot, sel, ^(UIImage *stitched) {
        if (stitched) {
            _currentImage = stitched;
            [Common toast:@"长截图完成，可继续操作"];
            [self showWithImage:stitched];
        } else {
            [Common toast:@"长截图失败，未找到可滚动区域"];
        }
    });
}

+ (void)doCrop:(UIImage *)image {
    UIWindow *cropWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    cropWin.windowLevel = UIWindowLevelAlert + 200;
    cropWin.backgroundColor = [UIColor blackColor];
    if (@available(iOS 13.0, *)) cropWin.windowScene = [Common activeWindowScene];
    
    CGFloat ratio = image.size.width / image.size.height;
    CGFloat ivW = cropWin.bounds.size.width;
    CGFloat ivH = ivW / ratio;
    if (ivH > cropWin.bounds.size.height - 120) {
        ivH = cropWin.bounds.size.height - 120;
        ivW = ivH * ratio;
    }
    CGFloat ivX = (cropWin.bounds.size.width - ivW) / 2;
    CGFloat ivY = (cropWin.bounds.size.height - 120 - ivH) / 2;
    
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(ivX, ivY, ivW, ivH)];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = YES;
    [cropWin addSubview:iv];
    
    UIView *cropBox = [[UIView alloc] initWithFrame:CGRectMake(ivW*0.1, ivH*0.1, ivW*0.8, ivH*0.8)];
    cropBox.layer.borderColor = [UIColor whiteColor].CGColor;
    cropBox.layer.borderWidth = 2;
    cropBox.layer.cornerRadius = 4;
    [iv addSubview:cropBox];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.frame = CGRectMake(cropWin.bounds.size.width/2 - 80, cropWin.bounds.size.height - 80, 160, 44);
    saveBtn.backgroundColor = [UIColor systemBlueColor];
    saveBtn.layer.cornerRadius = 22;
    [saveBtn setTitle:@"裁剪并继续" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [cropWin addSubview:saveBtn];
    
    [saveBtn addTarget:[self class] action:@selector(cropSaveTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(saveBtn, "cropIV", iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "cropBox", cropBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "cropImage", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "cropWindow", cropWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    cropWin.hidden = NO;
}

+ (void)cropSaveTapped:(UIButton *)btn {
    UIImageView *iv = objc_getAssociatedObject(btn, "cropIV");
    UIView *cropBox = objc_getAssociatedObject(btn, "cropBox");
    UIImage *image = objc_getAssociatedObject(btn, "cropImage");
    UIWindow *win = objc_getAssociatedObject(btn, "cropWindow");
    
    CGRect boxInIV = [iv convertRect:cropBox.frame toView:iv];
    CGFloat scaleX = image.size.width / iv.bounds.size.width;
    CGFloat scaleY = image.size.height / iv.bounds.size.height;
    CGRect cropRect = CGRectMake(boxInIV.origin.x * scaleX, boxInIV.origin.y * scaleY,
                                  boxInIV.size.width * scaleX, boxInIV.size.height * scaleY);
    
    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    UIImage *cropped = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    
    if (cropped) {
        _currentImage = cropped;
        [Common toast:@"裁剪完成"];
        [self showWithImage:cropped];
    }
    
    win.hidden = YES;
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
    if (_floatingWindow) {
        _floatingWindow.hidden = YES;
        _floatingWindow = nil;
    }
    
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
        [_floatingWindow resignKeyWindow];
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

#pragma mark - 辅助

+ (UIColor *)colorFromHex:(NSUInteger)hex {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

@end