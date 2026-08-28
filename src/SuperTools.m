//
//  SuperTools.m — 窗口B 全部按钮的底层实现（超级截图 v4.1）
//
//  只使用 iOS 16 系统自带框架：Vision / PencilKit / PDFKit / Photos / CoreGraphics / UIKit
//
//  v4.1 补全：
//   · 打码：从 v4.0 的占位 toast 升级为完整实现
//       模式A 手动涂抹：手指在图上画，画过的区域像素化（马赛克）
//       模式B 智能脱敏：Vision OCR 取文字坐标 → 正则匹配手机号/身份证/银行卡/邮箱
//                       → 命中区域自动叠加色块
//   · 取色器：从占位升级为完整实现（点图取像素色值，显示 HEX，可复制）
//   · 翻译：从「返回原文占位」升级为真实网络翻译调用（免费 gtx 接口，可换 API）
//   · OCR 重构为「逐行带坐标」的底层方法，翻译/智能脱敏共用
//
//  ⚠️ Vision 相关全部走 NSClassFromString + KVC，原因：CI 用的 theos SDK 是
//     iPhoneOS14.5，iOS 13+ 才有的 Vision 符号在头文件里并不齐全，直接引用会编译失败。
//

#import "SuperTools.h"
#import "Common.h"
#import "ImageUtils.h"
#import <Vision/Vision.h>
#import <PencilKit/PencilKit.h>
#import <PDFKit/PDFKit.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>

#pragma mark - 私有类 / 私有方法前置声明

@class XZPaintView;
@class XZMosaicEditor;
@class XZColorPicker;

// 本文件内部使用的私有方法（打码编辑器 / 取色器窗口会回调进来）
@interface SuperTools (Private)
+ (void)ocrObservations:(UIImage *)image
             completion:(void (^)(NSArray<NSDictionary *> *items))completion;
+ (void)detectSensitiveRects:(UIImage *)image
                  completion:(void (^)(NSArray<NSValue *> *rects))completion;
+ (void)translateText:(NSString *)text completion:(void (^)(NSString *dst))completion;
+ (UIImage *)pixelatedImage:(UIImage *)src ratio:(CGFloat)ratio;
+ (UIImage *)applyMask:(CGImageRef)maskCG toPixelated:(UIImage *)pixelated onImage:(UIImage *)orig;
+ (CGImageRef)createMaskWithSize:(CGSize)pxSize
                           rects:(NSArray<NSValue *> *)rects
                           paths:(NSArray<UIBezierPath *> *)paths
                      pathWidths:(NSArray<NSNumber *> *)widths;
@end

@interface XZMosaicEditor : NSObject
+ (void)edit:(UIImage *)image completion:(void (^)(UIImage *edited))completion;
@end

@interface XZColorPicker : NSObject
+ (void)show:(UIImage *)image;
@end

#pragma mark - 小工具

// 等比居中：算出 content 放进 bounds 后的实际显示区域（aspectFit）
static CGRect XZFitRect(CGSize content, CGRect bounds) {
    if (content.width <= 0 || content.height <= 0) return bounds;
    CGFloat s = MIN(bounds.size.width / content.width, bounds.size.height / content.height);
    CGSize out = CGSizeMake(content.width * s, content.height * s);
    return CGRectMake(bounds.origin.x + (bounds.size.width - out.width) / 2.0,
                      bounds.origin.y + (bounds.size.height - out.height) / 2.0,
                      out.width, out.height);
}

// 从 NSValue 里安全取 CGRect
static CGRect XZRectFromValue(id v) {
    if ([v isKindOfClass:[NSValue class]]) {
        return [(NSValue *)v CGRectValue];
    }
    return CGRectZero;
}

@implementation SuperTools

#pragma mark - 1. OCR（底层：逐行 + 坐标）

