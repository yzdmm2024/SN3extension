//
//  LongShotCapture.m — 长截图拼接实现（超级截图 v4.1）
//
//  拼接原理：
//    相邻两帧用 Vision 的 VNTranslationalImageRegistrationRequest 做平移配准，
//    得到帧 B 相对帧 A 的垂直位移 move（像素）→ 重叠高度 ov = 帧高 - move
//    → 拼接时帧 B 只保留「底部 move 像素」的新内容 → 逐帧垂直叠加。
//
//    ┌─────────┐ 帧A            ┌─────────┐ 帧B
//    │         │                │ 重叠区  │ ← 与帧A底部相同
//    │         │                ├─────────┤
//    │         │                │ 新内容  │ ← 只有这段拼进去
//    └─────────┘                └─────────┘
//
//  为什么 Vision 全部走 NSClassFromString + objc_msgSend：
//    CI 用的 theos SDK 是 iPhoneOS14.5，部分 iOS 13+ 才有的 Vision 符号在头文件里
//    并不齐全（v4.0 的 VNRecognizeTextRequest 就踩过）。动态调用 + KVC 取值可以
//    彻底绕开 SDK 头文件版本问题，运行时有就用、没有就走兜底。
//
//  三重兜底（保证任何情况下都不会崩、也不会因为一帧失败整体失败）：
//    1. Vision 配准失败          → 按固定重叠比例（默认 15%）裁剪
//    2. 滑动过快、帧间完全无重叠 → 同上（会有少量内容缺失，好过拼接失败）
//    3. 总高度超上限             → 按比例压缩每段贡献高度，硬控内存
//

#import "LongShotCapture.h"
#import "Common.h"
#import <math.h>
#import <objc/message.h>

// 配准时用的降采样宽度（原图 1170px 直接配准太慢，降到 256 宽足够稳健）
static const CGFloat kRegistrationWidth = 256.0;
// 拼接画布字节预算上限（约 80MB），换算成最大像素高度后再与 _maxPxHeight 取小
static const CGFloat kMaxCanvasBytes = 80.0 * 1024.0 * 1024.0;

@interface LongShotCapture ()
+ (UIImage *)registrationImageForImage:(UIImage *)img;
+ (CGFloat)visionShiftPtsFrom:(UIImage *)a cur:(UIImage *)b;
- (void)recomputeEstimatedHeight;
@end

@implementation LongShotCapture {
    NSMutableArray<UIImage *> *_frames;      // 采集到的帧
    NSMutableArray<NSNumber *> *_overlaps;   // 与上一帧的重叠高度（点），_overlaps[0] 恒为 0
    CGFloat _maxPxHeight;                    // 最大像素高度上限
    CGFloat _overlapRatio;                   // 兜底重叠比例
    CGFloat _estimatedHeight;                // 估算的最终高度（点）
}

static LongShotCapture *_shared = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _shared = [[LongShotCapture alloc] init]; });
    return _shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frames = [NSMutableArray array];
        _overlaps = [NSMutableArray array];
        _maxPxHeight = 12000.0;
        _overlapRatio = XZ_LONG_OVERLAP_DEFAULT;
        _estimatedHeight = 0;
    }
    return self;
}

- (NSInteger)frameCount { return (NSInteger)_frames.count; }
- (CGFloat)estimatedHeight { return _estimatedHeight; }

- (void)reset {
    [_frames removeAllObjects];
    [_overlaps removeAllObjects];
    _estimatedHeight = 0;
}

#pragma mark - 入帧

- (BOOL)addFrame:(UIImage *)frame {
    if (!frame || !frame.CGImage) return NO;

    // 第一帧：无条件接收
    if (_frames.count == 0) {
        [_frames addObject:frame];
        [_overlaps addObject:@(0.0)];
        [self recomputeEstimatedHeight];
        return YES;
    }

    UIImage *last = _frames.lastObject;
    if (!last.CGImage) return NO;

    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    if (lastHpx < 2) return NO;

    // 1) 主检测：像素灰度相关法求真实重叠（单位：像素，对应 CGImage 坐标系）
    CGFloat ov = [self overlapPxFromLast:last cur:frame];

    // 2) 兜底：Vision 配准（仍失败 → 固定比例）
    if (isnan(ov)) {
        ov = [self visionOverlapPxFrom:last cur:frame];
    }
    if (isnan(ov)) {
        ov = lastHpx * _overlapRatio;
    }

    // 3) 无位移（用户没滑动）→ 几乎整帧重合 → 丢弃，避免重复帧把长图刷成同一屏
    if (ov >= lastHpx * 0.99) return NO;

    // 4) 钳制：重叠不超过 98%，保证每帧至少贡献 2% 新内容（防整帧堆叠重复）
    ov = MAX(0.0, MIN(ov, lastHpx * 0.98));

    // 以「点」存储，与 stitchSync 坐标系一致
    CGFloat s = (last.size.height > 0) ? (lastHpx / last.size.height) : 1.0;
    CGFloat ovPts = ov / s;

    [_frames addObject:frame];
    [_overlaps addObject:@(ovPts)];
    [self recomputeEstimatedHeight];
    return YES;
}

