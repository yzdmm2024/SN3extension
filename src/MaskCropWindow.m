//
//  MaskCropWindow.m — 窗口A：遮罩镂空框选 + 长截图双标尺调节（超级截图 v4.1）
//
//  ────────────────────────────────────────────────────────────────────────
//  本文件是整套交互的「第一阶段」，严格遵守规格书：
//    · 框选/长截图调节阶段【绝不出现】两排编辑工具栏（那属于窗口B）
//    · 抓帧前必先隐藏遮罩，绝不把半透明黑截进图片
//    · 长截图调节复用本窗口，不新建独立窗口
//    · 退出时完整销毁窗口并置空
//
//  调用关系：
//    Tweak.xm  (收到 darwin 通知 com.axs.snapper3zhext.cc.capture)
//        └─> [MaskCropWindow.sharedInstance show]
//                 ├─ 框选模式  ──> onNormalShot ──> captureShotAndEdit ─┐
//                 └─ 长截图模式 ──> onLongGenerate ──> 分段抓帧循环 ─────┤
//                                                                      ▼
//                                             LongShotCapture.stitchWithCompletion
//                                                                      │
//                                        [self dismiss] ─> [EditToolbarWindow showWithImage:]
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.1 修复记录
//   1) 【致命】裁剪坐标空间错误：v4.0 把选区(点)×scale 当像素 rect，再跟 img.size
//      （UIGetScreenImage 返回的图 size 通常是「点」）做 CGRectIntersection，
//      导致屏幕下半部分的选区被裁成空 → 返回 nil → 弹「裁剪失败」→ 窗口B 永不出现。
//      现统一走 ImageUtils.cropImage:screenRect:（按比例换算，不假设点/像素）。
//   2) 【致命】普通 UIWindow 的 hitTest 命中空白区返回窗口自身 → 长截图调节阶段
//      底层 App 根本滑不动。现改用 XZPassThroughWindow，白名单外一律穿透。
//   3) 矩形 clamp 修正：旧代码只限制 w<=屏宽，未考虑 x 偏移，框可超出右/下边界。
//   4) 新增「长截图双标尺调节子模式」：左右锁死 + 两条只能上下拖的标尺 +
//      【生成长图】【重置】【取消】；生成长图 = 分段抓帧 + Vision 配准拼接。
//  ────────────────────────────────────────────────────────────────────────
//

#import "MaskCropWindow.h"
#import "XZPassThroughWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "EditToolbarWindow.h"
#import "LongShotCapture.h"

// ---------- 布局常量（pt） ----------
static const CGFloat kToolbarH  = 96.0;   // 底部按钮区总高（含安全区外留白）
static const CGFloat kButtonH   = 46.0;   // 按钮高
static const CGFloat kRulerH    = 30.0;   // 标尺触摸热区高（视觉是 2pt 细线 + 把手）
static const CGFloat kHUDH      = 54.0;   // 自动采集阶段底部进度条高
static const CGFloat kMinCrop   = 16.0;   // 有效选区最小边长
static const CGFloat kMinBandH  = 60.0;   // 两条标尺最小间距

// ---------- 自动采集参数 ----------
static const NSTimeInterval kCaptureInterval = 0.32;  // 抓帧间隔（秒）
static const NSInteger      kIdleLimit       = 30;    // 连续无位移帧数上限（约 9.6s 自动结束）

typedef NS_ENUM(NSInteger, XZDragTarget) {
    XZDragNone       = 0,
    XZDragDraw,          // 框选：画新矩形
    XZDragMove,          // 框选：整体拖动（宽高不变、不旋转）
    XZDragRulerTop,      // 长截图：拖「起始上线」
    XZDragRulerBottom,   // 长截图：拖「结束下线」
};

@interface MaskCropWindow () <UIGestureRecognizerDelegate>
- (void)setWindowHidden:(BOOL)hidden;
- (void)captureShotAndEditWithRect:(CGRect)rect;
- (void)enterCapturePhase;
- (void)exitCapturePhase;
- (void)captureTick;
- (void)finishCapture;
- (void)updateHUD;
- (CGRect)bandScreenRect;
- (void)refreshChrome;      // v4.2：强制刷新底部按钮栏（可见/布局/置顶）
@end

