//
//  SuperTools.m — 全部工具实现（v4.0 骨架）
//  OCR/识码/复制/贴图/保存/分享/PDF/压缩/去状态栏 完整；画图完整；
//  翻译（网络入口）/打码（智能脱敏）/取色器 骨架留 TODO。
//

#import "SuperTools.h"
#import "Common.h"
#import <Vision/Vision.h>
#import <PencilKit/PencilKit.h>
#import <PDFKit/PDFKit.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>

@implementation SuperTools

#pragma mark - 1. OCR（Vision 本地离线，KVC 动态调用避免依赖 SDK 头文件版本）

+ (void)ocr:(UIImage *)image completion:(void (^)(NSString *text))completion {
    if (!image.CGImage) { if (completion) completion(nil); return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *txt = [NSMutableString string];
        @try {
            Class reqCls = NSClassFromString(@"VNRecognizeTextRequest");
            Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
            if (reqCls && handlerCls) {
                id req = [[reqCls alloc] init];
                [req setValue:@1 forKey:@"recognitionLevel"];                 // VNRequestAccuracyHigh
                [req setValue:@[@"zh-Hans", @"zh-Hant", @"en-US"] forKey:@"recognitionLanguages"];
                id handler = [[handlerCls alloc] initWithCGImage:image.CGImage options:@{}];
                NSError *err = nil;
                [handler performRequests:@[req] error:&err];
                NSArray *results = [req valueForKey:@"results"];
                for (id obs in results) {
                    NSArray *cands = [obs valueForKey:@"topCandidates"];
                    NSString *s = [[cands firstObject] valueForKey:@"string"];
                    if (s.length) [txt appendFormat:@"%@\n", s];
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] OCR failed: %@ %@", e.name, e.reason);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(txt.length ? txt : nil);
        });
    });
}

#pragma mark - 2. 翻译（OCR + 网络翻译预留）

+ (void)translate:(UIImage *)image completion:(void (^)(NSString *dst, NSString *src))completion {
    [self ocr:image completion:^(NSString *text) {
        if (!text.length) { if (completion) completion(nil, nil); return; }
        // TODO: 接入翻译 API（百度/DeepL），当前返回原文占位
        if (completion) completion(text, text);
    }];
}

#pragma mark - 3. 画图（PencilKit）

+ (void)draw:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    if (!image) { if (completion) completion(nil); return; }
    if (@available(iOS 13.0, *)) {
        UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        win.windowLevel = UIWindowLevelAlert + 260;
        win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        win.userInteractionEnabled = YES;
        if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

        UIImageView *bg = [[UIImageView alloc] initWithFrame:win.bounds];
        bg.image = image;
        bg.contentMode = UIViewContentModeScaleAspectFit;
        bg.userInteractionEnabled = NO;
        [win addSubview:bg];

        PKCanvasView *canvas = [[PKCanvasView alloc] initWithFrame:win.bounds];
        canvas.backgroundColor = [UIColor clearColor];
        if (@available(iOS 14.0, *)) {
            canvas.drawingPolicy = PKCanvasViewDrawingPolicyAnyInput;
        }
        [win addSubview:canvas];

        // 完成 / 取消
        __block UIWindow *w = win;
        UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
        done.frame = CGRectMake(win.bounds.size.width - 90, 50, 70, 40);
        done.tag = 0;    // 完成
        [done setTitle:@"完成" forState:UIControlStateNormal];
        done.backgroundColor = UIColor.systemBlueColor;
        done.layer.cornerRadius = 20;
        [done setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [done addTarget:self action:@selector(drawDone:) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:done];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(20, 50, 70, 40);
        close.tag = 999; // 取消
        [close setTitle:@"取消" forState:UIControlStateNormal];
        close.backgroundColor = UIColor.systemGrayColor;
        close.layer.cornerRadius = 20;
        [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [close addTarget:self action:@selector(drawDone:) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:close];

        objc_setAssociatedObject(win, "drawCanvas", canvas, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(win, "drawImage", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(win, "drawCompletion", completion, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(win, "drawWindowRef", w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        win.hidden = NO;
        (void)w;
    } else {
        if (completion) completion(nil);
    }
}

+ (void)drawDone:(UIButton *)btn {
    UIWindow *win = objc_getAssociatedObject(btn.superview, "drawWindowRef");
    if (!win) win = btn.window;
    if (!win) return;
    PKCanvasView *canvas = objc_getAssociatedObject(win, "drawCanvas");
    UIImage *base = objc_getAssociatedObject(win, "drawImage");
    void (^comp)(UIImage *) = objc_getAssociatedObject(win, "drawCompletion");

    if (btn.tag == 999 || !canvas || !base) {   // 取消
        win.hidden = YES;
        if (comp) comp(nil);
        return;
    }
    if (@available(iOS 13.0, *)) {
        UIImage *drawing = [canvas.drawing imageFromRect:canvas.bounds scale:UIScreen.mainScreen.scale];
        UIGraphicsBeginImageContextWithOptions(base.size, NO, base.scale);
        [base drawAtPoint:CGPointZero];
        if (drawing) {
            CGFloat ratio = base.size.width / base.size.height;
            CGFloat w = win.bounds.size.width;
            CGFloat h = w / ratio;
            if (h > win.bounds.size.height) { h = win.bounds.size.height; w = h * ratio; }
            CGFloat x = (win.bounds.size.width - w) / 2;
            CGFloat y = (win.bounds.size.height - h) / 2;
            [drawing drawInRect:CGRectMake(x, y, w, h)];
        }
        UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        win.hidden = YES;
        if (comp) comp(result ?: base);
    }
}

#pragma mark - 4. 识码（Vision Barcode）

+ (void)codeScan:(UIImage *)image completion:(void (^)(NSString *code))completion {
    if (!image.CGImage) { if (completion) completion(nil); return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (@available(iOS 13.0, *)) {
            VNDetectBarcodesRequest *req = [[VNDetectBarcodesRequest alloc] init];
            VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
            NSError *err = nil;
            [h performRequests:@[req] error:&err];
            NSMutableString *txt = [NSMutableString string];
            for (VNBarcodeObservation *obs in req.results) {
                if (obs.payloadStringValue.length) [txt appendFormat:@"%@\n", obs.payloadStringValue];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(txt.length ? txt : nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
        }
    });
}

#pragma mark - 5. 打码（骨架）

+ (void)mosaic:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    // TODO(v4.1)：
    //  模式A 手动色块涂抹：遮罩层上手指涂抹 → 涂区域像素化。
    //  模式B 智能脱敏：Vision VNRecognizeTextRequest 得文字 bbox →
    //       匹配手机号/身份证正则 → 对应区域叠加色块。
    [Common toast:@"打码功能 v4.1 实现（当前占位）"];
    if (completion) completion(nil);
}

#pragma mark - 6. 复制

+ (void)copy:(UIImage *)image {
    UIPasteboard.generalPasteboard.image = image;
    [Common toast:@"已复制图片"];
}

#pragma mark - 7. 贴图（悬浮窗口）

static UIWindow *_floatWin;
+ (void)floating:(UIImage *)image {
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }
    CGFloat fw = 120, fh = 120 * image.size.height / image.size.width;
    if (fh > 200) { fh = 200; fw = 200 * image.size.width / image.size.height; }
    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(
        UIScreen.mainScreen.bounds.size.width - fw - 20,
        UIScreen.mainScreen.bounds.size.height / 2 - fh / 2, fw, fh)];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:win.bounds];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12;
    iv.clipsToBounds = YES;
    iv.layer.borderColor = UIColor.whiteColor.CGColor;
    iv.layer.borderWidth = 2;
    [win addSubview:iv];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(fw - 28, 0, 28, 28);
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = UIColor.redColor;
    [close addTarget:self action:@selector(closeFloat) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloat:)];
    [win addGestureRecognizer:pan];
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeFloat)];
    dt.numberOfTapsRequired = 2;
    [win addGestureRecognizer:dt];

    _floatWin = win;
    win.hidden = NO;
    [Common toast:@"已贴图：可拖动，双击或点 X 关闭"];
}