// 返回 items: @[ @{@"text":NSString, @"box":NSValue(CGRect 像素坐标)} ]
+ (void)ocrObservations:(UIImage *)image
             completion:(void (^)(NSArray<NSDictionary *> *items))completion {
    if (!image.CGImage) { if (completion) completion(nil); return; }
    CGFloat pxW = (CGFloat)CGImageGetWidth(image.CGImage);
    CGFloat pxH = (CGFloat)CGImageGetHeight(image.CGImage);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        @try {
            // 显式强引用：block 捕获 CGImageRef 不会自动 retain 宿主 UIImage，
            // 不写这行 image 可能在后台线程执行前就被释放，CGImageRef 变悬垂指针
            UIImage *img = image;
            CGImageRef cg = img.CGImage;
            if (!cg) {
                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
                return;
            }

            Class reqCls = NSClassFromString(@"VNRecognizeTextRequest");
            Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
            if (reqCls && handlerCls) {
                id req = [[reqCls alloc] init];
                @try {
                    [req setValue:@(1) forKey:@"recognitionLevel"];                 // VNRequestTextRecognitionLevelAccurate
                    [req setValue:@(YES) forKey:@"usesLanguageCorrection"];
                    [req setValue:[Common ocrLanguages] forKey:@"recognitionLanguages"];
                } @catch (NSException *e) { /* 老系统不支持的键忽略 */ }

                id handler = [[handlerCls alloc] init];
                SEL hSel = NSSelectorFromString(@"initWithCGImage:options:");
                if ([handler respondsToSelector:hSel]) {
                    handler = ((id (*)(id, SEL, CGImageRef, NSDictionary *))objc_msgSend)(handler, hSel, cg, @{});
                } else {
                    handler = nil;
                }
                if (handler) {
                    NSError *err = nil;
                    SEL pSel = NSSelectorFromString(@"performRequests:error:");
                    ((BOOL (*)(id, SEL, NSArray *, NSError **))objc_msgSend)(
                        handler, pSel, [NSArray arrayWithObject:req], &err);

                    NSArray *results = nil;
                    @try { results = [req valueForKey:@"results"]; } @catch (NSException *e) { results = nil; }

                    for (id obs in results) {
                        NSString *line = nil;
                        @try {
                            NSArray *cands = [obs valueForKey:@"topCandidates"];
                            // topCandidates 是方法，KVC 取不到；用 msgSend 取前 1 个
                            if (![cands isKindOfClass:[NSArray class]] || cands.count == 0) {
                                SEL tc = NSSelectorFromString(@"topCandidates:");
                                if ([obs respondsToSelector:tc]) {
                                    cands = ((NSArray *(*)(id, SEL, NSUInteger))objc_msgSend)(obs, tc, 1);
                                }
                            }
                            id cand = [cands isKindOfClass:[NSArray class]] ? cands.firstObject : nil;
                            if (cand) {
                                id s = [cand valueForKey:@"string"];
                                if ([s isKindOfClass:[NSString class]]) line = (NSString *)s;
                            }
                        } @catch (NSException *e) { line = nil; }

                        CGRect box = CGRectZero;
                        @try {
                            id bv = [obs valueForKey:@"boundingBox"];
                            if ([bv isKindOfClass:[NSValue class]]) {
                                CGRect n = [(NSValue *)bv CGRectValue];   // 归一化，原点左下
                                box = CGRectMake(n.origin.x * pxW,
                                                 (1.0 - n.origin.y - n.size.height) * pxH,
                                                 n.size.width * pxW,
                                                 n.size.height * pxH);
                            }
                        } @catch (NSException *e) { box = CGRectZero; }

                        if (line.length) {
                            [items addObject:@{@"text": line, @"box": [NSValue valueWithCGRect:box]}];
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] OCR exception: %@ %@", e.name, e.reason);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(items);
        });
    });
}

+ (void)ocr:(UIImage *)image completion:(void (^)(NSString *text))completion {
    [self ocrObservations:image completion:^(NSArray<NSDictionary *> *items) {
        NSMutableString *m = [NSMutableString string];
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            if (t.length) [m appendFormat:@"%@\n", t];
        }
        if (completion) completion(m.length ? m : nil);
    }];
}

+ (void)ocr:(UIImage *)image withBoxes:(void (^)(NSString *text, NSArray<NSValue *> *boxes))completion {
    [self ocrObservations:image completion:^(NSArray<NSDictionary *> *items) {
        NSMutableString *m = [NSMutableString string];
        NSMutableArray<NSValue *> *boxes = [NSMutableArray array];
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            if (t.length) [m appendFormat:@"%@\n", t];
            NSValue *b = it[@"box"];
            if (b) [boxes addObject:b];
        }
        if (completion) completion(m.length ? m : nil, boxes);
    }];
}

#pragma mark - 2. 翻译（OCR 取文 → 网络翻译）

+ (void)translate:(UIImage *)image completion:(void (^)(NSString *src, NSString *dst))completion {
    [self ocr:image completion:^(NSString *text) {
        if (!text.length) { if (completion) completion(nil, nil); return; }
        [self translateText:text completion:^(NSString *dst) {
            if (completion) completion(text, dst);
        }];
    }];
}

// 网络翻译入口。当前用免费 gtx 接口（无需 key）。
// 想换成百度/DeepL：把这里换成自己的签名请求即可，调用方无需改动。
+ (void)translateText:(NSString *)text completion:(void (^)(NSString *dst))completion {
    NSString *tl = [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh-CN"];
    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:
                   [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *us = [NSString stringWithFormat:
                    @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%@&dt=t&q=%@",
                    tl, q ?: @""];
    NSURL *url = [NSURL URLWithString:us];
    if (!url) { if (completion) completion(nil); return; }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *out = nil;
        @try {
            if (!err && data) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                // 结构: [ [ ["译文","原文",null,null,10], ... ], ... ]
                if ([json isKindOfClass:[NSArray class]] && [json count] > 0) {
                    id segs = json[0];
                    if ([segs isKindOfClass:[NSArray class]]) {
                        NSMutableString *m = [NSMutableString string];
                        for (id seg in segs) {
                            if ([seg isKindOfClass:[NSArray class]] && [seg count] > 0) {
                                id s0 = seg[0];
                                if ([s0 isKindOfClass:[NSString class]]) [m appendString:(NSString *)s0];
                            }
                        }
                        out = m.length ? m : nil;
                    }
                }
            } else {
                NSLog(@"[SN3] translate request failed: %@", err);
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] translate parse exception: %@", e);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out); });
    }];
    [task resume];
}