@implementation MaskCropWindow {
    XZPassThroughWindow *_win;      // 窗口A（可穿透）
    UIView      *_contentView;      // 全屏容器
    CAShapeLayer *_dimLayer;        // 半透明黑遮罩（evenOdd 镂空）
    CAShapeLayer *_borderLayer;     // 蓝色描边

    // ---- 底部按钮区 ----
    UIView   *_toolbar;
    UIButton *_btnLong;             // 长截图
    UIButton *_btnNormal;           // 正常截图
    UIButton *_btnCancel;           // 取消
    UIButton *_btnGenerate;         // 生成长图
    UIButton *_btnReset;            // 重置
    UIButton *_btnBackCrop;         // 取消（回普通框选）
    UILabel  *_hintLabel;           // 顶部提示

    // ---- 长截图双标尺 ----
    UIView *_rulerTop;              // 起始上线（tag = 101）
    UIView *_rulerBottom;           // 结束下线（tag = 102）
    UIView *_topLine, *_bottomLine; // 标尺里的 2pt 细线
    UILabel *_bandLabel;            // 标尺间距提示

    // ---- 自动采集 HUD ----
    UIView   *_hud;
    UILabel  *_hudLabel;
    UIButton *_hudDone;
    BOOL _capturing;                // 是否处于自动分段抓帧中
    NSInteger _idleTicks;

    // ---- 状态 ----
    XZMaskMode   _mode;
    XZDragTarget _drag;
    CGRect  _cropRect;              // 当前选区（屏幕点坐标）
    BOOL    _hasCrop;
    CGPoint _panStart;              // 画框起点
    CGPoint _panGrab;               // 拖动时手指在框内的相对偏移

    // 长截图锁定量（进入长截图模式时由 _cropRect 冻结）
    CGFloat _longX;                 // 锁死的左边界
    CGFloat _longW;                 // 锁死的宽度
    CGFloat _topY;                  // 起始上线 Y
    CGFloat _bottomY;               // 结束下线 Y
    CGFloat _bandMinY;              // 标尺可拖范围上界
    CGFloat _bandMaxY;              // 标尺可拖范围下界
}

#pragma mark - 单例 / 生命周期

+ (instancetype)sharedInstance {
    static MaskCropWindow *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[MaskCropWindow alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = XZMaskModeCrop;
        _drag = XZDragNone;
        _cropRect = CGRectZero;
        _hasCrop = NO;
        _capturing = NO;
        _idleTicks = 0;
    }
    return self;
}

#pragma mark - 建窗

- (void)show {
    // 重复点按控制中心：先完整销毁旧窗口，避免叠加泄漏
    if (_win) [self dismiss];
    [[LongShotCapture sharedInstance] reset];

    CGRect scr = [UIScreen mainScreen].bounds;

    _win = [[XZPassThroughWindow alloc] initWithFrame:scr];
    _win.windowLevel = UIWindowLevelAlert + 200;
    _win.backgroundColor = [UIColor clearColor];
    _win.userInteractionEnabled = YES;
    _win.passthrough = NO;                       // 框选阶段要吃下全屏拖拽
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    _contentView = [[UIView alloc] initWithFrame:_win.bounds];
    _contentView.backgroundColor = [UIColor clearColor];
    [_win addSubview:_contentView];

    // 镂空遮罩：全屏路径 + 选区路径，evenOdd → 选区内透出底层真实 App 画面
    _dimLayer = [CAShapeLayer layer];
    _dimLayer.fillColor = [UIColor colorWithWhite:0 alpha:0.5].CGColor;
    _dimLayer.fillRule = kCAFillRuleEvenOdd;
    _dimLayer.frame = _win.bounds;
    [_contentView.layer addSublayer:_dimLayer];

    // 蓝色描边
    _borderLayer = [CAShapeLayer layer];
    _borderLayer.strokeColor = [UIColor systemBlueColor].CGColor;
    _borderLayer.lineWidth = 2.0;
    _borderLayer.fillColor = [UIColor clearColor].CGColor;
    _borderLayer.frame = _win.bounds;
    [_contentView.layer addSublayer:_borderLayer];

    // 框选手势：框外 = 重画，框内 = 整体移动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleCropPan:)];
    pan.delegate = self;
    [_contentView addGestureRecognizer:pan];

    [self installToolbar];
    [self installRulers];
    [self installHUD];
    [self setMode:XZMaskModeCrop];
    [self refreshChrome];                        // v4.2：确保按钮栏置顶可见

    _win.hidden = NO;
    NSLog(@"[SN3] mask window A shown");
}

