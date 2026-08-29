//
//  LongShotCapture.m — 长截图拼接实现（超级截图 v5.1）
//
//  v5.1 核心算法：SAD 模板匹配找相邻帧接缝（不再依赖 Vision / NCC）。
//    相邻两帧尺寸一致（固定采集框），页面向下滚动时「当前帧顶部」与「上一帧底部」
//    内容相同。用 160 宽灰度图，在候选重叠 o∈[8%,95%] 内逐 o 计算平均绝对差(MAD)，
//    取最小 MAD 的 o* 为接缝 → 拼接时当前帧只保留「底部 (帧高-o*) 像素」的新内容。
//
//    ┌─────────┐ 帧A            ┌─────────┐ 帧B
//    │         │                │ 重叠区  │ ← 与帧A底部相同（MAD 最小处 o*）
//    │         │                ├─────────┤
//    │         │                │ 新内容  │ ← 只有这段拼进去
//    └─────────┘                └─────────┘
//
//  接受条件（保证「不重复」且「不全跳过」之间平衡）：
//    ① MAD(o*) < 60% × refMAD（refMAD=oMin/oMax 处 MAD，即「明显不重叠」处），证明找到接缝；
//    ② MAD(o*) < 50（绝对差不过大，排除整屏新内容 / 滚太快）；
//    ③ MAD(o*) 明显优于次优（多候选接近 → 不可靠 → 跳过）。
//  安全阀：连续 ≥5 帧配准失败但内容确实在变 → 强制保守重叠(35%)拼入，杜绝「整段只留首帧」。
//
//  历史教训（已修正）：
//    · v4.9 用 NCC + 「低相关整帧拼入」→ 聊天重复纹理找不到峰 → 整屏堆叠重复；
//    · v5.0 用 Vision 主检测 + NCC 严格阈值 → Vision 在 SpringBoard 调不动 → 全跳过 → 只剩首帧；
//    · v5.1 改用纯 SAD（OC 原生、设备必可用），阈值用「相对差」而非绝对相关性，稳健。
//
//  防 OOM：总高度超上限时按比例压缩每段贡献高度（kMaxCanvasBytes）。
//

#import "LongShotCapture.h"
#import "Common.h"
#import <math.h>

// 拼接画布字节预算上限（约 120MB），换算成最大像素高度后再与 _maxPxHeight 取小。
// v5.2：上调预算并为超长内容改为「整体降分辨率」而非「压缩每帧高度」，消除叠影。
static const CGFloat kMaxCanvasBytes = 120.0 * 1024.0 * 1024.0;

@interface LongShotCapture ()
- (void)recomputeEstimatedHeight;
- (BOOL)appendFrame:(UIImage *)frame overlapPx:(CGFloat)overlapPx;
@end

@implementation LongShotCapture {
    NSMutableArray<UIImage *> *_frames;      // 采集到的帧
    NSMutableArray<NSNumber *> *_overlaps;   // 与上一帧的重叠高度（点），_overlaps[0] 恒为 0
    CGFloat _maxPxHeight;                    // 最大像素高度上限
    CGFloat _overlapRatio;                   // 兜底重叠比例
    CGFloat _estimatedHeight;                // 估算的最终高度（点）
    CGFloat _emaOverlap;                     // 已接受重叠的指数滑动平均（点），时间先验（首帧为 NAN）
    NSInteger _skipStreak;                   // 连续被配准拒掉的帧数（安全阀计数）
    CGFloat _lastMAD;                        // 最近一次 SAD 的最优平均差（安全阀判断「内容是否真变了」）
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
        _maxPxHeight = 60000.0;   // v5.2：放宽硬上限（实际仍以 kMaxCanvasBytes 内存预算为准）
        _overlapRatio = XZ_LONG_OVERLAP_DEFAULT;
        _estimatedHeight = 0;
        _emaOverlap = (CGFloat)NAN;
        _skipStreak = 0;
        _lastMAD = 1e9f;
    }
    return self;
}

- (NSInteger)frameCount { return (NSInteger)_frames.count; }
- (CGFloat)estimatedHeight { return _estimatedHeight; }