#pragma mark - 3. 画图（PencilKit）

// 动态构造 PKInkingTool：不同 iOS/SDK 版本选择器不一样，逐个探测
static id XZMakeInkTool(NSInteger inkType, UIColor *color, CGFloat width) {
    Class cls = NSClassFromString(@"PKInkingTool");
    if (!cls) return nil;
    id tool = [cls alloc];

    SEL s3 = NSSelectorFromString(@"initWithInkType:color:width:");
    if ([tool respondsToSelector:s3]) {
        return ((id (*)(id, SEL, NSInteger, UIColor *, CGFloat))objc_msgSend)(tool, s3, inkType, color, width);
    }
    SEL s2 = NSSelectorFromString(@"initWithInkType:color:");
    if ([tool respondsToSelector:s2]) {
        return ((id (*)(id, SEL, NSInteger, UIColor *))objc_msgSend)(tool, s2, inkType, color);
    }
    return nil;
}

static id XZMakeEraserTool(void) {
    Class cls = NSClassFromString(@"PKEraserTool");
    if (!cls) return nil;
    id tool = [cls alloc];
    SEL s = NSSelectorFromString(@"initWithEraserType:");
    if ([tool respondsToSelector:s]) {
        return ((id (*)(id, SEL, NSInteger))objc_msgSend)(tool, s, 0);
    }
    return [[cls alloc] init];
}