// v4.2：强制刷新底部按钮栏 + 提示条（可见性 / 布局 / 置顶一次做齐）。
// 手势松手、模式切换后都调用，杜绝「框选完成但操作栏不出现」。
- (void)refreshChrome {
    if (!_win || !_toolbar) return;
    _toolbar.hidden = NO;
    _hintLabel.hidden = NO;
    if (_mode == XZMaskModeLong) {
        [self layoutButtons:@[_btnGenerate, _btnReset, _btnBackCrop]];
    } else {
        [self layoutButtons:@[_btnLong, _btnNormal, _btnCancel]];
    }
    [_win bringSubviewToFront:_toolbar];
    [_win bringSubviewToFront:_hintLabel];
    [_win layoutIfNeeded];
}

- (void)dismiss {
    _capturing = NO;
    _idleTicks = 0;
    _mode = XZMaskModeCrop;
    _drag = XZDragNone;
    _hasCrop = NO;
    _cropRect = CGRectZero;

    if (_win) {
        _win.hidden = YES;          // UIWindow 必须先隐藏再从视图树摘除，直接置 nil 会留下可见层
        _win = nil;                 // 置空，交还内存（防 SpringBoard 泄漏 / respring）
    }
    _contentView = nil;
    _dimLayer = nil;
    _borderLayer = nil;

    _toolbar = nil;
    _btnLong = _btnNormal = _btnCancel = nil;
    _btnGenerate = _btnReset = _btnBackCrop = nil;
    _hintLabel = nil;

    _rulerTop = _rulerBottom = nil;
    _topLine = _bottomLine = nil;
    _bandLabel = nil;

    _hud = nil; _hudLabel = nil; _hudDone = nil;

    [[LongShotCapture sharedInstance] reset];
    NSLog(@"[SN3] mask window A destroyed");
}

- (CGRect)cropRect { return _cropRect; }
- (BOOL)hasSelection { return _hasCrop && _cropRect.size.width >= kMinCrop && _cropRect.size.height >= kMinCrop; }

#pragma mark - 底部按钮区

- (void)installToolbar {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];
    CGFloat barH = kToolbarH;
    CGFloat barY = scr.size.height - safe.bottom - barH;
    // v4.2：SpringBoard 里 topWindow 的 safeAreaInsets 不可信，可能返回异常值把整条
    // 底部栏送出屏幕（用户反馈「松手后底部按钮不出现」）。硬钳制进屏幕范围。
    barY = MIN(MAX(barY, 0), scr.size.height - barH);
    NSLog(@"[SN3] toolbar barY=%.0f (screenH=%.0f safeTop=%.1f safeBottom=%.1f)",
          barY, scr.size.height, safe.top, safe.bottom);

    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, barY, scr.size.width, barH)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_win addSubview:_toolbar];
    [_win addInteractiveView:_toolbar];

    // ---- 普通框选模式：长截图 / 正常截图 / 取消 ----
    _btnLong   = [self makeButton:@"长截图"   bg:[UIColor systemYellowColor] action:@selector(onLongShot)];
    _btnNormal = [self makeButton:@"正常截图" bg:[UIColor systemBlueColor]   action:@selector(onNormalShot)];
    _btnCancel = [self makeButton:@"取消"     bg:[UIColor systemGrayColor]   action:@selector(onCancel)];

    // ---- 长截图调节模式：生成长图 / 重置 / 取消 ----
    _btnGenerate = [self makeButton:@"生成长图" bg:[UIColor systemGreenColor] action:@selector(onLongGenerate)];
    _btnReset    = [self makeButton:@"重置"     bg:[UIColor systemOrangeColor] action:@selector(onLongReset)];
    _btnBackCrop = [self makeButton:@"取消"     bg:[UIColor systemGrayColor]   action:@selector(onLongBackToCrop)];

    // 顶部提示条
    _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safe.top + 8, scr.size.width, 24)];
    _hintLabel.textColor = [UIColor whiteColor];
    _hintLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [_win addSubview:_hintLabel];
}