// v5.13：最近一帧相对上一帧的重叠比例(点/点)。_overlaps 存的就是点，直接与帧高比。
- (CGFloat)lastOverlapRatio {
    if (_overlaps.count < 2 || _frames.count < 2) return (CGFloat)NAN;
    CGFloat ovPts = [_overlaps.lastObject doubleValue];
    CGFloat h = _frames.lastObject.size.height;
    if (h <= 0) return (CGFloat)NAN;
    return MAX(0.0, MIN(1.0, ovPts / h));
}

- (void)reset {
    [_frames removeAllObjects];
    [_overlaps removeAllObjects];
    _estimatedHeight = 0;
    _emaOverlap = (CGFloat)NAN;
    _skipStreak = 0;
    _lastMAD = 1e9f;
}

#pragma mark - 入帧

// v5.1：入帧策略（SAD 模板匹配，不再依赖 Vision；对真实设备稳健）
//   1. 第一帧无条件接收；
//   2. 非第一帧用 SAD 在「上一帧底部 o 行 vs 当前帧顶部 o 行」找接缝（o=重叠行数）：
//        - 接缝处平均差最小且明显小于「明显不重叠」处（refMAD）→ 接受，overlap=o；
//        - 找不到可靠接缝 → 跳过；
//   3. 连续跳过 ≥5 帧且内容确实在变（_lastMAD 较大）→ 安全阀强制以 35% 保守重叠拼入，
//      杜绝「整段只留首帧」这种完全不可用的结果（宁可极少重复，也好过一张图）。
//   绝不回退「整帧拼入」/「固定比例重叠」，杜绝 v4.9 那种整屏重复堆叠。
- (BOOL)addFrame:(UIImage *)frame {
    if (!frame || !frame.CGImage) return NO;

    // 第一帧：无条件接收（无先验）
    if (_frames.count == 0) {
        [_frames addObject:frame];
        [_overlaps addObject:@(0.0)];
        _emaOverlap = (CGFloat)NAN;
        _skipStreak = 0;
        _lastMAD = 1e9f;
        [self recomputeEstimatedHeight];
        return YES;
    }

    UIImage *last = _frames.lastObject;
    if (!last.CGImage) return NO;

    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    if (lastHpx < 2) return NO;

    BOOL confident = NO;
    CGFloat overlapPx = [self sadOverlapPxFromLast:last cur:frame confident:&confident];

    if (!confident) {
        _skipStreak++;
        // 安全阀：连续多帧配准失败，但两帧内容确实不同（用户在滑动）→ 强制保守拼入
        if (_skipStreak >= 5 && _lastMAD > 30.0f) {
            overlapPx = lastHpx * 0.25;   // v5.2：安全阀强制重叠从 35% 降到 25%，减少可见重复块
            confident = YES;
            NSLog(@"[SN3] 安全阀：连续 %ld 帧未匹配但内容变化，强制保守重叠拼入", (long)_skipStreak);
        } else {
            return NO;
        }
    } else {
        _skipStreak = 0;
    }

    // 整帧重合 / 几乎没滑动（重叠≥97%） → 丢弃，避免把同一屏刷多次
    if (overlapPx >= lastHpx * 0.97) {
        NSLog(@"[SN3] 重叠 %.2f%%≈整帧，丢弃", overlapPx / lastHpx * 100.0);
        return NO;
    }
    // 无重叠（重叠≤3%，接近整帧全新内容）→ 丢弃，防不连续跳屏
    if (overlapPx <= lastHpx * 0.03) {
        NSLog(@"[SN3] 重叠 %.2f%%过低，丢弃", overlapPx / lastHpx * 100.0);
        return NO;
    }

    return [self appendFrame:frame overlapPx:overlapPx];
}