+ (void)draw:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    if (!image) { if (completion) completion(nil); return; }
    if (@available(iOS 13.0, *)) {
        CGRect scr = [UIScreen mainScreen].bounds;

        UIWindow *win = [[UIWindow alloc] initWithFrame:scr];
        win.windowLevel = UIWindowLevelAlert + 260;
        win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

        CGRect fit = XZFitRect(image.size, CGRectInset(scr, 4, 60));

        UIImageView *bg = [[UIImageView alloc] initWithFrame:fit];
        bg.image = image;
        bg.contentMode = UIViewContentModeScaleToFill;
        bg.userInteractionEnabled = NO;
        [win addSubview:bg];

        PKCanvasView *canvas = [[PKCanvasView alloc] initWithFrame:fit];
        canvas.backgroundColor = [UIColor clearColor];
        canvas.opaque = NO;
        if (@available(iOS 14.0, *)) {
            canvas.drawingPolicy = PKCanvasViewDrawingPolicyAnyInput;
        }
        [win addSubview:canvas];

        // 工具条：画笔 / 马克笔 / 橡皮 / 颜色切换 / 完成 / 取消
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - 108, scr.size.width, 108)];
        bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [win addSubview:bar];

        __block UIColor *inkColor = [UIColor redColor];
        __block CGFloat inkWidth  = 4.0;

        UIButton * (^mk)(NSString *, CGRect, NSInteger) = ^UIButton *(NSString *t, CGRect f, NSInteger tag) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = f; b.tag = tag;
            b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
            b.layer.cornerRadius = 8;
            [b setTitle:t forState:UIControlStateNormal];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            [b addTarget:self action:@selector(drawToolTapped:) forControlEvents:UIControlEventTouchUpInside];
            [bar addSubview:b];
            return b;
        };

        CGFloat bw = (scr.size.width - 40 - 10 * 3) / 4.0;
        mk(@"画笔",  CGRectMake(20, 10, bw, 40), 1);
        mk(@"马克笔", CGRectMake(30 + bw, 10, bw, 40), 2);
        mk(@"橡皮",  CGRectMake(40 + bw * 2, 10, bw, 40), 3);
        mk(@"换色",  CGRectMake(50 + bw * 3, 10, bw, 40), 4);
        mk(@"取消",  CGRectMake(20, 58, (scr.size.width - 50) / 2.0, 40), 998);
        mk(@"完成",  CGRectMake(30 + (scr.size.width - 50) / 2.0, 58, (scr.size.width - 50) / 2.0, 40), 999);

        objc_setAssociatedObject(win, "xz_draw_canvas", canvas, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(win, "xz_draw_image", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(win, "xz_draw_completion", completion, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(win, "xz_draw_color", inkColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(win, "xz_draw_width", @(inkWidth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        win.hidden = NO;

        // 默认给一支笔（PKInkingTool 不可用时用系统默认工具，依然能画）
        id tool = XZMakeInkTool(0, inkColor, inkWidth);
        if (tool) canvas.tool = tool;
    } else {
        if (completion) completion(nil);
    }
}

+ (void)drawToolTapped:(UIButton *)btn {
    UIWindow *win = btn.window;
    if (!win) return;
    PKCanvasView *canvas = objc_getAssociatedObject(win, "xz_draw_canvas");
    UIImage *base = objc_getAssociatedObject(win, "xz_draw_image");
    void (^comp)(UIImage *) = objc_getAssociatedObject(win, "xz_draw_completion");
    UIColor *color = objc_getAssociatedObject(win, "xz_draw_color") ?: [UIColor redColor];
    CGFloat width = [objc_getAssociatedObject(win, "xz_draw_width") doubleValue];
    if (width <= 0) width = 4.0;

    NSInteger tag = btn.tag;

    if (tag == 998) {              // 取消
        win.hidden = YES;
        if (comp) comp(nil);
        return;
    }
    if (tag == 999) {              // 完成：把画布内容合成回原图
        if (@available(iOS 13.0, *)) {
            UIImage *result = base;
            if (canvas && base) {
                UIImage *drawing = nil;
                @try {
                    SEL imgSel = NSSelectorFromString(@"imageFromRect:scale:");
                    if ([canvas.drawing respondsToSelector:imgSel]) {
                        drawing = ((UIImage *(*)(id, SEL, CGRect, CGFloat))objc_msgSend)(
                            canvas.drawing, imgSel, canvas.bounds, [UIScreen mainScreen].scale);
                    }
                } @catch (NSException *e) { drawing = nil; }

                UIGraphicsBeginImageContextWithOptions(base.size, NO, base.scale);
                [base drawAtPoint:CGPointZero];
                if (drawing) [drawing drawInRect:CGRectMake(0, 0, base.size.width, base.size.height)];
                UIImage *merged = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                if (merged) result = merged;
            }
            win.hidden = YES;
            if (comp) comp(result);
        }
        return;
    }

    // 切工具
    id tool = nil;
    if (tag == 1) {
        tool = XZMakeInkTool(0, color, width);          // pen
    } else if (tag == 2) {
        tool = XZMakeInkTool(2, [color colorWithAlphaComponent:0.4], width * 4);  // marker
    } else if (tag == 3) {
        tool = XZMakeEraserTool();
    } else if (tag == 4) {
        static NSInteger cIdx = 0;
        NSArray *palette = @[[UIColor redColor], [UIColor yellowColor], [UIColor greenColor],
                             [UIColor blueColor], [UIColor blackColor], [UIColor whiteColor]];
        cIdx = (cIdx + 1) % (NSInteger)palette.count;
        color = palette[cIdx];
        objc_setAssociatedObject(win, "xz_draw_color", color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tool = XZMakeInkTool(0, color, width);
    }
    if (tool && canvas) canvas.tool = tool;
}

#pragma mark - 4. 识码（Vision Barcode）

+ (void)codeScan:(UIImage *)image completion:(void (^)(NSString *code))completion {
    if (!image.CGImage) { if (completion) completion(nil); return; }
    CGImageRef cg = image.CGImage;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *txt = [NSMutableString string];
        @try {
            Class reqCls = NSClassFromString(@"VNDetectBarcodesRequest");
            Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
            if (reqCls && handlerCls) {
                id req = [[reqCls alloc] init];
                id handler = [[handlerCls alloc] init];
                SEL hSel = NSSelectorFromString(@"initWithCGImage:options:");
                if ([handler respondsToSelector:hSel]) {
                    handler = ((id (*)(id, SEL, CGImageRef, NSDictionary *))objc_msgSend)(handler, hSel, cg, @{});
                    NSError *err = nil;
                    SEL pSel = NSSelectorFromString(@"performRequests:error:");
                    ((BOOL (*)(id, SEL, NSArray *, NSError **))objc_msgSend)(
                        handler, pSel, [NSArray arrayWithObject:req], &err);

                    NSArray *results = nil;
                    @try { results = [req valueForKey:@"results"]; } @catch (NSException *e) { results = nil; }
                    for (id obs in results) {
                        NSString *s = nil;
                        @try {
                            id v = [obs valueForKey:@"payloadStringValue"];
                            if ([v isKindOfClass:[NSString class]]) s = (NSString *)v;
                        } @catch (NSException *e) { s = nil; }
                        if (s.length) [txt appendFormat:@"%@\n", s];
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] barcode exception: %@", e);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(txt.length ? txt : nil);
        });
    });
}

#pragma mark - 5. 打码（马赛克）

+ (void)mosaic:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    if (!image) { if (completion) completion(nil); return; }
    [XZMosaicEditor edit:image completion:completion];
}

// 像素化：先缩到 1/ratio 再放大回去（最近邻 → 马赛克）
+ (UIImage *)pixelatedImage:(UIImage *)src ratio:(CGFloat)ratio {
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    CGFloat pxW = (CGFloat)CGImageGetWidth(cg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cg);
    if (pxW < 4 || pxH < 4) return nil;

    CGFloat smallW = MAX(2, pxW / ratio);
    CGFloat smallH = MAX(2, pxH / ratio);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef smallCtx = CGBitmapContextCreate(NULL, (size_t)smallW, (size_t)smallH, 8, 0, cs,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!smallCtx) return nil;
    CGContextSetInterpolationQuality(smallCtx, kCGInterpolationNone);
    CGContextDrawImage(smallCtx, CGRectMake(0, 0, smallW, smallH), cg);
    CGImageRef smallCG = CGBitmapContextCreateImage(smallCtx);
    CGContextRelease(smallCtx);
    if (!smallCG) return nil;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(pxW, pxH), NO, 1.0);
    CGContextRef bigCtx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(bigCtx, kCGInterpolationNone);
    if (bigCtx) CGContextDrawImage(bigCtx, CGRectMake(0, 0, pxW, pxH), smallCG);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(smallCG);
    return out;
}

// 把 orig 与 pixelated 按 mask（DeviceGray，白=打码区）合成
+ (UIImage *)applyMask:(CGImageRef)maskCG
          toPixelated:(UIImage *)pixelated
              onImage:(UIImage *)orig {
    CGImageRef px = pixelated.CGImage;
    if (!px || !maskCG) return nil;
    CGImageRef masked = CGImageCreateWithMask(px, maskCG);
    if (!masked) return nil;

    CGSize size = orig.size;
    UIGraphicsBeginImageContextWithOptions(size, NO, orig.scale > 0 ? orig.scale : 1.0);
    [orig drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *layer = [UIImage imageWithCGImage:masked
                                         scale:(orig.scale > 0 ? orig.scale : 1.0)
                                   orientation:UIImageOrientationUp];
    [layer drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(masked);
    return out;
}

// 用一组「像素坐标矩形 + 一组像素坐标路径」生成 DeviceGray 掩码
+ (CGImageRef)createMaskWithSize:(CGSize)pxSize
                          rects:(NSArray<NSValue *> *)rects
                          paths:(NSArray<UIBezierPath *> *)paths
                     pathWidths:(NSArray<NSNumber *> *)widths {
    size_t W = (size_t)MAX(2, pxSize.width);
    size_t H = (size_t)MAX(2, pxSize.height);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    if (!cs) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    UIGraphicsPushContext(ctx);
    // 转成 UIKit 坐标系（左上原点），这样下面的 UIKit 绘制才不会上下颠倒
    CGContextTranslateCTM(ctx, 0, (CGFloat)H);
    CGContextScaleCTM(ctx, 1, -1);

    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, (CGFloat)W, (CGFloat)H));

    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    for (NSValue *v in rects) {
        CGRect r = [v CGRectValue];
        if (r.size.width > 0 && r.size.height > 0) UIRectFill(r);
    }
    for (NSUInteger i = 0; i < paths.count; i++) {
        UIBezierPath *p = paths[i];
        CGFloat w = (i < widths.count) ? [widths[i] doubleValue] : 20.0;
        p.lineWidth = MAX(1.0, w);
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [p stroke];
    }
    UIGraphicsPopContext();

    CGImageRef mask = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return mask;
}

// 智能脱敏：OCR 出文字坐标，正则命中就返回对应区域（像素坐标）
+ (void)detectSensitiveRects:(UIImage *)image completion:(void (^)(NSArray<NSValue *> *rects))completion {
    [self ocrObservations:image completion:^(NSArray<NSDictionary *> *items) {
        NSMutableArray<NSValue *> *out = [NSMutableArray array];
        NSArray *patterns = @[
            @"1[3-9]\\d{9}",                                        // 手机号
            @"\\d{17}[0-9Xx]",                                      // 身份证 18 位
            @"\\d{15}",                                             // 身份证 15 位
            @"\\d{16,19}",                                          // 银行卡
            @"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",     // 邮箱
        ];
        for (NSDictionary *it in items) {
            NSString *t = it[@"text"];
            CGRect box = XZRectFromValue(it[@"box"]);
            if (!t.length || box.size.width <= 0) continue;
            for (NSString *pat in patterns) {
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat
                                                                                   options:0 error:nil];
                if (!re) continue;
                NSRange r = [re rangeOfFirstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
                if (r.location != NSNotFound) {
                    // 命中就整行打码，并向外扩一点避免露出边缘笔画
                    CGRect padded = CGRectInset(box, -box.size.height * 0.15, -box.size.height * 0.15);
                    [out addObject:[NSValue valueWithCGRect:padded]];
                    break;
                }
            }
        }
        if (completion) completion(out);
    }];
}

#pragma mark - 6. 复制

+ (void)copy:(UIImage *)image {
    if (!image) return;
    [UIPasteboard generalPasteboard].image = image;
    [Common toast:@"已复制图片到剪贴板"];
}

#pragma mark - 7. 贴图（悬浮窗口）

static UIWindow *_floatWin = nil;

+ (void)floating:(UIImage *)image {
    if (!image) return;
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }

    CGFloat fw = 120.0;
    CGFloat fh = 120.0 * image.size.height / MAX(1, image.size.width);
    if (fh > 200) { fh = 200; fw = 200 * image.size.width / MAX(1, image.size.height); }
    CGRect scr = [UIScreen mainScreen].bounds;

    UIWindow *win = [[UIWindow alloc] initWithFrame:
                     CGRectMake(scr.size.width - fw - 20,
                                scr.size.height / 2 - fh / 2, fw, fh)];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.backgroundColor = [UIColor clearColor];
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:win.bounds];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12;
    iv.clipsToBounds = YES;
    iv.layer.borderColor = [UIColor whiteColor].CGColor;
    iv.layer.borderWidth = 2;
    [win addSubview:iv];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(fw - 28, 0, 28, 28);
    [close setImage:[Common systemIcon:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor redColor];
    [close addTarget:self action:@selector(closeFloat) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloat:)];
    [win addGestureRecognizer:pan];
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeFloatByGesture:)];
    dt.numberOfTapsRequired = 2;
    [win addGestureRecognizer:dt];

    _floatWin = win;
    win.hidden = NO;
    [Common toast:@"已贴图：可拖动，双击或点 X 关闭"];
}