- (UIButton *)makeButton:(NSString *)title bg:(UIColor *)bg action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_toolbar addSubview:b];
    return b;
}

// 把 3 个按钮等宽排进底部栏
- (void)layoutButtons:(NSArray<UIButton *> *)btns {
    CGFloat pad = 16.0, gap = 10.0;
    CGFloat totalW = _toolbar.bounds.size.width - pad * 2;
    CGFloat bw = (totalW - gap * (btns.count - 1)) / MAX(1, (CGFloat)btns.count);
    CGFloat y = (kToolbarH - kButtonH) / 2.0;
    CGFloat x = pad;
    for (UIButton *b in btns) {
        b.frame = CGRectMake(x, y, bw, kButtonH);
        x += bw + gap;
    }
}

#pragma mark - 长截图双标尺

- (UIView *)makeRulerWithTag:(NSInteger)tag color:(UIColor *)color title:(NSString *)title line:(UIView **)lineRef {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIView *r = [[UIView alloc] initWithFrame:CGRectMake(0, 0, scr.size.width, kRulerH)];
    r.backgroundColor = [UIColor clearColor];
    r.tag = tag;

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, kRulerH / 2 - 1, scr.size.width, 2)];
    line.backgroundColor = color;
    [r addSubview:line];
    if (lineRef) *lineRef = line;

    // 左侧把手：既是视觉锚点也是拖动提示
    UILabel *handle = [[UILabel alloc] initWithFrame:CGRectMake(12, 3, 62, 24)];
    handle.text = title;
    handle.textColor = [UIColor whiteColor];
    handle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    handle.textAlignment = NSTextAlignmentCenter;
    handle.backgroundColor = color;
    handle.layer.cornerRadius = 6;
    handle.clipsToBounds = YES;
    [r addSubview:handle];

    // 右侧把手（对称，方便右手拖动）
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(scr.size.width - 30, kRulerH / 2 - 8, 16, 16)];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 8;
    [r addSubview:dot];

    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(handleRulerPan:)];
    [r addGestureRecognizer:p];
    return r;
}

- (void)installRulers {
    UIView *topLine = nil, *bottomLine = nil;
    _rulerTop = [self makeRulerWithTag:101
                                 color:[UIColor systemGreenColor]
                                 title:@"起点"
                                  line:&topLine];
    _rulerBottom = [self makeRulerWithTag:102
                                    color:[UIColor systemRedColor]
                                    title:@"终点"
                                     line:&bottomLine];
    _topLine = topLine;
    _bottomLine = bottomLine;
    _rulerTop.hidden = YES;
    _rulerBottom.hidden = YES;
    [_win addSubview:_rulerTop];
    [_win addSubview:_rulerBottom];
    [_win addInteractiveView:_rulerTop];
    [_win addInteractiveView:_rulerBottom];

    CGRect scr = [UIScreen mainScreen].bounds;
    _bandLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, scr.size.width - 24, 20)];
    _bandLabel.textColor = [UIColor whiteColor];
    _bandLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _bandLabel.textAlignment = NSTextAlignmentCenter;
    _bandLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    _bandLabel.layer.cornerRadius = 6;
    _bandLabel.clipsToBounds = YES;
    _bandLabel.hidden = YES;
    [_win addSubview:_bandLabel];
}

#pragma mark - 采集 HUD

