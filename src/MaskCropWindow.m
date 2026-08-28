//
//  MaskCropWindow.m — 窗口A：遮罩镂空框选 + 长截图实时预览框（超级截图 v4.6）
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.6 交互重设计（依据用户实测反馈）：
//    · 局部截图 = 默认模式：
//        - 进入遮罩即局部截图模式，直接拖框；
//        - 松手【立即】裁出选区 → 销毁窗口A → 弹窗口B 两排编辑工具栏；
//        - 不再需要「再点一次截图按钮」确认（去掉底部确认栏）。
//        - 顶部保留三个小入口：【正常截图】【长截图】【取消】。
//    · 正常截图：仿系统电源+音量键，截整屏直接存相册「SN3截图」，不弹编辑（原生行为）。
//    · 长截图 = 独立实时预览框：
//        - 点【长截图】直接弹出全屏宽「截取框」；
//        - 框内触摸穿透，底层 App 可上下滑动，实时预览长截图内容；
//        - 框外只有 2 个按钮：【生成长图】【取消】；
//        - 取消上下标尺、取消手动「采集下一屏」：进入即启动自动抓帧定时器（~0.4s），
//          框内滑动期间逐帧采集、重叠去重，松手静止即停采；看到满意的起止内容后点【生成长图】。
//    · 抓屏前必隐藏边框/遮罩，绝不把暗色/控件截进图片。
//    · 退出时完整销毁窗口并置空，防 SpringBoard 泄漏。
//
//  ────────────────────────────────────────────────────────────────────────

#import "MaskCropWindow.h"
#import "XZPassThroughWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "EditToolbarWindow.h"
#import "LongShotCapture.h"

// ---------- 布局常量（pt） ----------
static const CGFloat kTopBarH  = 44.0;   // 顶部小入口栏高
static const CGFloat kButtonH  = 46.0;   // 按钮高
static const CGFloat kMinCrop  = 16.0;   // 有效选区最小边长

// 长截图截取框留白
static const CGFloat kFrameTopInset  = 64.0;   // 框顶距安全区上沿
static const CGFloat kFrameSideInset = 6.0;    // 框左右留白（≈全屏宽）
static const CGFloat kFrameBotInset  = 96.0;   // 框底距按钮区

typedef NS_ENUM(NSInteger, XZDragTarget) {
    XZDragNone       = 0,
    XZDragDraw,          // 框选：画新矩形
    XZDragMove,          // 框选：整体拖动（宽高不变、不旋转）
};

@interface MaskCropWindow () <UIGestureRecognizerDelegate>
- (void)setWindowHidden:(BOOL)hidden;
- (void)captureShotAndEditWithRect:(CGRect)rect;   // 局部截图 → 窗口B
- (void)captureFullScreenAndSave;                  // 正常截图 → 相册（无编辑）
- (void)refreshChrome;                             // 强制刷新 UI
@end

@implementation MaskCropWindow {
    XZPassThroughWindow *_win;      // 窗口A（可穿透）
    UIView      *_contentView;      // 全屏容器（承载遮罩/边框图层）
    CAShapeLayer *_dimLayer;        // 半透明黑遮罩（evenOdd 镂空）
    CAShapeLayer *_borderLayer;     // 描边（局部选区 / 长截图框）

    // ---- 顶部小入口栏（框选模式） ----
    UIView   *_topBar;
    UIButton *_btnTopNormal;        // 正常截图
    UIButton *_btnTopLong;          // 长截图
    UIButton *_btnTopCancel;        // 取消
    UILabel  *_hintLabel;           // 提示

    // ---- 长截图：框外 2 按钮 + 计数 ----
    UIButton *_btnGen;              // 生成长图
    UIButton *_btnLongCancel;       // 取消
    UILabel  *_longCountLabel;      // 已采集帧数

    // ---- 状态 ----
    XZMaskMode   _mode;
    XZDragTarget _drag;
    CGRect  _cropRect;              // 当前选区（屏幕点坐标）
    BOOL    _hasCrop;
    CGPoint _panStart;              // 画框起点
    CGPoint _panGrab;               // 拖动时手指在框内的相对偏移

    CGRect   _longFrameRect;        // 长截图截取框（窗口/屏幕坐标）
    NSTimer *_captureTimer;         // 自动抓帧定时器
    BOOL     _capturing;            // 抓帧防重入
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

    // 描边
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

    [self installTopBar];
    [self installLongControls];
    [self setMode:XZMaskModeCrop];
    [self refreshChrome];

    _win.hidden = NO;
    [Common toast:@"拖出要截取的区域，松手即弹出编辑菜单"];
    NSLog(@"[SN3] mask window A shown (v4.6)");
}

