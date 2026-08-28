//
//  LongShotCapture.m — 长截图拼接（v4.0 骨架）
//
//  拼接算法（可编译骨架，关键算法已实现核心思路）：
//   1. 相邻两帧用 Vision VNTranslationalImageRegistrationRequest 做图像配准，
//      得到平移量 → 计算重叠高度 → 裁剪重复区。
//   2. 全部帧裁剪后按总高度垂直拼接。
//   3. 最大像素高度上限（防内存溢出）。
//   4. 配准失败（观察不到）时：手动偏移调节兜底（TODO 交互）。
//

#import "LongShotCapture.h"
#import <Vision/Vision.h>

@implementation LongShotCapture {
    NSMutableArray<UIImage *> *_frames;
    CGFloat _maxPxHeight;
}

static LongShotCapture *_shared;

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _shared = [LongShotCapture new]; });
    return _shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frames = [NSMutableArray array];
        _maxPxHeight = 12000;   // 长图最大像素高度，防 OOM
    }
    return self;
}

- (NSInteger)frameCount { return _frames.count; }

- (void)reset { [_frames removeAllObjects]; }

- (void)addFrame:(UIImage *)frame {
    if (frame) [_frames addObject:frame];
}

#pragma mark - 拼接

- (void)stitchWithCompletion:(void (^)(UIImage *result))completion {
    if (_frames.count < 2) { if (completion) completion(nil); return; }
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
        CGFloat frameW = frames.firstObject.size.width;
        CGFloat frameH = frames.firstObject.size.height;

        // 1. 逐对求重叠高度（Vision 平移配准）
        NSMutableArray<NSNumber *> *overlaps = [NSMutableArray array];
        for (NSInteger i = 0; i + 1 < frames.count; i++) {
            CGFloat ov = [self overlapBetween:frames[i] next:frames[i+1] fallback:frameH * 0.2];
            [overlaps addObject:@(ov)];
        }

        // 2. 总高度（叠加有效部分）
        CGFloat totalH = frameH;
        for (NSNumber *ov in overlaps) totalH += (frameH - ov.doubleValue);
        if (totalH > _maxPxHeight) totalH = _maxPxHeight;   // 上限防溢出

        // 3. 垂直拼接（逐帧绘制）
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(frameW, totalH), NO, frames.firstObject.scale);
        CGFloat y = 0;
        for (NSInteger i = 0; i < frames.count; i++) {
            UIImage *f = frames[i];
            CGFloat drawH = frameH;
            if (i > 0) {
                CGFloat ov = overlaps[i-1].doubleValue;
                drawH = frameH - ov;      // 裁掉与上一帧的重叠区
            }
            [f drawInRect:CGRectMake(0, y, frameW, drawH)];
            y += drawH;
        }
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return out;
    } @catch (NSException *e) {
        NSLog(@"[SN3] stitch failed: %@ %@", e.name, e.reason);
        return nil;
    }
}

// Vision 平移配准求重叠高度；失败回退固定 20% 重叠
- (CGFloat)overlapBetween:(UIImage *)a next:(UIImage *)b fallback:(CGFloat)fallback {
    if (@available(iOS 11.0, *)) {
        @try {
            VNTranslationalImageRegistrationRequest *req =
                [[VNTranslationalImageRegistrationRequest alloc] initWithTargetedCGImage:b.CGImage options:@{}];
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCGImage:a.CGImage options:@{}];
            NSError *err = nil;
            [handler performRequests:@[req] error:&err];
            if (!err && req.results.count) {
                VNImageTranslationAlignmentObservation *obs = req.results.firstObject;
                // alignmentTransform.tx = 相对上一帧的平移（像素，CGImage 坐标系）
                CGFloat ty = obs.alignmentTransform.ty;
                CGFloat ov = a.size.height - fabs(ty);
                if (ov > 0 && ov < a.size.height) return ov;
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] registration failed: %@", e);
        }
    }
    // TODO: 手动偏移调节兜底（v4.1：失败时弹 UI 让用户拖重合滑块）
    return fallback;
}

@end