- (void)installHUD {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _hud = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - safe.bottom - kHUDH,
                                                    scr.size.width, kHUDH)];
    _hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    _hud.hidden = YES;
    [_win addSubview:_hud];
    [_win addInteractiveView:_hud];

    _hudLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, scr.size.width - 130, 20)];
    _hudLabel.textColor = [UIColor whiteColor];
    _hudLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_hud addSubview:_hudLabel];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 28, scr.size.width - 130, 18)];
    sub.text = @"请缓慢向上滑动页面，松手后自动拼接";
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    sub.font = [UIFont systemFontOfSize:11];
    [_hud addSubview:sub];

    _hudDone = [UIButton buttonWithType:UIButtonTypeSystem];
    _hudDone.frame = CGRectMake(scr.size.width - 104, 10, 88, 34);
    _hudDone.backgroundColor = [UIColor systemBlueColor];
    _hudDone.layer.cornerRadius = 8;
    [_hudDone setTitle:@"完成拼接" forState:UIControlStateNormal];
    [_hudDone setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _hudDone.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_hudDone addTarget:self action:@selector(onCaptureDone) forControlEvents:UIControlEventTouchUpInside];
    [_hud addSubview:_hudDone];
}

#pragma mark - 模式切换

- (void)setMode:(XZMaskMode)mode {
    _mode = mode;

    BOOL isLong = (mode == XZMaskModeLong);

    _btnLong.hidden   = isLong;
    _btnNormal.hidden = isLong;
    _btnCancel.hidden = isLong;
    _btnGenerate.hidden = !isLong;
    _btnReset.hidden    = !isLong;
    _btnBackCrop.hidden = !isLong;

    _rulerTop.hidden    = !isLong;
    _rulerBottom.hidden = !isLong;
    _bandLabel.hidden   = !isLong;

    if (isLong) {
        [self layoutButtons:@[_btnGenerate, _btnReset, _btnBackCrop]];
        _hintLabel.text = @"左右已锁定 · 上下拖动标尺确定范围 · 页面可照常滑动";
        // 穿透：只有标尺和底部栏吃触摸，其余让位给底层 App（用户才能滑动页面）
        _win.passthrough = YES;
        _contentView.userInteractionEnabled = NO;
        [self lockLongBoundsFromCropRect];
    } else {
        [self layoutButtons:@[_btnLong, _btnNormal, _btnCancel]];
        _hintLabel.text = @"在画面上拖出要截取的区域";
        _win.passthrough = NO;
        _contentView.userInteractionEnabled = YES;
    }
    [self updateMask];
}

// 进入长截图模式：冻结左右边界与宽度，标尺默认 = 当前可视区上下边缘
- (void)lockLongBoundsFromCropRect {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    CGFloat barTop = scr.size.height - safe.bottom - kToolbarH;
    _bandMinY = safe.top;
    _bandMaxY = MAX(_bandMinY + kMinBandH, barTop - 6);
    if (_bandMaxY > scr.size.height - safe.bottom) _bandMaxY = scr.size.height - safe.bottom;

    // 左右锁死：完全沿用刚绘制的矩形选区的 x 与 width，之后禁止左右修改
    _longX = MAX(0, _cropRect.origin.x);
    _longW = _cropRect.size.width;
    if (_longW <= 0) _longW = scr.size.width;
    if (_longX + _longW > scr.size.width) _longW = scr.size.width - _longX;

    // 重置 = 标尺回到可视区上下边缘
    _topY = _bandMinY;
    _bottomY = _bandMaxY;
    [self syncLongUI];
}

// 重置：上下标尺恢复当前屏幕可视区域上下边缘（左右仍锁死）
- (void)resetRulers {
    _topY = _bandMinY;
    _bottomY = _bandMaxY;
    [self syncLongUI];
}

// 把 上/下线 Y 同步到 UI + 遮罩镂空区间
- (void)syncLongUI {
    if (_bottomY - _topY < kMinBandH) _bottomY = MIN(_bandMaxY, _topY + kMinBandH);

    _cropRect = CGRectMake(_longX, _topY, _longW, _bottomY - _topY);
    _hasCrop = YES;
    [self updateMask];
    [self layoutRulers];

    CGFloat h = _bottomY - _topY;
    _bandLabel.text = [NSString stringWithFormat:@"长截图区间：宽 %.0f · 高 %.0f pt", _longW, h];
}