- (void)recomputeEstimatedHeight {
    CGFloat h = 0;
    for (NSUInteger i = 0; i < _frames.count; i++) {
        UIImage *f = _frames[i];
        CGFloat fh = f.size.height;
        if (i == 0) {
            h = fh;
        } else {
            CGFloat ov = [_overlaps[i] doubleValue];
            h += MAX(1.0, fh - ov);
        }
    }
    _estimatedHeight = h;
}

- (BOOL)isOverHeightLimit {
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0) scale = 2.0;
    return (_estimatedHeight * scale) >= _maxPxHeight;
}

#pragma mark - 拼接

- (void)stitchWithCompletion:(void (^)(UIImage *result))completion {
    if (_frames.count == 0) { if (completion) completion(nil); return; }
    if (_frames.count == 1) { if (completion) completion(_frames.firstObject); return; }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *result = [self stitchSync];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(result);
        });
    });
}

- (UIImage *)stitchSync {
    @try {
        NSArray<UIImage *> *frames = [_frames copy];
        NSArray<NSNumber *> *ovs   = [_overlaps copy];
        if (frames.count == 0) return nil;

        CGImageRef firstCG = frames.firstObject.CGImage;
        if (!firstCG) return nil;
        CGFloat Wpx = (CGFloat)CGImageGetWidth(firstCG);
        CGFloat Hpx = (CGFloat)CGImageGetHeight(firstCG);
        if (Wpx < 2 || Hpx < 2) return nil;

        // 每段「新贡献」的像素高度：segs[0] = 整帧，其余 = 帧高 - 重叠
        NSMutableArray<NSNumber *> *segs = [NSMutableArray array];
        CGFloat total = Hpx;
        [segs addObject:@(Hpx)];
        for (NSUInteger i = 1; i < frames.count; i++) {
            UIImage *f = frames[i];
            CGImageRef cg = f.CGImage;
            if (!cg) { [segs addObject:@(0.0)]; continue; }
            CGFloat fhPx = (CGFloat)CGImageGetHeight(cg);
            CGFloat ovPts = (i < ovs.count) ? [ovs[i] doubleValue] : (f.size.height * _overlapRatio);
            // 重叠是「点」，换算成该帧的像素
            CGFloat s = (f.size.height > 0) ? (fhPx / f.size.height) : 1.0;
            CGFloat ovPx = MAX(0.0, MIN(ovPts * s, fhPx - 1.0));
            CGFloat add = MAX(1.0, fhPx - ovPx);
            [segs addObject:@(add)];
            total += add;
        }

        // 兜底3：超上限则按比例压缩每段，硬控内存（Wpx * total * 4 bytes）
        CGFloat scale = [UIScreen mainScreen].scale;
        if (scale <= 0) scale = 2.0;
        CGFloat maxPx = _maxPxHeight;
        CGFloat budgetPx = kMaxCanvasBytes / (Wpx * 4.0);
        if (budgetPx < maxPx) maxPx = budgetPx;
        if (total > maxPx && total > 0) {
            CGFloat k = maxPx / total;
            total = maxPx;
            for (NSUInteger i = 0; i < segs.count; i++) {
                segs[i] = @(MAX(1.0, [segs[i] doubleValue] * k));
            }
        }
        if (total < 2 || Wpx < 2) return nil;

        // 画布用像素尺寸 + scale=1，最后再按屏幕 scale 包一层，保证 size 是「点」
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(Wpx, total), YES, 1.0);
        [[UIColor whiteColor] setFill];
        UIRectFill(CGRectMake(0, 0, Wpx, total));

        CGFloat y = 0;
        for (NSUInteger i = 0; i < frames.count && i < segs.count; i++) {
            UIImage *f = frames[i];
            CGFloat add = [segs[i] doubleValue];
            CGFloat fhPx = f.CGImage ? (CGFloat)CGImageGetHeight(f.CGImage) : add;
            if (fhPx < 1) continue;
            // 帧 i 只有「底部 add 像素」是新内容：把整帧上移 (fhPx - add) 后画，
            // 使它的底部正好落在画布 y..y+add
            [f drawInRect:CGRectMake(0, y - (fhPx - add), Wpx, fhPx)];
            y += add;
        }
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        CGImageRef outCG = out.CGImage;
        if (!outCG) {
            // 绝对兜底：直接纵向简单拼接所有帧（无去重，仅防返回 nil 让流程卡死）
            return [self simpleConcat:frames];
        }
        return [UIImage imageWithCGImage:outCG scale:scale orientation:UIImageOrientationUp];
    } @catch (NSException *e) {
        NSLog(@"[SN3] stitch exception: %@ %@", e.name, e.reason);
        return [self simpleConcat:frames];
    }
}