- (void)refreshChrome {
    if (!_win) return;

    if (_mode == XZMaskModeCrop) {
        _topBar.hidden        = NO;
        _hintLabel.hidden     = NO;
        _btnGen.hidden        = YES;
        _btnLongCancel.hidden = YES;
        _longCountLabel.hidden = YES;
        _win.passthrough      = NO;              // 框选阶段吃下全屏拖拽
        _contentView.userInteractionEnabled = YES;
        _borderLayer.hidden = !_hasCrop;
        [self updateMask];
        [_win bringSubviewToFront:_topBar];
        [_win bringSubviewToFront:_hintLabel];
    } else {
        _topBar.hidden        = YES;
        _hintLabel.hidden     = YES;
        _btnGen.hidden        = NO;
        _btnLongCancel.hidden = NO;
        _longCountLabel.hidden = NO;
        _win.passthrough      = YES;             // 长截图：框内穿透、框外吞咽
        _win.passRect        = _longFrameRect;   // 框内坐标 → 穿透给 App
        _contentView.userInteractionEnabled = NO; // 不拦截手势，交给 hitTest 决定
        _borderLayer.hidden = NO;
        [self updateMask];
        [self updateLongCounter];
        [_win bringSubviewToFront:_btnGen];
        [_win bringSubviewToFront:_btnLongCancel];
        [_win bringSubviewToFront:_longCountLabel];
    }
    [_win layoutIfNeeded];
}

- (void)dismiss {
    _mode = XZMaskModeCrop;
    _drag = XZDragNone;
    _hasCrop = NO;
    _cropRect = CGRectZero;
    _capturing = NO;

    if (_captureTimer) { [_captureTimer invalidate]; _captureTimer = nil; }

    if (_win) {
        _win.hidden = YES;          // UIWindow 必须先隐藏再从视图树摘除，直接置 nil 会留下可见层
        _win = nil;                 // 置空，交还内存（防 SpringBoard 泄漏 / respring）
    }
    _contentView = nil;
    _dimLayer = nil;
    _borderLayer = nil;

    _topBar = nil;
    _btnTopNormal = _btnTopLong = _btnTopCancel = nil;
    _hintLabel = nil;
    _btnGen = _btnLongCancel = nil;
    _longCountLabel = nil;

    [[LongShotCapture sharedInstance] reset];
    NSLog(@"[SN3] mask window A destroyed");
}

- (CGRect)cropRect { return _cropRect; }
- (BOOL)hasSelection { return _hasCrop && _cropRect.size.width >= kMinCrop && _cropRect.size.height >= kMinCrop; }

#pragma mark - 顶部小入口栏 + 长截图按钮

- (UIButton *)makeBarButton:(NSString *)title bg:(UIColor *)bg action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.8;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:b];
    [_win addInteractiveView:b];
    return b;
}

- (void)installTopBar {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];
    CGFloat y = safe.top;
    _topBar = [[UIView alloc] initWithFrame:CGRectMake(0, y, scr.size.width, kTopBarH)];
    _topBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_win addSubview:_topBar];
    [_win addInteractiveView:_topBar];

    _btnTopNormal = [self makeBarButton:@"正常截图" bg:[UIColor systemBlueColor]   action:@selector(onNormalShot)];
    _btnTopLong   = [self makeBarButton:@"长截图"   bg:[UIColor systemYellowColor] action:@selector(onLongShot)];
    _btnTopCancel = [self makeBarButton:@"取消"     bg:[UIColor systemGrayColor]   action:@selector(onCancel)];
    [self layoutTopBar];

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, y + kTopBarH, scr.size.width, 22)];
    _hintLabel.textColor = [UIColor whiteColor];
    _hintLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    _hintLabel.text = @"拖框选区域，松手即编辑 · 顶部可切「正常截图/长截图」";
    [_win addSubview:_hintLabel];
    [_win addInteractiveView:_hintLabel];
}

- (void)layoutTopBar {
    CGFloat pad = 10.0, gap = 8.0;
    CGFloat totalW = _topBar.bounds.size.width - pad * 2;
    CGFloat bw = (totalW - gap * 2) / 3.0;
    CGFloat y = (kTopBarH - (kButtonH - 8)) / 2.0;
    CGFloat x = pad;
    for (UIButton *b in @[_btnTopNormal, _btnTopLong, _btnTopCancel]) {
        b.frame = CGRectMake(x, y, bw, kButtonH - 8);
        x += bw + gap;
    }
}