- (void)layoutRulers {
    CGRect scr = [UIScreen mainScreen].bounds;
    _rulerTop.frame    = CGRectMake(0, _topY - kRulerH / 2, scr.size.width, kRulerH);
    _rulerBottom.frame = CGRectMake(0, _bottomY - kRulerH / 2, scr.size.width, kRulerH);
    _topLine.frame    = CGRectMake(0, kRulerH / 2 - 1, scr.size.width, 2);
    _bottomLine.frame = CGRectMake(0, kRulerH / 2 - 1, scr.size.width, 2);
    _bandLabel.frame  = CGRectMake(12, _topY + 12, scr.size.width - 24, 20);
}

#pragma mark - 手势

- (void)handleCropPan:(UIPanGestureRecognizer *)pan {
    if (_mode != XZMaskModeCrop) return;

    CGPoint loc = [pan locationInView:_contentView];
    CGRect b = _contentView.bounds;

    if (pan.state == UIGestureRecognizerStateBegan) {
        if ([self hasSelection] && CGRectContainsPoint(_cropRect, loc)) {
            _drag = XZDragMove;
            _panGrab = CGPointMake(loc.x - _cropRect.origin.x, loc.y - _cropRect.origin.y);
        } else {
            _drag = XZDragDraw;
            _panStart = loc;
            _cropRect = CGRectMake(loc.x, loc.y, 0, 0);
            _hasCrop = YES;
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (_drag == XZDragDraw) {
            // 反向绘制自动矫正：取 min/fabs 归一化成标准 CGRect
            CGFloat x = MIN(_panStart.x, loc.x);
            CGFloat y = MIN(_panStart.y, loc.y);
            CGFloat w = fabs(loc.x - _panStart.x);
            CGFloat h = fabs(loc.y - _panStart.y);
            x = MAX(0, x);
            y = MAX(0, y);
            // 框不能超出屏幕（v4.0 漏了 x/y 偏移，右下角会溢出）
            w = MIN(w, b.size.width - x);
            h = MIN(h, b.size.height - y);
            _cropRect = CGRectMake(x, y, MAX(0, w), MAX(0, h));
        } else if (_drag == XZDragMove) {
            // 整体拖动：宽高不变、不旋转
            CGFloat nx = loc.x - _panGrab.x;
            CGFloat ny = loc.y - _panGrab.y;
            nx = MAX(0, MIN(nx, b.size.width - _cropRect.size.width));
            ny = MAX(0, MIN(ny, b.size.height - _cropRect.size.height));
            _cropRect = CGRectMake(nx, ny, _cropRect.size.width, _cropRect.size.height);
        }
        [self updateMask];
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        _drag = XZDragNone;
        if (_cropRect.size.width < kMinCrop || _cropRect.size.height < kMinCrop) {
            _hasCrop = NO;          // 太小当作没画
            _cropRect = CGRectZero;
        }
        [self updateMask];
        // v4.2：松手立刻刷新底部按钮栏（【长截图|正常截图|取消】必须此时就在）
        [self refreshChrome];
        NSLog(@"[SN3] crop pan ended: rect=(%.0f,%.0f,%.0f,%.0f) valid=%d",
              _cropRect.origin.x, _cropRect.origin.y,
              _cropRect.size.width, _cropRect.size.height, (int)_hasCrop);
    }
}

// 标尺拖动：只允许上下，禁止横向移动
- (void)handleRulerPan:(UIPanGestureRecognizer *)pan {
    if (_mode != XZMaskModeLong) return;

    CGPoint loc = [pan locationInView:_win];

    if (pan.state == UIGestureRecognizerStateBegan) {
        _drag = (pan.view.tag == 101) ? XZDragRulerTop : XZDragRulerBottom;
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged || pan.state == UIGestureRecognizerStateEnded) {
        CGFloat y = MAX(_bandMinY, MIN(loc.y, _bandMaxY));
        if (_drag == XZDragRulerTop) {
            _topY = MAX(_bandMinY, MIN(y, _bottomY - kMinBandH));
        } else if (_drag == XZDragRulerBottom) {
            _bottomY = MIN(_bandMaxY, MAX(y, _topY + kMinBandH));
        }
        [self syncLongUI];
    }
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        _drag = XZDragNone;
    }
}