+ (void)closeFloat {
    if (_floatWin) { _floatWin.hidden = YES; _floatWin = nil; }
}
+ (void)closeFloatByGesture:(UITapGestureRecognizer *)g {
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
    if (!image) { if (completion) completion(NO); return; }
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized &&
                status != PHAuthorizationStatusLimited) {
                if (completion) completion(NO);
                return;
            }
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            } completionHandler:^(BOOL ok, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) NSLog(@"[SN3] save failed: %@", error);
                    if (completion) completion(ok);
                });
            }];
        });
    }];
}

#pragma mark - 9. 分享

+ (void)share:(UIImage *)image fromWindow:(UIWindow *)win {
    if (!image) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[image]
                                                                     applicationActivities:nil];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad && win) {
        avc.popoverPresentationController.sourceView = win;
        avc.popoverPresentationController.sourceRect = CGRectMake(win.bounds.size.width / 2,
                                                                  win.bounds.size.height / 2, 0, 0);
    }
    [Common present:avc fromWindow:win];
}

#pragma mark - 10a. 导出 PDF

+ (NSString *)exportPDF:(UIImage *)image {
    if (!image) return nil;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"supershot.pdf"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    CGRect page = CGRectMake(0, 0, image.size.width, image.size.height);
    UIGraphicsBeginPDFContextToFile(path, page, nil);
    UIGraphicsBeginPDFPageWithInfo(page, nil);
    [image drawInRect:page];
    UIGraphicsEndPDFContext();
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

#pragma mark - 10b. 压缩（CGImageDestination 改 JPEG 质量）

+ (UIImage *)compress:(UIImage *)image quality:(CGFloat)quality {
    if (!image.CGImage) return nil;
    CGFloat q = MAX(0.05, MIN(1.0, quality));

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    if (!dest) {
        NSData *d = UIImageJPEGRepresentation(image, q);
        return d ? [UIImage imageWithData:d] : nil;
    }
    NSDictionary *props = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(q)};
    CGImageDestinationAddImage(dest, image.CGImage, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return (ok && data.length) ? [UIImage imageWithData:data] : nil;
}

#pragma mark - 10c. 去状态栏

+ (UIImage *)stripStatusBar:(UIImage *)image {
    if (!image.CGImage) return nil;

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) return nil;
    // 图片自身坐标系里，1pt 对应多少单位
    CGFloat ratio = image.size.width / screenW;
    CGFloat statusH = [Common screenSafeInsets].top;
    if (statusH <= 0) statusH = 20.0;

    CGFloat cut = statusH * ratio;
    if (cut >= image.size.height * 0.5) return nil;   // 保护：别把整张图切没了

    CGRect r = CGRectMake(0, cut, image.size.width, image.size.height - cut);
    r = CGRectIntersection(r, CGRectMake(0, 0, image.size.width, image.size.height));
    if (CGRectIsNull(r) || r.size.height < 2) return nil;

    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, r);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return out;
}