// v5.2：实际把一帧拼入队列（自动/手动共用），overlapPx 为与上一帧的重叠像素高。
- (BOOL)appendFrame:(UIImage *)frame overlapPx:(CGFloat)overlapPx {
    UIImage *last = _frames.lastObject;
    CGFloat lastHpx = last ? (CGFloat)CGImageGetHeight(last.CGImage) : 0;
    CGFloat scale = (last.size.height > 0) ? (lastHpx / last.size.height) : 2.0;
    CGFloat ovPts = overlapPx / scale;

    [_frames addObject:frame];
    [_overlaps addObject:@(ovPts)];

    // 更新时间先验（指数滑动平均），仅用于后续轻微异常检测
    if (isnan(_emaOverlap)) _emaOverlap = ovPts;
    else _emaOverlap = _emaOverlap * 0.6 + ovPts * 0.4;

    [self recomputeEstimatedHeight];
    return YES;
}

// v5.2：手动长截图模式追加一帧（用户滑完一屏后主动点【下一屏】）。
//   有可靠 SAD 接缝则用之；配不准时按极小保守重叠(10%)拼入，避免重复堆叠。
- (BOOL)addManualFrame:(UIImage *)frame {
    if (!frame || !frame.CGImage) return NO;

    // 第一帧：无条件接收（无先验）
    if (_frames.count == 0) {
        [_frames addObject:frame];
        [_overlaps addObject:@(0.0)];
        _emaOverlap = (CGFloat)NAN;
        _skipStreak = 0;
        _lastMAD = 1e9f;
        [self recomputeEstimatedHeight];
        return YES;
    }

    UIImage *last = _frames.lastObject;
    if (!last.CGImage) return NO;
    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    if (lastHpx < 2) return NO;

    BOOL confident = NO;
    CGFloat overlapPx = [self sadOverlapPxFromLast:last cur:frame confident:&confident];
    if (!confident) {
        overlapPx = lastHpx * 0.10;   // 手动模式默认极小重叠，宁可漏一点也不要重复
        NSLog(@"[SN3] 手动帧 SAD 不可靠，按 10%% 保守重叠拼入");
    }

    // 几乎整帧重合（用户没滑）→ 丢弃
    if (overlapPx >= lastHpx * 0.97) {
        NSLog(@"[SN3] 手动帧重叠 %.2f%%≈整帧，丢弃", overlapPx / lastHpx * 100.0);
        return NO;
    }
    if (overlapPx <= lastHpx * 0.02) overlapPx = lastHpx * 0.02;

    return [self appendFrame:frame overlapPx:overlapPx];
}