#pragma mark - 遮罩重绘

- (void)updateMask {
    CGRect full = _contentView ? _contentView.bounds : [UIScreen mainScreen].bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:full];
    if (_hasCrop) {
        [path appendPath:[UIBezierPath bezierPathWithRect:_cropRect]];
    }
    _dimLayer.path = path.CGPath;

    if (_hasCrop) {
        _borderLayer.path = [UIBezierPath bezierPathWithRect:_cropRect].CGPath;
        _borderLayer.hidden = NO;
    } else {
        _borderLayer.hidden = YES;
    }
}

#pragma mark - 按钮动作（普通框选模式）

// 正常截图：隐藏遮罩 → 抓屏 → 按当前完整矩形框裁剪 → 销毁窗口A → 弹窗口B
- (void)onNormalShot {
    if (![self hasSelection]) { [Common toast:@"请先在画面上框选区域"]; return; }
    [self captureShotAndEditWithRect:_cropRect];
}

// 长截图：进入长截图调节子模式（复用窗口A）
- (void)onLongShot {
    if (![self hasSelection]) { [Common toast:@"请先框选区域，确定长截图左右范围"]; return; }
    [self setMode:XZMaskModeLong];
    [Common toast:@"左右已锁定：拖动上下标尺确定范围，滑动页面浏览内容"];
}

// 取消：直接销毁退出
- (void)onCancel {
    [self dismiss];
}

#pragma mark - 按钮动作（长截图调节模式）

// 生成长图
- (void)onLongGenerate {
    if (_bottomY - _topY < 40) { [Common toast:@"长截图区间太短"]; return; }

    [[LongShotCapture sharedInstance] reset];
    _capturing = YES;
    _idleTicks = 0;
    [self enterCapturePhase];
    [self captureTick];
}

// 重置：上下标尺恢复可视区上下边缘（左右仍锁死）
- (void)onLongReset {
    [self resetRulers];
    [Common toast:@"标尺已重置"];
}

// 取消：退出长截图调节，回到普通矩形框选模式
- (void)onLongBackToCrop {
    [[LongShotCapture sharedInstance] reset];
    [self setMode:XZMaskModeCrop];
    [Common toast:@"已回到框选模式"];
}

#pragma mark - 自动分段抓帧（生成长图）

// 采集带：固定左右范围 + 两条标尺划定的 Y 轴垂直区间
- (CGRect)bandScreenRect {
    return CGRectMake(_longX, _topY, _longW, MAX(1, _bottomY - _topY));
}

// 进入采集阶段：隐藏遮罩/描边/标尺/按钮栏（避免暗色被截入），只留底部 HUD
- (void)enterCapturePhase {
    _dimLayer.hidden = YES;
    _borderLayer.hidden = YES;
    _rulerTop.hidden = YES;
    _rulerBottom.hidden = YES;
    _bandLabel.hidden = YES;
    _toolbar.hidden = YES;
    _hintLabel.hidden = YES;
    _hud.hidden = NO;
    _win.passthrough = YES;      // 采集时更要把触摸让给底层 App 供滑动
    _contentView.userInteractionEnabled = NO;
    [self updateHUD];
}

- (void)exitCapturePhase {
    _hud.hidden = YES;
    _hintLabel.hidden = NO;
    _dimLayer.hidden = NO;
    _borderLayer.hidden = NO;
    _toolbar.hidden = NO;
    _contentView.userInteractionEnabled = (_mode == XZMaskModeCrop);
    _win.passthrough = (_mode == XZMaskModeLong);
    [self updateMask];
    if (_mode == XZMaskModeLong) {
        _rulerTop.hidden = NO;
        _rulerBottom.hidden = NO;
        _bandLabel.hidden = NO;
    }
}

