//
//  LongShotCapture.m — 长截图拼接实现（超级截图 v5.0）
//
//  v5.0 核心变更：用 Vision VNTranslationalImageRegistrationRequest 做帧间平移配准，
//  直接得到「当前帧相对上一帧垂直位移」，换算成重叠高度 → 拼接时只保留新内容。
//  NCC 降到【校验/兜底】角色：Vision 失败或结果离谱时，用 NCC 粗筛；NCC 也找不到
//  清晰匹配 → 直接跳过该帧，绝不整帧拼入。
//
//  为什么用 Vision 做主检测？
//    它内部基于相位相关 / 特征匹配，对聊天、网页、表格等「重复纹理 + 小位移」场景
//    远比手搓 128px 亮度签名 NCC 稳健；v4.9 的 NCC 在低纹理/重复气泡界面找不到峰，
//    错误地 fallback 到「整帧拼入」，导致长图大量重复。
//
//  ┌─────────┐ 帧A            ┌─────────┐ 帧B
//  │         │                │ 重叠区  │ ← 与帧A底部相同（Vision 给出的位移换算）
//  │         │                ├─────────┤
//  │         │                │ 新内容  │ ← 只有这段拼进去
//  └─────────┘                └─────────┘
//
//  防 OOM：总高度超上限时按比例压缩每段贡献高度（kMaxCanvasBytes）。
//

#import "LongShotCapture.h"
#import "Common.h"
#import <math.h>
#import <objc/message.h>

// 配准时用的降采样宽度（原图 1170px 直接配准太慢，降到 256 宽足够稳健）
static const CGFloat kRegistrationWidth = 256.0;
// 拼接画布字节预算上限（约 80MB），换算成最大像素高度后再与 _maxPxHeight 取小
static const CGFloat kMaxCanvasBytes = 80.0 * 1024.0 * 1024.0;

// v4.9：帧比对用的降采样参数（高分辨率 + 多列采样，保证特征 discriminating）
static const NSInteger XZ_SIG_W = 128;   // 降采样宽
static const NSInteger XZ_SIG_K = 12;    // 每帧采样的等距列数（每行列亮度签名）

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
    CGFloat _emaOverlap;                     // 已接受重叠的指数滑动平均（点），时间先验
    CGFloat _lastShift;                      // 最近一次 Vision 检测到的垂直位移（点）
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
        _emaOverlap = (CGFloat)NAN;
        _lastShift = (CGFloat)NAN;
    }
    return self;
}

- (NSInteger)frameCount { return (NSInteger)_frames.count; }
- (CGFloat)estimatedHeight { return _estimatedHeight; }

- (void)reset {
    [_frames removeAllObjects];
    [_overlaps removeAllObjects];
    _estimatedHeight = 0;
    _emaOverlap = (CGFloat)NAN;
    _lastShift = (CGFloat)NAN;
}

#pragma mark - 入帧