// v5.3：精确模式入帧（重叠由 App 真实滚动增量算出，不靠 SAD 猜测）。
- (BOOL)addExactFrame:(UIImage *)frame overlapPoints:(CGFloat)overlapPoints {
    if (!frame || !frame.CGImage) return NO;

    if (_frames.count == 0) {
        [_frames addObject:frame];
        [_overlaps addObject:@(0.0)];
        _emaOverlap = (CGFloat)NAN;
        _skipStreak = 0;
        _lastMAD = 1e9f;
        [self recomputeEstimatedHeight];
        return YES;
    }

    UIImage *last = _frames.lastObject;
    CGFloat lastHpts = last.size.height;
    if (lastHpts < 1) {
        CGFloat px = last.CGImage ? (CGFloat)CGImageGetHeight(last.CGImage) : 0;
        CGFloat sc = [UIScreen mainScreen].scale; if (sc <= 0) sc = 2.0;
        lastHpts = px / sc;
    }
    CGFloat regionH = lastHpts;                 // 与上一帧同高（采集区域固定）

    CGFloat ov = overlapPoints;
    if (ov < 2.0f) ov = 2.0f;                   // 极小重叠，防缝隙
    if (ov >= regionH * 0.97f) {                // 几乎整帧重合 = 没滚 = 重复
        NSLog(@"[SN3] 精确帧重叠 %.1f%%≈整帧，丢弃", ov / regionH * 100.0);
        return NO;
    }
    [_frames addObject:frame];
    [_overlaps addObject:@(ov)];
    [self recomputeEstimatedHeight];
    NSLog(@"[SN3] 精确帧：滚动增量=%.1fpt → 重叠=%.1fpt", regionH - overlapPoints, ov);
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

        // 兜底：超内存预算则【整体降分辨率】拼接（画布等比缩小 s 倍），保持各帧重叠比例不变，
        // 从根本上消除「压缩每帧高度」导致的叠影；牺牲一点清晰度换取超长图可用。
        CGFloat scale = [UIScreen mainScreen].scale;
        if (scale <= 0) scale = 2.0;
        CGFloat maxPx = _maxPxHeight;
        CGFloat budgetPx = kMaxCanvasBytes / (Wpx * 4.0);
        if (budgetPx < maxPx) maxPx = budgetPx;
        CGFloat s = 1.0;                         // 输出相对采集分辨率的缩放（<=1）
        if (total > maxPx && total > 0) s = maxPx / total;
        CGFloat outW = Wpx * s;
        CGFloat outH = total * s;
        if (outW < 2 || outH < 2) return nil;

        UIGraphicsBeginImageContextWithOptions(CGSizeMake(outW, outH), YES, 1.0);
        [[UIColor whiteColor] setFill];
        UIRectFill(CGRectMake(0, 0, outW, outH));

        CGFloat y = 0;
        for (NSUInteger i = 0; i < frames.count && i < segs.count; i++) {
            UIImage *f = frames[i];
            CGFloat add = [segs[i] doubleValue];
            CGFloat fhPx = f.CGImage ? (CGFloat)CGImageGetHeight(f.CGImage) : add;
            if (fhPx < 1) continue;
            // 帧 i 只有「底部 add 像素」是新内容：整帧上移 (fhPx - add)，再整体乘 s 落到画布
            CGFloat drawY = (y - (fhPx - add)) * s;
            CGFloat drawH = fhPx * s;
            [f drawInRect:CGRectMake(0, drawY, outW, drawH)];
            y += add;
        }
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        CGImageRef outCG = out.CGImage;
        if (!outCG) {
            // 绝对兜底：直接纵向简单拼接所有帧（无去重，仅防返回 nil 让流程卡死）
            return [self simpleConcat:frames];
        }
        // 分辨率已按 s 缩进画布，故直接以 scale=1 输出（点尺寸=像素尺寸）
        return [UIImage imageWithCGImage:outCG scale:1.0 orientation:UIImageOrientationUp];
    } @catch (NSException *e) {
        NSLog(@"[SN3] stitch exception: %@ %@", e.name, e.reason);
        return [self simpleConcat:_frames];
    }
}

#pragma mark - v5.1：SAD 模板匹配找接缝（主配准，不依赖 Vision / NCC）

// 降采样到固定宽 160 的单通道灰度图（每行 160 字节）。速度快、足够判别接缝。
- (NSData *)gray160:(UIImage *)img outH:(NSInteger *)outH {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    CGFloat w = (CGFloat)CGImageGetWidth(cg);
    CGFloat h = (CGFloat)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0) return nil;
    NSInteger W = 160;
    NSInteger dsH = (NSInteger)lround(W * h / w);
    if (dsH < 2) dsH = 2;
    if (outH) *outH = dsH;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, dsH, 8, W * 4,
                                             cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, dsH), cg);

    unsigned char *src = CGBitmapContextGetData(ctx);
    if (!src) { CGContextRelease(ctx); return nil; }

    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(dsH * W)];
    unsigned char *dst = d.mutableBytes;
    for (NSInteger r = 0; r < dsH; r++) {
        const unsigned char *row = src + r * W * 4;
        for (NSInteger c = 0; c < W; c++) {
            const unsigned char *p = row + c * 4;
            dst[r * W + c] = (unsigned char)((p[0] * 299 + p[1] * 587 + p[2] * 114) / 1000);
        }
    }
    CGContextRelease(ctx);
    return d;
}

// 计算 last 的【底部 o 行】与 cur 的【顶部 o 行】的平均绝对差（MAD）。
static CGFloat blockMAD(const unsigned char *a, NSInteger hA,
                        const unsigned char *b, NSInteger o, NSInteger W) {
    NSInteger n = o * W;
    if (n <= 0) return 1e9f;
    const unsigned char *pa = a + (hA - o) * W;
    const unsigned char *pb = b;
    long long s = 0;
    for (NSInteger i = 0; i < n; i++) {
        NSInteger dv = pa[i] - pb[i];
        s += dv < 0 ? -dv : dv;
    }
    return (CGFloat)s / (CGFloat)n;
}