- (void)updateHUD {
    NSInteger n = [[LongShotCapture sharedInstance] frameCount];
    CGFloat est = [[LongShotCapture sharedInstance] estimatedHeight];
    _hudLabel.text = [NSString stringWithFormat:@"已采集 %ld 帧 · 累计约 %.0f pt", (long)n, est];
}

- (void)captureTick {
    if (!_capturing || !_win) return;

    BOOL changed = NO;
    @try {
        // ① 遮罩此刻已经隐藏，抓到的是干净的真实屏幕
        UIImage *screen = [ImageUtils captureScreen];
        if (screen) {
            // v4.2：采集带同样先转换到屏幕全局坐标再裁剪
            CGRect band = [self bandScreenRect];
            if (_contentView) band = [_contentView convertRect:band toView:nil];
            UIImage *frame = [ImageUtils cropImage:screen screenRect:band];
            if (frame) {
                // 与上一帧比对，无位移（用户没滑动）则丢弃，避免重复帧
                changed = [[LongShotCapture sharedInstance] addFrame:frame];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[SN3] capture tick failed: %@ %@", e.name, e.reason);
    }

    if (changed) _idleTicks = 0; else _idleTicks++;
    [self updateHUD];

    BOOL overLimit = [[LongShotCapture sharedInstance] isOverHeightLimit];
    if (_idleTicks >= kIdleLimit || overLimit) {
        NSLog(@"[SN3] capture finished: idle=%ld overLimit=%d", (long)_idleTicks, overLimit);
        [self finishCapture];
        return;
    }

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCaptureInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ws captureTick];
    });
}

- (void)onCaptureDone {
    [self finishCapture];
}

- (void)finishCapture {
    if (!_capturing) return;
    _capturing = NO;

    if ([[LongShotCapture sharedInstance] frameCount] < 2) {
        [self exitCapturePhase];
        [Common toast:@"未检测到页面滑动，请滑动内容后再点生成长图"];
        return;
    }

    [Common toast:@"正在拼接长图..."];
    __weak typeof(self) ws = self;
    [[LongShotCapture sharedInstance] stitchWithCompletion:^(UIImage *result) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        if (result) {
            // ③ 拼接完成销毁窗口A  ④ 唤起窗口B，弹出两排编辑工具栏
            [ss exitCapturePhase];
            [ss dismiss];
            [EditToolbarWindow showWithImage:result];
        } else {
            [Common toast:@"拼接失败，请重试"];
            [ss exitCapturePhase];
            [ss setMode:XZMaskModeLong];
        }
    }];
}

#pragma mark - 抓屏 + 裁剪 公共路径

- (void)setWindowHidden:(BOOL)hidden {
    _win.hidden = hidden;
}

// 临时隐藏遮罩 → 抓屏 → 按 rect 裁剪 → 销毁窗口A → 弹窗口B
- (void)captureShotAndEditWithRect:(CGRect)rect {
    if (!_win) return;

    // v4.2：显式把选区从 contentView 局部坐标转换到屏幕全局坐标再裁剪。
    // contentView 全屏在原点时是恒等变换，但这一步保证 UI 坐标系永远与截图坐标系对齐
    //（用户反馈的「只截到左上角」一半根因就在坐标空间没显式转换）。
    CGRect screenRect = rect;
    if (_contentView) screenRect = [_contentView convertRect:rect toView:nil];

    [self setWindowHidden:YES];                 // ① 关键：先隐藏遮罩，避免暗色被截入

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;

        UIImage *screen = [ImageUtils captureScreen];
        [ss setWindowHidden:NO];

        if (!screen) { [Common toast:@"截图失败"]; return; }
        NSLog(@"[SN3] normal shot: screenRect=(%.0f,%.0f,%.0f,%.0f)",
              screenRect.origin.x, screenRect.origin.y,
              screenRect.size.width, screenRect.size.height);
        UIImage *cropped = [ImageUtils cropImage:screen screenRect:screenRect];
        if (!cropped) { [Common toast:@"裁剪失败"]; return; }

        [ss dismiss];                            // ② 销毁窗口A
        [EditToolbarWindow showWithImage:cropped]; // ③ 唤起窗口B：两排工具栏
    });
}

@end
