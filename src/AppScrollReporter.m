//
//  AppScrollReporter.m — 精确长截图 · App 侧滚动监听（超级截图 v5.3）
//
//  原理：
//    SpringBoard 的长截图「精确模式」点【开始采集】时 notify_post(arm)，并把采集区域
//    高度(点)写入 notify 状态 SN3_LS_REGIONH。本类收到 arm 后：
//      1. 在 keyWindow 的视图树里找 contentSize 最大的 UIScrollView（聊天消息列表）；
//      2. 每 0.1s 轮询它的 contentOffset.y（不用 KVO，避免滚动视图释放导致崩溃）；
//      3. 累计滚动量 ≥ 半屏 且 停止滚动 0.2s（用户停手）→ 把当前 contentOffset.y 写入
//         SN3_LS_OFFSET 状态、notify_post(capture)，SpringBoard 据此抓当前屏并按精确
//         增量拼接。
//    用户滑到顶/底不动时不会重复抓（累计量不够）；快速连滑会在每次停手时抓一屏。
//    disarm 时若还有少量未抓的增量（≥5% 屏高）补抓最后一屏。
//
//  为什么不用 KVO：arm 后用户可能退出聊天（滚动视图释放），KVO 在 dealloc 时会崩溃；
//  改为轮询并在 _sv 变 nil 时自动 disarm，安全。
//

#include <notify.h>
#import "AppScrollReporter.h"
#import "SN3Notify.h"

static AppScrollReporter *g_inst = nil;
static int g_armTok = 0, g_disarmTok = 0, g_offsetTok = 0, g_regionTok = 0;

@implementation AppScrollReporter {
    __weak UIScrollView *_sv;        // 主滚动视图（弱引用，释放即失效）
    CGFloat _lastObs;                // 上一 tick 的 contentOffset.y
    CGFloat _accum;                  // 自上次抓帧累计的滚动量（点）
    NSTimeInterval _lastChange;      // 最近一次发生滚动的时间
    BOOL   _armed;
    CGFloat _regionH;                // 采集区域高（点），来自 SB
    NSTimer *_timer;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_inst = [[AppScrollReporter alloc] init]; });
    return g_inst;
}

+ (void)setup {
    notify_register_dispatch(SN3_LS_ARM, &g_armTok, dispatch_get_main_queue(), ^(int t) {
        [[AppScrollReporter shared] arm];
    });
    notify_register_dispatch(SN3_LS_DISARM, &g_disarmTok, dispatch_get_main_queue(), ^(int t) {
        [[AppScrollReporter shared] disarm];
    });
    notify_register_check(SN3_LS_OFFSET, &g_offsetTok);
    notify_register_check(SN3_LS_REGIONH, &g_regionTok);
    NSLog(@"[SN3] AppScrollReporter registered (arm/disarm/offset/regionh)");
}

// 在视图树里找 contentSize 最高的可见 UIScrollView（聊天消息列表通常是最大的那个）
- (UIScrollView *)findMainScrollView {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) win = [UIApplication sharedApplication].windows.lastObject;
    if (!win) return nil;

    UIView *root = win.rootViewController ? win.rootViewController.view : win;
    UIScrollView *best = nil;
    CGFloat bestH = 0;
    // 迭代遍历（聊天界面层级可能很深，避免递归爆栈）
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat ch = sv.contentSize.height;
            if (ch > bestH && ch > 300.0f) { bestH = ch; best = sv; }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return best;
}

- (void)arm {
    _armed = YES;
    _sv = [self findMainScrollView];
    if (!_sv) {
        NSLog(@"[SN3] app: 未找到可滚动视图，精确模式将由 SB 看门狗回退自动");
        return;
    }
    uint64_t rh = 0;
    notify_get_state(g_regionTok, &rh);
    _regionH = (CGFloat)rh / 100.0f;
    if (_regionH < 100.0f) _regionH = [UIScreen mainScreen].bounds.size.height;

    _lastObs = _sv.contentOffset.y;
    _accum = 0;
    _lastChange = [[NSDate date] timeIntervalSince1970];

    [_timer invalidate]; _timer = nil;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                             target:self
                                           selector:@selector(poll)
                                           userInfo:nil
                                            repeats:YES];
    // 立即抓第 1 屏（当前滚动位置）
    [self sendCaptureAt:_sv.contentOffset.y];
    NSLog(@"[SN3] app: armed, regionH=%.0f, scrollView contentSize=%.0f",
          _regionH, _sv.contentSize.height);
}

- (void)disarm {
    _armed = NO;
    [_timer invalidate]; _timer = nil;
    // 收尾：若还有少量未抓增量（≥5% 屏高）补抓最后一屏
    if (_sv && _accum >= _regionH * 0.05f) {
        [self sendCaptureAt:_sv.contentOffset.y];
    }
    _sv = nil;
    NSLog(@"[SN3] app: disarmed");
}

- (void)poll {
    if (!_armed) return;
    if (!_sv) { [self disarm]; return; }   // 滚动视图已释放，安全退出

    CGFloat now = _sv.contentOffset.y;
    CGFloat d = now - _lastObs;
    NSTimeInterval t = [[NSDate date] timeIntervalSince1970];
    if (fabs(d) > 0.5f) {                   // 这一 tick 发生了滚动
        _accum += fabs(d);
        _lastObs = now;
        _lastChange = t;
    }
    // 累计滚够半屏 且 已停手 0.2s → 抓一屏并清零累计
    if (_accum >= _regionH * 0.5f && (t - _lastChange) > 0.2) {
        [self sendCaptureAt:now];
        _accum = 0;
    }
}

- (void)sendCaptureAt:(CGFloat)offset {
    uint64_t enc = (uint64_t)(round(offset * 100.0));
    notify_set_state(g_offsetTok, enc);     // 写精确偏移（点*100），SB 读取
    notify_post(SN3_LS_CAPTURE);            // 触发 SB 抓当前屏
}

@end
