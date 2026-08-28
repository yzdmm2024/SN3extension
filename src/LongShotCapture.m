//
//  LongShotCapture.m — 长截图拼接实现（超级截图 v4.9）
//
//  拼接原理（参考开源滚动截图方案 Picsew / screen-stitch / FSCapture）：
//    相邻两帧尺寸一致（固定采集框），页面向下滚动时「当前帧顶部」与「上一帧底部」
//    内容相同。对这两段条带做 NCC（归一化互相关系数）比对，峰值位置 = 真实重叠高度 →
//    拼接时当前帧只保留「底部（帧高-重叠）像素」的新内容 → 逐帧垂直叠加，无重复。
//
//    ┌─────────┐ 帧A            ┌─────────┐ 帧B
//    │         │                │ 重叠区  │ ← 与帧A底部相同（NCC 峰值处）
//    │         │                ├─────────┤
//    │         │                │ 新内容  │ ← 只有这段拼进去
//    └─────────┘                └─────────┘
//
//  v4.9 关键改进（彻底消除重复）：
//    · 64px 灰度 SAD → 128 宽 / 每 12 列采样的亮度签名，特征更具判别力；
//    · SAD → NCC，对亮度偏移 / 抗锯齿更稳健；
//    · 单层全搜索 → 粗（整行均值）到细（多列签名）两层搜索，避开局部最小；
//    · 匹配不可靠时【直接跳过该帧】，不再回退固定重叠比例（旧版 80% 兜底的重复根因）。
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

    // 主检测：NCC（归一化互相关系数）帧比对求真实重叠（v4.9 重写）。
    //   不再使用 64px 灰度 SAD（低分辨率导致大量内容「看起来一样」→ 重叠被低估 → 重复），
    //   改用 128 宽、每 12 列采样的高分辨亮度签名 + 粗→细两层 NCC 搜索 + 强置信门限。
    //   匹配不可靠时【直接跳过本帧】（不猜测重叠、不回退固定比例）→ 从根本上杜绝重复/乱拼。
    BOOL confident = NO;
    CGFloat ov = [self overlapPxFromLast:last cur:frame confident:&confident];
    if (!confident) {
        // 不可靠（内容模糊 / 低纹理 / 无明显最优匹配）→ 跳过本帧，等下一次更清晰的帧。
        // 参考 Picsew / screen-stitch：找不到强匹配就「跳过/告警」，而非静默错拼。
        return NO;
    }

    // 无位移（用户没滑动 / 内容整帧重合）→ 丢弃，避免静止帧把长图刷成同一屏
    if (ov >= lastHpx * 0.985) return NO;

    // 钳制：重叠不超过 97%，保证每帧至少贡献 3% 新内容
    ov = MAX(0.0, MIN(ov, lastHpx * 0.97));

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
        return [self simpleConcat:_frames];
    }
}

#pragma mark - v4.9：NCC 帧比对重叠检测（主方法，取代失效的 Vision 配准 + 64px 灰度 SAD）

// NCC（归一化互相关系数），输入两段等长亮度字节，返回 [-1,1]。
// 比 SAD 更稳健：对亮度整体偏移 / 抗锯齿产生的像素偏差不敏感（FSCapture 文所述）。
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
    if (da < 1.0 || db < 1.0) return 0.0f;   // 平坦条带（低纹理）→ 无相关性
    return (float)(num / sqrt(da * db));
}

// 把图降采样到固定宽 XZ_SIG_W，每行取 XZ_SIG_K 个等距列的亮度，组成 (h*K) 字节签名数组。
// 多列采样比「整行均值」更具判别力，是匹配准确的关键（避免不同内容被误判为相同）。
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

// 从签名数组生成「整行均值」数组（1 字节/行），供粗搜使用。
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