// v5.0：入帧策略
//   1. 第一帧无条件接收；
//   2. 非第一帧先用 Vision VNTranslationalImageRegistrationRequest 求垂直位移 shift（点），
//      换算为重叠 overlap = lastHpx - shift*scale；
//   3. Vision 失败 / 结果离谱 → NCC 校验；NCC 也失败 → 跳过；
//   4. 重叠 < 3% 或 > 98.5% → 跳过（前者接近整帧新内容但无法验证，后者基本重复）；
//   5. 否则接受，并更新时间先验 _emaOverlap/_lastShift。
//   核心原则：匹配不上宁可丢帧，也绝不整帧硬拼。
- (BOOL)addFrame:(UIImage *)frame {
    if (!frame || !frame.CGImage) return NO;

    // 第一帧：无条件接收
    if (_frames.count == 0) {
        [_frames addObject:frame];
        [_overlaps addObject:@(0.0)];
        _emaOverlap = 0.0;
        [self recomputeEstimatedHeight];
        return YES;
    }

    UIImage *last = _frames.lastObject;
    if (!last.CGImage) return NO;

    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    CGFloat lastScale = (last.size.height > 0) ? (lastHpx / last.size.height) : 2.0;
    if (lastHpx < 2) return NO;

    CGFloat shiftPts = 0, overlapPx = 0;
    BOOL confident = NO;

    BOOL visionOk = NO;
    // ----- 1) Vision 平移配准（主检测）-----
    shiftPts = [LongShotCapture visionShiftPtsFrom:last cur:frame];
    if (!isnan(shiftPts)) {
        CGFloat shiftPx = fabs(shiftPts) * lastScale;        // 点 → 上一帧像素（取绝对值，兼容两种符号约定）
        // 合理范围：内容移动 3%~96% 帧高；太小=没滑动，太大=不连续/跳屏
        if (shiftPx > lastHpx * 0.03 && shiftPx < lastHpx * 0.96) {
            overlapPx = lastHpx - shiftPx;
            confident = YES;
            visionOk = YES;
            NSLog(@"[SN3] Vision shift=%.1fpt overlap=%.1fpx", shiftPts, overlapPx);
        }
    }

    // ----- 2) NCC 校验 / Vision 失败兜底 -----
    if (!confident) {
        CGFloat nccOv = [self overlapPxFromLast:last cur:frame confident:&confident];
        if (confident) {
            overlapPx = nccOv;
            NSLog(@"[SN3] NCC fallback overlap=%.1fpx", overlapPx);
        }
    }

    if (!confident) {
        NSLog(@"[SN3] 帧无法配准，跳过（防错拼重复）");
        return NO;
    }

    // 时间先验校验：若已有稳定先验，当前重叠偏离先验 ±40% 则视为异常 → 跳过
    if (!isnan(_emaOverlap) && _emaOverlap > 0) {
        CGFloat emaPx = _emaOverlap * lastScale;
        if (overlapPx < emaPx * 0.60 || overlapPx > emaPx * 1.40) {
            NSLog(@"[SN3] overlap %.1fpx 偏离先验 %.1fpx 太多，跳过", overlapPx, emaPx);
            return NO;
        }
    }

    // 整帧重合 / 没滑动 → 丢弃
    if (overlapPx >= lastHpx * 0.985) {
        NSLog(@"[SN3] 重叠 %.2f%% 视为整帧重复，丢弃", overlapPx / lastHpx * 100.0);
        return NO;
    }

    // 重叠过大（<3% 新内容）→ 丢弃，避免把同一屏刷多次
    if (overlapPx >= lastHpx * 0.97) {
        NSLog(@"[SN3] 重叠 %.2f%% 超过 97%%，丢弃", overlapPx / lastHpx * 100.0);
        return NO;
    }

    // 重叠过小（<3% 重叠）→ 接近整帧新内容，无法确认是否连续 → 跳过
    if (overlapPx <= lastHpx * 0.03) {
        NSLog(@"[SN3] 重叠 %.2f%% 过低，无法确认连续性，跳过", overlapPx / lastHpx * 100.0);
        return NO;
    }

    CGFloat ovPts = overlapPx / lastScale;

    [_frames addObject:frame];
    [_overlaps addObject:@(ovPts)];

    // 更新时间先验（指数滑动平均）
    if (isnan(_emaOverlap)) _emaOverlap = ovPts;
    else _emaOverlap = _emaOverlap * 0.7 + ovPts * 0.3;
    if (visionOk) _lastShift = shiftPts;

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
        return [self simpleConcat:_frames];
    }
}

#pragma mark - v5.0：NCC 校验（Vision 失败时的第二道防线）

// NCC（归一化互相关系数），输入两段等长亮度字节，返回 [-1,1]。
static float nccBytes(const unsigned char *a, int n, const unsigned char *b, int n2) {
    if (!a || !b || n != n2 || n <= 0) return 0.0f;
    long long sa = 0, sb = 0;
    for (int i = 0; i < n; i++) { sa += a[i]; sb += b[i]; }
    double ma = (double)sa / (double)n;
    double mb = (double)sb / (double)n;
    double num = 0, da = 0, db = 0;
    for (int i = 0; i < n; i++) {
        double xa = a[i] - ma, xb = b[i] - mb;
        num += xa * xb; da += xa * xa; db += xb * xb;
    }
    if (da < 1.0 || db < 1.0) return 0.0f;
    return (float)(num / sqrt(da * db));
}

// 把图降采样到固定宽 XZ_SIG_W，每行取 XZ_SIG_K 个等距列的亮度，组成 (h*K) 字节签名数组。
- (NSData *)rowSigsForImage:(UIImage *)img outH:(NSInteger *)outH {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    CGFloat w = (CGFloat)CGImageGetWidth(cg);
    CGFloat h = (CGFloat)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0) return nil;
    NSInteger dsW = XZ_SIG_W;
    NSInteger dsH = (NSInteger)lround(dsW * h / w);
    if (dsH < 2) dsH = 2;
    if (outH) *outH = dsH;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(NULL, dsW, dsH, 8, dsW * 4,
                                             cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dsW, dsH), cg);

    unsigned char *src = CGBitmapContextGetData(ctx);
    if (!src) { CGContextRelease(ctx); return nil; }

    NSInteger K = XZ_SIG_K;
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(dsH * K)];
    unsigned char *dst = d.mutableBytes;
    int cols[K];
    for (int k = 0; k < K; k++) cols[k] = (int)lround((CGFloat)k * (CGFloat)(dsW - 1) / (CGFloat)(K - 1));
    for (NSInteger r = 0; r < dsH; r++) {
        const unsigned char *row = src + r * dsW * 4;
        for (int k = 0; k < K; k++) {
            const unsigned char *p = row + cols[k] * 4;
            dst[r * K + k] = (unsigned char)((p[0] * 299 + p[1] * 587 + p[2] * 114) / 1000);
        }
    }
    CGContextRelease(ctx);
    return d;
}

- (NSData *)rowMeansFromSigs:(const unsigned char *)sig h:(NSInteger)h K:(NSInteger)K {
    if (!sig || h <= 0) return nil;
    NSMutableData *m = [NSMutableData dataWithLength:(NSUInteger)h];
    unsigned char *md = m.mutableBytes;
    for (NSInteger r = 0; r < h; r++) {
        int sum = 0;
        const unsigned char *row = sig + r * K;
        for (int k = 0; k < K; k++) sum += row[k];
        md[r] = (unsigned char)(sum / K);
    }
    return m;
}