#pragma mark - v4.3：像素灰度相关重叠检测（主方法，取代失效的 Vision 配准）

// 把图降采样成单通道灰度、固定宽度 dsW、等比高度的字节数组（每行 dsW 字节）。
// SpringBoard 内无 Accelerate 保证，这里用 CoreGraphics 直接画进灰度位图上下文。
- (NSData *)grayDataForImage:(UIImage *)img width:(NSInteger)dsW outHeight:(NSInteger *)outH {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    CGFloat w = (CGFloat)CGImageGetWidth(cg);
    CGFloat h = (CGFloat)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0) return nil;
    NSInteger dsH = (NSInteger)lround(dsW * h / w);
    if (dsH < 2) dsH = 2;
    if (outH) *outH = dsH;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(NULL, dsW, dsH, 8, dsW, cs, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dsW, dsH), cg);

    size_t bpr = CGBitmapContextGetBytesPerRow(ctx);
    unsigned char *src = CGBitmapContextGetData(ctx);
    if (!src) { CGContextRelease(ctx); return nil; }
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(dsH * dsW)];
    unsigned char *dst = d.mutableBytes;
    for (NSInteger r = 0; r < dsH; r++) {
        memcpy(dst + r * dsW, src + r * bpr, dsW);
    }
    CGContextRelease(ctx);
    return d;
}

// 求 cur 相对 last 的重叠像素高度（CGImage 像素坐标）。失败返回 NAN。
// 原理：固定左右范围的采集带每帧尺寸一致，页面向下滚动时 cur 的【顶部】若干行
//       与 last 的【底部】若干行内容相同；逐候选重叠 o 比 SAD（绝对差和），取最小者。
- (CGFloat)overlapPxFromLast:(UIImage *)last cur:(UIImage *)cur {
    NSInteger W = 64, hL = 0, hC = 0;
    NSData *gL = [self grayDataForImage:last width:W outHeight:&hL];
    NSData *gC = [self grayDataForImage:cur width:W outHeight:&hC];
    if (!gL || !gC || hL < 4 || hC < 4) return (CGFloat)NAN;

    const unsigned char *a = gL.bytes;
    const unsigned char *b = gC.bytes;

    NSInteger maxO = MIN(hL, hC) - 1;
    if (maxO < 2) return (CGFloat)NAN;

    // 重叠通常落在 10%~95% 区间，缩小搜索范围提速且避免误匹配
    NSInteger oMin = MAX(1, (NSInteger)(0.10 * (CGFloat)maxO));
    NSInteger oMax = (NSInteger)(0.95 * (CGFloat)maxO);
    if (oMax <= oMin) oMax = maxO;

    CGFloat bestSAD = (CGFloat)INFINITY;
    NSInteger bestO = 0;
    for (NSInteger o = oMin; o <= oMax; o++) {
        long long diff = 0;
        for (NSInteger r = 0; r < o; r++) {
            const unsigned char *ra = a + (hL - o + r) * W;
            const unsigned char *rb = b + r * W;
            for (NSInteger c = 0; c < W; c++) {
                NSInteger dv = ra[c] - rb[c];
                diff += dv < 0 ? -dv : dv;
            }
        }
        CGFloat sad = (CGFloat)diff / (CGFloat)(o * W);
        if (sad < bestSAD) { bestSAD = sad; bestO = o; }
    }
    if (bestO == 0) return (CGFloat)NAN;

    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    // bestO（降采样行）占上一帧高度比例 → 真实重叠像素
    CGFloat overlapPx = (CGFloat)bestO / (CGFloat)hL * lastHpx;
    return overlapPx;
}

// Vision 兜底：把垂直位移换算成重叠像素；无重叠或失败返回 NAN/兜底比例。
- (CGFloat)visionOverlapPxFrom:(UIImage *)last cur:(UIImage *)cur {
    CGFloat shiftPts = [LongShotCapture visionShiftPtsFrom:last cur:cur];
    if (isnan(shiftPts)) return (CGFloat)NAN;
    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    CGFloat s = (last.size.height > 0) ? (lastHpx / last.size.height) : 1.0;
    CGFloat shiftPx = shiftPts * s;
    if (shiftPx >= lastHpx) return lastHpx * _overlapRatio;   // 帧间无重叠 → 兜底比例
    return MAX(0.0, lastHpx - shiftPx);
}