// 在候选重叠 o∈[oMin,oMax] 内做 NCC 搜索，返回最优重叠 o 及其 NCC、次优 NCC。
// 比对：sigA 的【底部 o 行】 vs sigB 的【顶部 o 行】（页面向下滚动 → 二者内容相同）。
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
        const unsigned char *a = sigA + (hA - o) * K;   // 上一帧底部
        const unsigned char *b = sigB;                   // 当前帧顶部
        float ncc = nccBytes(a, len, b, len);
        if (ncc > bN) { sN = bN; bN = ncc; bO = o; }
        else if (ncc > sN) { sN = ncc; }
    }
    if (bestO) *bestO = bO;
    if (bestNCC) *bestNCC = bN;
    if (secondNCC) *secondNCC = sN;
}

// 求 cur 相对 last 的重叠像素高度（CGImage 像素坐标）。匹配不可靠时 confident=NO（交由上层跳过）。
// v4.9：粗→细两层 NCC 搜索
//   · 粗搜（整行均值，全局）定位近似重叠，避免局部最小；
//   · 细搜（多列签名，在粗解 ±15% 高度内）精修到精确重叠；
//   · 大滚动/无重叠：NCC 处处极低 → 整帧拼入（不重复）；
//   · 置信度不足 / 无明显最优 → confident=NO → 上层跳过该帧（绝不猜测重叠 → 杜绝重复）。
- (CGFloat)overlapPxFromLast:(UIImage *)last cur:(UIImage *)cur confident:(BOOL *)confident {
    NSInteger hL = 0, hC = 0;
    NSData *sL = [self rowSigsForImage:last outH:&hL];
    NSData *sC = [self rowSigsForImage:cur outH:&hC];
    if (!sL || !sC || hL < 8 || hC < 8) { if (confident) *confident = NO; return (CGFloat)NAN; }

    NSInteger K = XZ_SIG_K;
    NSInteger maxO = MIN(hL, hC) - 1;
    if (maxO < 3) { if (confident) *confident = NO; return (CGFloat)NAN; }
    NSInteger oMin = MAX(2, (NSInteger)(0.02 * (CGFloat)maxO));
    NSInteger oMax = MAX(oMin + 2, (NSInteger)(0.98 * (CGFloat)maxO));

    // 粗搜：整行均值（1 字节/行）全局找近似重叠
    NSData *mL = [self rowMeansFromSigs:sL.bytes h:hL K:K];
    NSData *mC = [self rowMeansFromSigs:sC.bytes h:hC K:K];
    int cO = 0; float cN = -2, cS = -2;
    [self seamSearchSig:mL.bytes hA:(int)hL sigB:mC.bytes hB:(int)hC K:1
                 oMin:(int)oMin oMax:(int)oMax bestO:&cO bestNCC:&cN secondNCC:&cS];

    // 细搜：多列签名，在粗解 ±15% 高度内精修
    int fOmin = MAX((int)oMin, cO - (int)(0.15 * (CGFloat)maxO));
    int fOmax = MIN((int)oMax, cO + (int)(0.15 * (CGFloat)maxO));
    int fO = 0; float fN = -2, fS = -2;
    [self seamSearchSig:sL.bytes hA:(int)hL sigB:sC.bytes hB:(int)hC K:(int)K
                 oMin:fOmin oMax:fOmax bestO:&fO bestNCC:&fN secondNCC:&fS];

    if (fO == 0) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // 大幅滚动 / 几乎无重叠：NCC 处处很低 → 整帧拼入（仅补新内容，不重复）
    if (fN < 0.25f) { if (confident) *confident = YES; return 0.0f; }

    // 置信度不足（绝对相关性过低，常见于大幅滚动/低纹理）→ 上层跳过本帧
    if (fN < 0.60f) { if (confident) *confident = NO; return (CGFloat)NAN; }
    // 无明显最优（次优几乎一样高，匹配不可靠）→ 跳过，避免错拼
    if (fN < fS * 1.06f) { if (confident) *confident = NO; return (CGFloat)NAN; }

    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    CGFloat overlapPx = (CGFloat)fO / (CGFloat)hL * lastHpx;   // 降采样行占比 → 真实像素
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