- (void)seamSearchSig:(const unsigned char *)sigA hA:(int)hA
               sigB:(const unsigned char *)sigB hB:(int)hB K:(int)K
               oMin:(int)oMin oMax:(int)oMax
              bestO:(int *)bestO bestNCC:(float *)bestNCC secondNCC:(float *)secondNCC {
    int maxO = MIN(hA, hB) - 1;
    if (maxO < 2 || oMin > oMax) { if (bestO) *bestO = 0; if (bestNCC) *bestNCC = -2; if (secondNCC) *secondNCC = -2; return; }
    if (oMin < 2) oMin = 2;
    if (oMax > maxO) oMax = maxO;
    float bN = -2, sN = -2; int bO = 0;
    for (int o = oMin; o <= oMax; o++) {
        int len = o * K;
        const unsigned char *a = sigA + (hA - o) * K;
        const unsigned char *b = sigB;
        float ncc = nccBytes(a, len, b, len);
        if (ncc > bN) { sN = bN; bN = ncc; bO = o; }
        else if (ncc > sN) { sN = ncc; }
    }
    if (bestO) *bestO = bO;
    if (bestNCC) *bestNCC = bN;
    if (secondNCC) *secondNCC = sN;
}

// NCC 校验：仅用于 Vision 主检测失败时。匹配不可靠 → confident=NO（上层跳过）。
// v5.0 删除「低 NCC 整帧拼入」分支，这个分支是 v4.9 聊天界面大量重复的直接元凶。
- (CGFloat)overlapPxFromLast:(UIImage *)last cur:(UIImage *)cur confident:(BOOL *)confident {
    NSInteger hL = 0, hC = 0;
    NSData *sL = [self rowSigsForImage:last outH:&hL];
    NSData *sC = [self rowSigsForImage:cur outH:&hC];
    if (!sL || !sC || hL < 8 || hC < 8) { if (confident) *confident = NO; return (CGFloat)NAN; }

    NSInteger K = XZ_SIG_K;
    NSInteger maxO = MIN(hL, hC) - 1;
    if (maxO < 3) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // 若已有 Vision/历史先验，优先在先验 ±25% 内搜索，避免在重复纹理里找错峰
    NSInteger oMin = MAX(2, (NSInteger)(0.03 * (CGFloat)maxO));
    NSInteger oMax = MAX(oMin + 2, (NSInteger)(0.97 * (CGFloat)maxO));
    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    if (!isnan(_emaOverlap) && _emaOverlap > 0 && lastHpx > 0) {
        CGFloat emaRatio = (_emaOverlap * (lastHpx / last.size.height)) / lastHpx;
        NSInteger emaO = (NSInteger)(emaRatio * hL);
        if (emaO > 2) {
            NSInteger band = (NSInteger)(0.25 * (CGFloat)maxO);
            oMin = MAX(2, emaO - band);
            oMax = MIN(maxO, emaO + band);
        }
    }

    NSData *mL = [self rowMeansFromSigs:sL.bytes h:hL K:K];
    NSData *mC = [self rowMeansFromSigs:sC.bytes h:hC K:K];
    int cO = 0; float cN = -2, cS = -2;
    [self seamSearchSig:mL.bytes hA:(int)hL sigB:mC.bytes hB:(int)hC K:1
                 oMin:(int)oMin oMax:(int)oMax bestO:&cO bestNCC:&cN secondNCC:&cS];

    int fOmin = MAX((int)oMin, cO - (int)(0.15 * (CGFloat)maxO));
    int fOmax = MIN((int)oMax, cO + (int)(0.15 * (CGFloat)maxO));
    int fO = 0; float fN = -2, fS = -2;
    [self seamSearchSig:sL.bytes hA:(int)hL sigB:sC.bytes hB:(int)hC K:(int)K
                 oMin:fOmin oMax:fOmax bestO:&fO bestNCC:&fN secondNCC:&fS];

    if (fO == 0) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // 整帧重合 / 基本没滚动：NCC 高 + 重叠极大 → 返回接近帧高的重叠（上层会丢弃）
    if (fN > 0.88f && (CGFloat)fO / (CGFloat)hL > 0.95) {
        CGFloat overlapPx = (CGFloat)fO / (CGFloat)hL * lastHpx;
        if (confident) *confident = YES;
        return overlapPx;
    }

    // 无明显相关 → 跳过（绝不整帧拼入）
    if (fN < 0.28f) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // 有相关但不强 → 跳过
    if (fN < 0.40f) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // 次优太接近 → 匹配位置不可靠 → 跳过
    if (fN < fS * 1.08f) { if (confident) *confident = NO; return (CGFloat)NAN; }

    CGFloat overlapPx = (CGFloat)fO / (CGFloat)hL * lastHpx;
    if (confident) *confident = YES;
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
// 仅作兜底：主重叠检测已改用 NCC 帧比对（见 overlapPxFromLast:cur:confident:），
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