// 绝对兜底拼接（仅 stitchSync 异常时调用）：纵向简单堆叠所有帧，保证不返回 nil。
- (UIImage *)simpleConcat:(NSArray<UIImage *> *)frames {
    @try {
        if (frames.count == 0) return nil;
        if (frames.count == 1) return frames.firstObject;
        CGFloat Wpx = (CGFloat)CGImageGetWidth(frames.firstObject.CGImage);
        CGFloat total = 0;
        for (UIImage *f in frames) total += (CGFloat)CGImageGetHeight(f.CGImage);
        if (Wpx < 2 || total < 2) return frames.firstObject;
        CGFloat scale = [UIScreen mainScreen].scale;
        if (scale <= 0) scale = 2.0;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(Wpx, total), YES, 1.0);
        CGFloat y = 0;
        for (UIImage *f in frames) {
            CGFloat fh = (CGFloat)CGImageGetHeight(f.CGImage);
            [f drawInRect:CGRectMake(0, y, Wpx, fh)];
            y += fh;
        }
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        CGImageRef cg = out.CGImage;
        if (!cg) return frames.firstObject;
        return [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    } @catch (NSException *e) {
        return frames.firstObject;
    }
}

// 拼接兜底（finishCapture 拼接失败分支调用）：复跑 stitchSync（现已足够稳健）。
- (UIImage *)stitchFallback {
    @try { return [self stitchSync]; } @catch (NSException *e) { return nil; }
}

#pragma mark - Vision 配准

// 降采样到固定宽度，加速配准（VNTranslationalImageRegistrationRequest 对大图很慢）
+ (UIImage *)registrationImageForImage:(UIImage *)img {
    CGImageRef cg = img.CGImage;
    if (!cg) return img;
    CGFloat w = (CGFloat)CGImageGetWidth(cg);
    if (w <= kRegistrationWidth) return img;
    CGFloat h = (CGFloat)CGImageGetHeight(cg);
    if (h <= 0) return img;

    CGSize sz = CGSizeMake(kRegistrationWidth, h * (kRegistrationWidth / w));
    UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
    [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

// 求 b 相对 a 的垂直位移（点）。失败返回 NAN。
// 仅作兜底：主重叠检测已改用像素灰度相关法（见 overlapPxFromLast:cur:），
// 因为 Vision 的 VNTranslationalImageRegistrationRequest 在 SpringBoard 内经常失效。
+ (CGFloat)visionShiftPtsFrom:(UIImage *)a cur:(UIImage *)b {
    Class reqCls = NSClassFromString(@"VNTranslationalImageRegistrationRequest");
    Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
    if (!reqCls || !handlerCls) return (CGFloat)NAN;
    if (!a.CGImage || !b.CGImage) return (CGFloat)NAN;

    @try {
        id req = [reqCls alloc];
        SEL initSel = NSSelectorFromString(@"initWithTargetedCGImage:options:");
        if (![req respondsToSelector:initSel]) return (CGFloat)NAN;
        req = ((id (*)(id, SEL, CGImageRef, NSDictionary *))objc_msgSend)(req, initSel, b.CGImage, @{});

        id handler = [handlerCls alloc];
        SEL hSel = NSSelectorFromString(@"initWithCGImage:options:");
        if (![handler respondsToSelector:hSel]) return (CGFloat)NAN;
        handler = ((id (*)(id, SEL, CGImageRef, NSDictionary *))objc_msgSend)(handler, hSel, a.CGImage, @{});

        SEL pSel = NSSelectorFromString(@"performRequests:error:");
        if (![handler respondsToSelector:pSel]) return (CGFloat)NAN;
        NSError *err = nil;
        NSArray *reqs = [NSArray arrayWithObject:req];
        ((BOOL (*)(id, SEL, NSArray *, NSError **))objc_msgSend)(handler, pSel, reqs, &err);
        if (err) {
            NSLog(@"[SN3] registration error: %@", err);
            return (CGFloat)NAN;
        }

        NSArray *results = nil;
        @try { results = [req valueForKey:@"results"]; } @catch (NSException *e) { results = nil; }
        if (![results isKindOfClass:[NSArray class]] || results.count == 0) return (CGFloat)NAN;

        id obs = results.firstObject;
        id val = nil;
        @try { val = [obs valueForKey:@"alignmentTransform"]; } @catch (NSException *e) { val = nil; }
        if (![val isKindOfClass:[NSValue class]]) return (CGFloat)NAN;

        CGAffineTransform t = [(NSValue *)val CGAffineTransformValue];
        CGFloat ty = t.ty;
        // t.ty 处于注册图坐标系（宽 kRegistrationWidth），按宽度比还原到原帧【点】坐标
        UIImage *ra = [LongShotCapture registrationImageForImage:a];
        if (ra.size.width > 0) ty = ty * (a.size.width / ra.size.width);
        return ty;
    } @catch (NSException *e) {
        NSLog(@"[SN3] registration exception: %@ %@", e.name, e.reason);
        return (CGFloat)NAN;
    }
}

@end