+ (void)closeFloat {
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }
}
+ (void)panFloat:(UIPanGestureRecognizer *)pan {
    if (!_floatWin) return;
    CGPoint t = [pan translationInView:_floatWin.superview];
    _floatWin.center = CGPointMake(_floatWin.center.x + t.x, _floatWin.center.y + t.y);
    [pan setTranslation:CGPointZero inView:_floatWin.superview];
}

#pragma mark - 8. 保存

+ (void)save:(UIImage *)image completion:(void (^)(BOOL ok))completion {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized) {
                if (completion) completion(NO);
                return;
            }
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            } completionHandler:^(BOOL ok, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(ok);
                });
            }];
        });
    }];
}

#pragma mark - 9. 分享

+ (void)share:(UIImage *)image fromWindow:(UIWindow *)win {
    UIActivityViewController *avc = [[UIActivityViewController alloc]
                                      initWithActivityItems:@[image] applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        avc.popoverPresentationController.sourceView = win;
        avc.popoverPresentationController.sourceRect = CGRectMake(win.bounds.size.width/2, win.bounds.size.height/2, 0, 0);
    }
    UIWindow *keyWin = win ?: [Common topWindow];
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (root) [root presentViewController:avc animated:YES completion:nil];
}

#pragma mark - 10a. 导出 PDF

+ (NSString *)exportPDF:(UIImage *)image {
    if (!image) return nil;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"supershot.pdf"];
    CGRect page = CGRectMake(0, 0, image.size.width, image.size.height);
    UIGraphicsBeginPDFContextToFile(path, page, nil);
    UIGraphicsBeginPDFPageWithInfo(page, nil);
    [image drawInRect:page];
    UIGraphicsEndPDFContext();
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

#pragma mark - 10b. 压缩

+ (UIImage *)compress:(UIImage *)image quality:(CGFloat)quality {
    NSData *data = UIImageJPEGRepresentation(image, quality);
    return data ? [UIImage imageWithData:data] : nil;
}

#pragma mark - 10c. 去状态栏（裁剪顶部）

+ (UIImage *)stripStatusBar:(UIImage *)image {
    if (!image.CGImage) return nil;
    CGFloat statusH = 44.0;                    // 状态栏高度（pt）
    CGFloat scale = image.size.width / UIScreen.mainScreen.bounds.size.width;
    CGRect crop = CGRectMake(0, statusH * scale, image.size.width,
                             image.size.height - statusH * scale);
    crop = CGRectIntersection(crop, CGRectMake(0, 0, image.size.width, image.size.height));
    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, crop);
    UIImage *out = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return out;
}

#pragma mark - 10d. 取色器（骨架）

+ (void)colorPicker:(UIImage *)image {
    // TODO(v4.1)：弹放大镜取色 UI，读像素色值并显示/复制 HEX
    [Common toast:@"取色器 v4.1 实现（当前占位）"];
}

@end