- (void)installLongControls {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    // 长截图截取框（全屏宽，留上下边距给按钮/提示）
    CGFloat top = safe.top + kFrameTopInset;
    CGFloat bot = safe.bottom + kFrameBotInset;
    _longFrameRect = CGRectMake(kFrameSideInset, top,
                                scr.size.width - 2 * kFrameSideInset,
                                MAX(40, scr.size.height - top - bot));

    // 框外两按钮：生成长图 / 取消
    CGFloat by = scr.size.height - safe.bottom - 84;
    CGFloat pad = 16.0, gap = 12.0;
    CGFloat bw = (scr.size.width - pad * 2 - gap) / 2.0;
    _btnGen = [self makeBarButton:@"生成长图"
                                bg:[UIColor systemGreenColor]
                              action:@selector(onLongGenerate)];
    _btnGen.frame = CGRectMake(pad, by, bw, kButtonH);
    _btnLongCancel = [self makeBarButton:@"取消"
                                      bg:[UIColor systemGrayColor]
                                    action:@selector(onLongCancel)];
    _btnLongCancel.frame = CGRectMake(pad + bw + gap, by, bw, kButtonH);

    // 计数提示（框底内）
    _longCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, _longFrameRect.origin.y + _longFrameRect.size.height - 24,
                                                                scr.size.width, 20)];
    _longCountLabel.textColor = [UIColor whiteColor];
    _longCountLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _longCountLabel.textAlignment = NSTextAlignmentCenter;
    _longCountLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _longCountLabel.text = @"已采集 0 屏";
    [_win addSubview:_longCountLabel];
    [_win addInteractiveView:_longCountLabel];
}

#pragma mark - 模式切换

- (void)setMode:(XZMaskMode)mode {
    _mode = mode;
    if (mode == XZMaskModeLong) {
        // 进入长截图：显示截取框 + 启动自动抓帧
        [self startCaptureTimer];
        [self refreshChrome];
        [Common toast:@"长截图：框内滑动页面预览，点「生成长图」"];
    } else {
        if (_captureTimer) { [_captureTimer invalidate]; _captureTimer = nil; }
        [self refreshChrome];
    }
}

- (void)startCaptureTimer {
    if (_captureTimer) [_captureTimer invalidate];
    _captureTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                    target:self
                                                  selector:@selector(longCaptureTick)
                                                  userInfo:nil
                                                   repeats:YES];
    // 立即采一帧（初始画面）
    [self longCaptureTick];
}

- (void)updateLongCounter {
    NSInteger n = [[LongShotCapture sharedInstance] frameCount];
    CGFloat est = [[LongShotCapture sharedInstance] estimatedHeight];
    _longCountLabel.text = [NSString stringWithFormat:@"已采集 %ld 屏 · 预计长图约 %.0f pt", (long)n, est];
}

#pragma mark - 手势（框选）

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
            CGFloat x = MIN(_panStart.x, loc.x);
            CGFloat y = MIN(_panStart.y, loc.y);
            CGFloat w = fabs(loc.x - _panStart.x);
            CGFloat h = fabs(loc.y - _panStart.y);
            x = MAX(0, x); y = MAX(0, y);
            w = MIN(w, b.size.width - x);
            h = MIN(h, b.size.height - y);
            _cropRect = CGRectMake(x, y, MAX(0, w), MAX(0, h));
        } else if (_drag == XZDragMove) {
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
            _hasCrop = NO;
            _cropRect = CGRectZero;
            [self updateMask];
            return;
        }
        [self updateMask];
        // v4.6：松手【立即】进入编辑，不再需要二次确认
        NSLog(@"[SN3] crop pan ended -> 立即唤起窗口B 编辑 rect=(%.0f,%.0f,%.0f,%.0f)",
              _cropRect.origin.x, _cropRect.origin.y,
              _cropRect.size.width, _cropRect.size.height);
        [self captureShotAndEditWithRect:_cropRect];
    }
}

#pragma mark - 遮罩重绘

- (void)updateMask {
    CGRect full = _contentView ? _contentView.bounds : [UIScreen mainScreen].bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:full];
    CGRect hole = (_mode == XZMaskModeLong) ? _longFrameRect : (_hasCrop ? _cropRect : CGRectZero);
    if (!CGRectIsEmpty(hole)) {
        [path appendPath:[UIBezierPath bezierPathWithRect:hole]];
    }
    _dimLayer.path = path.CGPath;

    if (!CGRectIsEmpty(hole)) {
        _borderLayer.path = [UIBezierPath bezierPathWithRect:hole].CGPath;
        _borderLayer.hidden = NO;
    } else {
        _borderLayer.hidden = YES;
    }
}