#pragma mark - 10d. 取色器

+ (void)colorPicker:(UIImage *)image fromWindow:(UIWindow *)win {
    if (!image) return;
    [XZColorPicker show:image];
}

@end

#pragma mark - 涂鸦视图（打码用）

@interface XZPaintView : UIView
@property (nonatomic, strong) NSMutableArray<UIBezierPath *> *paths;
@property (nonatomic, assign) CGFloat strokeWidth;
@end

@implementation XZPaintView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _paths = [NSMutableArray array];
        _strokeWidth = 24.0;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = _strokeWidth;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path moveToPoint:p];
    [_paths addObject:path];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    [_paths.lastObject addLineToPoint:p];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self setNeedsDisplay];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
    for (UIBezierPath *p in _paths) {
        p.lineWidth = _strokeWidth;
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [p stroke];
    }
}

@end

#pragma mark - 打码编辑器（窗口）

@implementation XZMosaicEditor {
    UIWindow *_win;
    XZPaintView *_paintView;
    UIImage *_source;
    NSMutableArray<NSValue *> *_smartRects;
    UILabel *_tipLabel;
    void (^_completion)(UIImage *);
}

+ (void)edit:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    XZMosaicEditor *editor = [[XZMosaicEditor alloc] init];
    [editor buildWithImage:image completion:completion];
}