// 求 cur 相对 last 的重叠像素高度（CGImage 像素坐标系）。匹配不可靠 → confident=NO（上层跳过）。
// 原理（参考 Pixsew / screen-stitch / FSCapture 开源滚动截图方案）：
//   相邻两帧宽一致，页面向下滚动时「当前帧顶部」与「上一帧底部」内容相同。
//   在候选重叠 o∈[8%,95%] 内逐 o 计算 MAD，取最小 MAD 的 o* 为接缝。
//   判定「找到接缝」：① MAD(o*) 明显小于「明显不重叠处」(refMAD，取 oMin/oMax 处 MAD 较大者)；
//                    ② MAD(o*) 绝对差不过大（<50，排除整屏新内容/滚太快）；
//                    ③ MAD(o*) 明显优于次优（多个候选接近 → 不可靠）。
- (CGFloat)sadOverlapPxFromLast:(UIImage *)last cur:(UIImage *)cur confident:(BOOL *)confident {
    NSInteger W = 160, hL = 0, hC = 0;
    NSData *gL = [self gray160:last outH:&hL];
    NSData *gC = [self gray160:cur outH:&hC];
    if (!gL || !gC || hL < 8 || hC < 8) { if (confident) *confident = NO; return (CGFloat)NAN; }

    const unsigned char *a = gL.bytes;
    const unsigned char *b = gC.bytes;
    NSInteger maxO = MIN(hL, hC) - 1;
    if (maxO < 3) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // 搜索带：允许快滚(8%)到接近整帧重合(95%，更大视为没滑动→丢弃)
    NSInteger oMin = MAX(2, (NSInteger)(0.08 * (CGFloat)maxO));
    NSInteger oMax = MAX(oMin + 2, (NSInteger)(0.95 * (CGFloat)maxO));

    CGFloat bestMAD = 1e9f, secondMAD = 1e9f;
    NSInteger bestO = 0;
    CGFloat madOmin = 0, madOmax = 0;
    for (NSInteger o = oMin; o <= oMax; o++) {
        CGFloat mad = blockMAD(a, hL, b, o, W);
        if (o == oMin) madOmin = mad;
        if (o == oMax) madOmax = mad;
        if (mad < bestMAD) { secondMAD = bestMAD; bestMAD = mad; bestO = o; }
        else if (mad < secondMAD) { secondMAD = mad; }
    }
    _lastMAD = bestMAD;
    if (bestO == 0) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // ① 整帧重合 / 基本没滚动：重叠极大且差极小 → 视为没滑动，上层丢弃
    if ((CGFloat)bestO / (CGFloat)maxO >= 0.95 && bestMAD < 12.0f) {
        if (confident) *confident = NO; return (CGFloat)NAN;
    }

    // ② 参考「明显不重叠」处平均差；接缝必须明显比它更相似才可信
    CGFloat refMAD = MAX(madOmin, madOmax);
    if (refMAD < 1.0f) refMAD = 1.0f;
    if (bestMAD > refMAD * 0.60f) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // ③ 绝对差过大（内容确实不同，可能滚太快/整屏新内容）→ 跳过，等后续帧
    if (bestMAD > 50.0f) { if (confident) *confident = NO; return (CGFloat)NAN; }

    // ④ v5.2：聊天等重复纹理场景次优候选很接近属正常；仅当「best 不算很低(>18)
    //    且次优明显更优(差距>5%)」才判为不可靠跳过，避免安全阀频发造成大块重叠。
    if (bestMAD > 18.0f && bestMAD > secondMAD * 0.95f) {
        if (confident) *confident = NO; return (CGFloat)NAN;
    }

    CGFloat lastHpx = (CGFloat)CGImageGetHeight(last.CGImage);
    CGFloat overlapPx = (CGFloat)bestO / (CGFloat)hL * lastHpx;   // 降采样行占比 → 真实像素
    if (confident) *confident = YES;
    NSLog(@"[SN3] SAD 接缝 o=%.0f/%.0f mad=%.1f ref=%.1f → overlap=%.1fpx",
          (CGFloat)bestO, (CGFloat)maxO, bestMAD, refMAD, overlapPx);
    return overlapPx;
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

@end