#pragma mark - 按钮动作（框选模式）

// 正常截图：仿系统电源+音量键，截整屏直接存相册，不弹编辑工具栏
- (void)onNormalShot {
    [self captureFullScreenAndSave];
}

- (void)onCancel {
    [self dismiss];
}

#pragma mark - 按钮动作（长截图）

// 长截图：直接弹全屏宽截取框（取消先画矩形、取消标尺）
- (void)onLongShot {
    [self setMode:XZMaskModeLong];
}

// 生成长图：拼接 → 销毁窗口A → 弹窗口B 两排编辑工具栏
- (void)onLongGenerate {
    if ([[LongShotCapture sharedInstance] frameCount] < 1) {
        [Common toast:@"请先在框内滑动页面采集内容"];
        return;
    }
    [Common toast:@"正在拼接长图..."];
    if (_captureTimer) { [_captureTimer invalidate]; _captureTimer = nil; }
    __weak typeof(self) ws = self;
    [[LongShotCapture sharedInstance] stitchWithCompletion:^(UIImage *result) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        UIImage *img = result ?: [[LongShotCapture sharedInstance] stitchFallback];
        [ss dismiss];
        if (img) {
            [EditToolbarWindow showWithImage:img];
        } else {
            [Common toast:@"拼接失败，请重试"];
        }
    }];
}

- (void)onLongCancel {
    [self dismiss];
}

// 自动抓帧：隐藏边框 → 抓屏 → 按截取框裁剪 → 加入长截图队列（重叠去重）
- (void)longCaptureTick {
    if (!_win || _mode != XZMaskModeLong || _capturing) return;
    _capturing = YES;

    BOOL borderHidden = _borderLayer.hidden;
    _borderLayer.hidden = YES;                 // 抓帧时去掉边框，避免被截进长图

    UIImage *screen = [ImageUtils captureScreen];
    _borderLayer.hidden = borderHidden;

    if (!screen) { _capturing = NO; return; }
    UIImage *tile = [ImageUtils cropImage:screen screenRect:_longFrameRect];
    if (tile) {
        [[LongShotCapture sharedInstance] addFrame:tile];
        [self updateLongCounter];
    }
    _capturing = NO;
}

#pragma mark - 抓屏 + 裁剪 公共路径

- (void)setWindowHidden:(BOOL)hidden {
    _win.hidden = hidden;
}

// 临时隐藏遮罩 → 抓屏 → 按 rect 裁剪 → 销毁窗口A → 弹窗口B（局部截图）
- (void)captureShotAndEditWithRect:(CGRect)rect {
    if (!_win) return;

    CGRect screenRect = rect;
    if (_contentView) screenRect = [_contentView convertRect:rect toView:nil];
    NSLog(@"[SN3] free crop requested screenRect=(%.0f,%.0f,%.0f,%.0f)",
          screenRect.origin.x, screenRect.origin.y, screenRect.size.width, screenRect.size.height);

    [self setWindowHidden:YES];                 // ① 关键：先隐藏遮罩，避免暗色被截入

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;

        UIImage *screen = [ImageUtils captureScreen];
        if (!screen) {
            [ss dismiss];
            [Common toast:@"截图失败，请重试"];
            return;
        }

        UIImage *result = [ImageUtils cropImage:screen screenRect:screenRect];
        if (!result) {
            NSLog(@"[SN3] crop failed, fallback to full-screen image");
            result = screen;
            [Common toast:@"选区裁剪失败，已用整屏图"];
        }

        [ss dismiss];                            // ② 销毁窗口A
        [EditToolbarWindow showWithImage:result]; // ③ 唤起窗口B：两排编辑工具栏（必弹）
    });
}

// 正常截图：整屏 → 保存到相册「SN3截图」→ 直接结束（不弹编辑，仿原生）
- (void)captureFullScreenAndSave {
    if (!_win) return;
    [self setWindowHidden:YES];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        UIImage *screen = [ImageUtils captureScreen];
        [ss dismiss];                            // 先销毁窗口A
        if (!screen) { [Common toast:@"截图失败"]; return; }
        [ImageUtils saveToCustomAlbum:screen completion:^(BOOL ok, NSError *e) {
            [Common toast: ok ? @"已截图，已保存到相册「SN3截图」" : @"保存失败，请检查相册权限"];
        }];
    });
}

@end