- (void)buildWithImage:(UIImage *)image completion:(void (^)(UIImage *edited))completion {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 240;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];
    _source = image;
    _completion = completion;

    CGRect fit = XZFitRect(image.size, CGRectMake(8, safe.top + 52, scr.size.width - 16,
                                                  scr.size.height - safe.top - safe.bottom - 190));

    UIImageView *iv = [[UIImageView alloc] initWithFrame:fit];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleToFill;
    iv.layer.borderWidth = 1;
    iv.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    [_win addSubview:iv];

    _paintView = [[XZPaintView alloc] initWithFrame:fit];
    [_win addSubview:_paintView];

    // 智能脱敏命中的区域（像素坐标）
    _smartRects = [NSMutableArray array];

    // ---- 按钮区 ----
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - 130,
                                                           scr.size.width, 130)];
    bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [_win addSubview:bar];

    CGFloat bw = (scr.size.width - 50) / 2.0;

    UIButton *smart = [self mkBtn:@"智能脱敏" frame:CGRectMake(20, 10, bw, 40) sel:@selector(onSmart)
                            color:[UIColor systemPurpleColor]];
    [bar addSubview:smart];

    UIButton *undo = [self mkBtn:@"撤销一笔" frame:CGRectMake(30 + bw, 10, bw, 40) sel:@selector(onUndo)
                           color:[UIColor systemGrayColor]];
    [bar addSubview:undo];

    UIButton *cancel = [self mkBtn:@"取消" frame:CGRectMake(20, 60, bw, 44) sel:@selector(onCancel)
                             color:[UIColor systemGrayColor]];
    [bar addSubview:cancel];

    UIButton *done = [self mkBtn:@"完成打码" frame:CGRectMake(30 + bw, 60, bw, 44) sel:@selector(onDone)
                           color:[UIColor systemBlueColor]];
    [bar addSubview:done];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, safe.top + 12, scr.size.width - 40, 30)];
    tip.text = @"手指涂抹要打码的位置，或点「智能脱敏」自动识别手机号/身份证";
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    tip.font = [UIFont systemFontOfSize:12];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.numberOfLines = 2;
    [_win addSubview:tip];
    _tipLabel = tip;

    _win.hidden = NO;
    objc_setAssociatedObject(_win, "xz_mosaic_editor", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIButton *)mkBtn:(NSString *)title frame:(CGRect)f sel:(SEL)sel color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = color;
    b.layer.cornerRadius = 8;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// 智能脱敏：OCR → 正则 → 命中框
- (void)onSmart {
    _tipLabel.text = @"正在识别敏感信息...";
    __weak typeof(self) ws = self;
    [SuperTools detectSensitiveRects:_source completion:^(NSArray<NSValue *> *rects) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        if (rects.count == 0) {
            ss->_tipLabel.text = @"没有识别到手机号/身份证等敏感信息，可手动涂抹";
            return;
        }
        [ss->_smartRects addObjectsFromArray:rects];
        ss->_tipLabel.text = [NSString stringWithFormat:@"已自动识别 %lu 处敏感信息，可继续手动涂抹",
                              (unsigned long)rects.count];
        [ss->_paintView setNeedsDisplay];
    }];
}

- (void)onUndo {
    if (_paintView.paths.count > 0) {
        [_paintView.paths removeLastObject];
        [_paintView setNeedsDisplay];
    }
}

- (void)onCancel {
    [self finishWithImage:nil];
}

- (void)onDone {
    CGImageRef cg = _source.CGImage;
    if (!cg) { [self finishWithImage:nil]; return; }
    CGFloat pxW = (CGFloat)CGImageGetWidth(cg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cg);

    // 显示区域(view 坐标) → 图片像素坐标 的比例
    CGRect fit = _paintView.frame;
    CGFloat k = (fit.size.width > 0) ? (pxW / fit.size.width) : 1.0;

    // 手动涂抹路径 → 像素坐标
    NSMutableArray<UIBezierPath *> *pixPaths = [NSMutableArray array];
    NSMutableArray<NSNumber *> *pixWidths = [NSMutableArray array];
    for (UIBezierPath *p in _paintView.paths) {
        UIBezierPath *cp = [UIBezierPath bezierPathWithCGPath:p.CGPath];
        CGAffineTransform t = CGAffineTransformMakeScale(k, k);
        t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(-fit.origin.x * k, -fit.origin.y * k));
        [cp applyTransform:t];
        [pixPaths addObject:cp];
        [pixWidths addObject:@(p.lineWidth * k)];
    }

    CGImageRef mask = [SuperTools createMaskWithSize:CGSizeMake(pxW, pxH)
                                              rects:_smartRects
                                              paths:pixPaths
                                         pathWidths:pixWidths];
    if (!mask) { [Common toast:@"打码失败"]; [self finishWithImage:nil]; return; }

    UIImage *pixelated = [SuperTools pixelatedImage:_source ratio:14.0];
    UIImage *out = [SuperTools applyMask:mask toPixelated:(pixelated ?: _source) onImage:_source];
    CGImageRelease(mask);

    [self finishWithImage:out ?: _source];
}

- (void)finishWithImage:(UIImage *)img {
    void (^comp)(UIImage *) = _completion;
    if (_win) {
        _win.hidden = YES;
        objc_setAssociatedObject(_win, "xz_mosaic_editor", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _win = nil;
    }
    _paintView = nil;
    _source = nil;
    _smartRects = nil;
    _tipLabel = nil;
    _completion = nil;
    if (comp) comp(img);
}

@end

#pragma mark - 取色器窗口

@implementation XZColorPicker {
    UIWindow *_win;
    UIImageView *_imageView;
    UIImage *_source;
    UIView *_swatch;
    UILabel *_hexLabel;
    UIColor *_current;
}

+ (void)show:(UIImage *)image {
    XZColorPicker *cp = [[XZColorPicker alloc] init];
    [cp buildWithImage:image];
}

- (void)buildWithImage:(UIImage *)image {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _win = [[UIWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 250;
    _win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    CGRect fit = XZFitRect(image.size, CGRectMake(8, safe.top + 52, scr.size.width - 16,
                                                  scr.size.height - safe.top - safe.bottom - 150));
    UIImageView *iv = [[UIImageView alloc] initWithFrame:fit];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleToFill;
    iv.userInteractionEnabled = YES;
    [_win addSubview:iv];
    _imageView = iv;
    _source = image;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(onTap:)];
    [iv addGestureRecognizer:tap];

    _swatch = [[UIView alloc] initWithFrame:CGRectMake(20, safe.top + 12, 34, 34)];
    _swatch.backgroundColor = [UIColor clearColor];
    _swatch.layer.cornerRadius = 6;
    _swatch.layer.borderWidth = 1;
    _swatch.layer.borderColor = [UIColor whiteColor].CGColor;
    [_win addSubview:_swatch];

    _hexLabel = [[UILabel alloc] initWithFrame:CGRectMake(64, safe.top + 12, scr.size.width - 150, 34)];
    _hexLabel.text = @"点一下图片上的任意位置取色";
    _hexLabel.textColor = [UIColor whiteColor];
    _hexLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_win addSubview:_hexLabel];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(scr.size.width - 84, safe.top + 12, 72, 34);
    copy.backgroundColor = [UIColor systemBlueColor];
    copy.layer.cornerRadius = 8;
    [copy setTitle:@"复制HEX" forState:UIControlStateNormal];
    [copy setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [copy addTarget:self action:@selector(onCopy) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:copy];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(20, scr.size.height - safe.bottom - 60, scr.size.width - 40, 46);
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    close.layer.cornerRadius = 10;
    [close setTitle:@"关闭取色器" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:close];

    _win.hidden = NO;
    objc_setAssociatedObject(_win, "xz_color_picker", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)onTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:_imageView];
    CGSize isz = _source.size;
    if (isz.width <= 0 || isz.height <= 0) return;
    // view 坐标 → 图片自身坐标系（点）
    CGPoint imgPt = CGPointMake(p.x / _imageView.bounds.size.width * isz.width,
                                p.y / _imageView.bounds.size.height * isz.height);
    UIColor *c = [ImageUtils pixelColorAtPoint:imgPt inImage:_source];
    if (!c) return;

    _current = c;
    _swatch.backgroundColor = c;

    CGFloat r = 0, gg = 0, b = 0, a = 0;
    [c getRed:&r green:&gg blue:&b alpha:&a];
    NSString *hex = [NSString stringWithFormat:@"#%02X%02X%02X",
                     (int)(r * 255), (int)(gg * 255), (int)(b * 255)];
    _hexLabel.text = [NSString stringWithFormat:@"%@   RGB(%d,%d,%d)",
                      hex, (int)(r * 255), (int)(gg * 255), (int)(b * 255)];
}

- (void)onCopy {
    if (!_hexLabel.text.length) return;
    NSString *hex = _hexLabel.text;
    NSRange sp = [hex rangeOfString:@" "];
    if (sp.location != NSNotFound) hex = [hex substringToIndex:sp.location];
    [UIPasteboard generalPasteboard].string = hex;
    [Common toast:[NSString stringWithFormat:@"已复制 %@", hex]];
}

- (void)onClose {
    if (_win) {
        _win.hidden = YES;
        objc_setAssociatedObject(_win, "xz_color_picker", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _win = nil;
    }
    _imageView = nil;
    _source = nil;
    _swatch = nil;
    _hexLabel = nil;
    _current = nil;
}

@end
