//
//  MaskCropWindow.m — 窗口A：遮罩镂空框选 + 长截图悬浮调节面板（超级截图 v4.5）
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.5 交互重设计（依据用户实测反馈）：
//    · 三种截图入口彻底分离，互不打扰：
//        - 正常截图：仿系统电源+音量键，截【整屏全屏】，直接保存到相册「SN3截图」，
//                   不弹任何编辑工具栏（原生行为，截图完即结束）。
//        - 局部截图：先拖框选区域，点「局部截图」→ 销毁窗口A → 弹窗口B 两排编辑工具栏。
//        - 长截图：点「长截图」直接弹出【独立悬浮在屏幕中间的调节面板】，不再要求先画矩形；
//                  宽度恒为整机全屏宽；面板里上下两个滑杆决定截取的垂直起始/结束范围；
//                  用户滑动底层 App 后点「采集下一屏」逐帧采集，点「生成长图」拼接 → 窗口B。
//    · 抓屏前必隐藏遮罩/面板，绝不把暗色/控件截进图片。
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
static const CGFloat kToolbarH  = 96.0;   // 底部按钮区总高（含安全区外留白）
static const CGFloat kButtonH   = 46.0;   // 按钮高
static const CGFloat kMinCrop   = 16.0;   // 有效选区最小边长

// 长截图悬浮面板
static const CGFloat kPanelW    = 300.0;
static const CGFloat kPanelH    = 396.0;
static const CGFloat kPanelBtnH = 42.0;

typedef NS_ENUM(NSInteger, XZDragTarget) {
    XZDragNone       = 0,
    XZDragDraw,          // 框选：画新矩形
    XZDragMove,          // 框选：整体拖动（宽高不变、不旋转）
};

@interface MaskCropWindow () <UIGestureRecognizerDelegate>
- (void)setWindowHidden:(BOOL)hidden;
- (void)captureShotAndEditWithRect:(CGRect)rect;   // 局部截图 → 窗口B
- (void)captureFullScreenAndSave;                  // 正常截图 → 相册（无编辑）
- (void)refreshChrome;                             // 强制刷新底部按钮栏
@end

@implementation MaskCropWindow {
    XZPassThroughWindow *_win;      // 窗口A（可穿透）
    UIView      *_contentView;      // 全屏容器
    CAShapeLayer *_dimLayer;        // 半透明黑遮罩（evenOdd 镂空）
    CAShapeLayer *_borderLayer;     // 蓝色描边

    // ---- 底部按钮区（框选模式） ----
    UIView   *_toolbar;
    UIButton *_btnLong;             // 长截图
    UIButton *_btnNormal;           // 正常截图
    UIButton *_btnCrop;             // 局部截图（v4.5 新增）
    UIButton *_btnCancel;           // 取消
    UILabel  *_hintLabel;           // 顶部提示

    // ---- 长截图悬浮面板（独立窗口，居中） ----
    UIView      *_longPanel;
    UISlider    *_startSlider;      // 起始 Y（0~1）
    UISlider    *_endSlider;        // 结束 Y（0~1）
    UILabel     *_bandLabel;        // 区间提示
    UILabel     *_longCountLabel;   // 已采集帧数
    UIButton    *_btnCaptureFrame;  // 采集下一屏
    UIButton    *_btnGenerate;      // 生成长图
    UIButton    *_btnLongCancel;    // 取消

    // ---- 状态 ----
    XZMaskMode   _mode;
    XZDragTarget _drag;
    CGRect  _cropRect;              // 当前选区（屏幕点坐标）
    BOOL    _hasCrop;
    CGPoint _panStart;              // 画框起点
    CGPoint _panGrab;               // 拖动时手指在框内的相对偏移

    // 长截图锁定量（v4.5：宽度恒为全屏宽，由滑杆决定上下范围）
    CGFloat _longX;                 // 锁死左边界（恒 0）
    CGFloat _longW;                 // 锁死宽度（恒全屏宽）
    CGFloat _topY;                  // 起始 Y（点）
    CGFloat _bottomY;               // 结束 Y（点）
    CGFloat _startRatio;            // 起始比例 0~1
    CGFloat _endRatio;              // 结束比例 0~1
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
        _startRatio = 0.0;
        _endRatio = 1.0;
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
    [self installLongPanel];
    [self setMode:XZMaskModeCrop];
    [self refreshChrome];

    _win.hidden = NO;
    NSLog(@"[SN3] mask window A shown");
}

- (void)refreshChrome {
    if (!_win || !_toolbar) return;
    if (_mode == XZMaskModeCrop) {
        _toolbar.hidden = NO;
        _hintLabel.hidden = NO;
        _longPanel.hidden = YES;
        [self layoutButtons:@[_btnLong, _btnNormal, _btnCrop, _btnCancel]];
        [_win bringSubviewToFront:_toolbar];
        [_win bringSubviewToFront:_hintLabel];
        [_win layoutIfNeeded];
    }
}

- (void)dismiss {
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
    _btnLong = _btnNormal = _btnCrop = _btnCancel = nil;
    _hintLabel = nil;

    _longPanel = nil;
    _startSlider = _endSlider = nil;
    _bandLabel = nil;
    _longCountLabel = nil;
    _btnCaptureFrame = _btnGenerate = _btnLongCancel = nil;

    [[LongShotCapture sharedInstance] reset];
    NSLog(@"[SN3] mask window A destroyed");
}

- (CGRect)cropRect { return _cropRect; }
- (BOOL)hasSelection { return _hasCrop && _cropRect.size.width >= kMinCrop && _cropRect.size.height >= kMinCrop; }

#pragma mark - 底部按钮区（框选模式）

- (void)installToolbar {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];
    CGFloat barH = kToolbarH;
    CGFloat barY = scr.size.height - safe.bottom - barH;
    barY = MIN(MAX(barY, 0), scr.size.height - barH);   // 硬钳制进屏幕，避免 safeArea 异常送出屏

    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, barY, scr.size.width, barH)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [_win addSubview:_toolbar];
    [_win addInteractiveView:_toolbar];

    // 框选模式：长截图 / 正常截图 / 局部截图 / 取消
    _btnLong   = [self makeButton:@"长截图"   bg:[UIColor systemYellowColor] action:@selector(onLongShot)];
    _btnNormal = [self makeButton:@"正常截图" bg:[UIColor systemBlueColor]   action:@selector(onNormalShot)];
    _btnCrop   = [self makeButton:@"局部截图" bg:[UIColor systemTealColor]   action:@selector(onFreeCrop)];
    _btnCancel = [self makeButton:@"取消"     bg:[UIColor systemGrayColor]   action:@selector(onCancel)];

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safe.top + 8, scr.size.width, 24)];
    _hintLabel.textColor = [UIColor whiteColor];
    _hintLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [_win addSubview:_hintLabel];
    [_win addInteractiveView:_hintLabel];
}

- (UIButton *)makeButton:(NSString *)title bg:(UIColor *)bg action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.8;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_toolbar addSubview:b];
    return b;
}

// 把 N 个按钮等宽排进底部栏
- (void)layoutButtons:(NSArray<UIButton *> *)btns {
    CGFloat pad = 12.0, gap = 8.0;
    CGFloat totalW = _toolbar.bounds.size.width - pad * 2;
    CGFloat bw = (totalW - gap * (btns.count - 1)) / MAX(1, (CGFloat)btns.count);
    CGFloat y = (kToolbarH - kButtonH) / 2.0;
    CGFloat x = pad;
    for (UIButton *b in btns) {
        b.frame = CGRectMake(x, y, bw, kButtonH);
        x += bw + gap;
    }
}

#pragma mark - 长截图悬浮面板

- (void)installLongPanel {
    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat px = (scr.size.width - kPanelW) / 2.0;
    CGFloat py = (scr.size.height - kPanelH) / 2.0;
    _longPanel = [[UIView alloc] initWithFrame:CGRectMake(px, py, kPanelW, kPanelH)];
    _longPanel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    _longPanel.layer.cornerRadius = 16;
    _longPanel.clipsToBounds = YES;
    _longPanel.hidden = YES;
    [_win addSubview:_longPanel];
    [_win addInteractiveView:_longPanel];          // 面板内所有子视图（按钮/滑杆）一并接收触摸

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, kPanelW, 26)];
    title.text = @"长截图（全屏宽）";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [_longPanel addSubview:title];

    // 起点滑杆
    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(16, 52, kPanelW - 32, 18)];
    sl.text = @"起始位置"; sl.textColor = [UIColor systemGreenColor];
    sl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_longPanel addSubview:sl];
    _startSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, 74, kPanelW - 32, 30)];
    _startSlider.minimumValue = 0; _startSlider.maximumValue = 1; _startSlider.value = 0;
    _startSlider.minimumTrackTintColor = [UIColor systemGreenColor];
    [_startSlider addTarget:self action:@selector(onSlider:) forControlEvents:UIControlEventValueChanged];
    [_longPanel addSubview:_startSlider];

    // 终点滑杆
    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(16, 116, kPanelW - 32, 18)];
    el.text = @"结束位置"; el.textColor = [UIColor systemRedColor];
    el.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_longPanel addSubview:el];
    _endSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, 138, kPanelW - 32, 30)];
    _endSlider.minimumValue = 0; _endSlider.maximumValue = 1; _endSlider.value = 1;
    _endSlider.minimumTrackTintColor = [UIColor systemRedColor];
    [_endSlider addTarget:self action:@selector(onSlider:) forControlEvents:UIControlEventValueChanged];
    [_longPanel addSubview:_endSlider];

    // 区间提示
    _bandLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 178, kPanelW - 32, 20)];
    _bandLabel.textColor = [UIColor whiteColor];
    _bandLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _bandLabel.textAlignment = NSTextAlignmentCenter;
    [_longPanel addSubview:_bandLabel];

    // 已采集帧数
    _longCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 202, kPanelW - 32, 20)];
    _longCountLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _longCountLabel.font = [UIFont systemFontOfSize:12];
    _longCountLabel.textAlignment = NSTextAlignmentCenter;
    _longCountLabel.text = @"已采集 0 帧";
    [_longPanel addSubview:_longCountLabel];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 226, kPanelW - 32, 32)];
    tip.text = @"滑动底层页面换内容，点「采集下一屏」逐帧抓取";
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    tip.font = [UIFont systemFontOfSize:11];
    tip.numberOfLines = 2;
    tip.textAlignment = NSTextAlignmentCenter;
    [_longPanel addSubview:tip];

    // 按钮行：采集下一屏 / 生成长图
    CGFloat rowY = 296, bw = (kPanelW - 32 - 8) / 2.0;
    _btnCaptureFrame = [self panelButton:@"采集下一屏" bg:[UIColor systemBlueColor]
                                    frame:CGRectMake(16, rowY, bw, kPanelBtnH)
                                   action:@selector(onLongCaptureFrame)];
    _btnGenerate = [self panelButton:@"生成长图" bg:[UIColor systemGreenColor]
                                frame:CGRectMake(16 + bw + 8, rowY, bw, kPanelBtnH)
                               action:@selector(onLongGenerate)];
    // 取消（整行）
    _btnLongCancel = [self panelButton:@"取消" bg:[UIColor systemGrayColor]
                                  frame:CGRectMake(16, rowY + kPanelBtnH + 10, kPanelW - 32, kPanelBtnH)
                                 action:@selector(onLongCancel)];
}

- (UIButton *)panelButton:(NSString *)title bg:(UIColor *)bg frame:(CGRect)f action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_longPanel addSubview:b];
    return b;
}

#pragma mark - 模式切换

- (void)setMode:(XZMaskMode)mode {
    _mode = mode;
    BOOL isLong = (mode == XZMaskModeLong);

    _btnLong.hidden   = isLong;
    _btnNormal.hidden = isLong;
    _btnCrop.hidden   = isLong;
    _btnCancel.hidden = isLong;

    if (isLong) {
        // 长截图：隐藏遮罩与底部栏，弹出悬浮面板；触摸穿透（面板外区域让位给底层 App 滑动）
        _dimLayer.hidden = YES;
        _borderLayer.hidden = YES;
        _toolbar.hidden = YES;
        _hintLabel.hidden = YES;
        _longPanel.hidden = NO;
        _win.passthrough = YES;
        _contentView.userInteractionEnabled = NO;
        [self setupLongDefaults];
        [self updateLongCounter];
        [_win bringSubviewToFront:_longPanel];
    } else {
        // 框选：显示遮罩与底部栏，关闭穿透
        _dimLayer.hidden = NO;
        _borderLayer.hidden = !_hasCrop;
        _toolbar.hidden = NO;
        _hintLabel.hidden = NO;
        _longPanel.hidden = YES;
        _win.passthrough = NO;
        _contentView.userInteractionEnabled = YES;
        _hintLabel.text = @"拖框→点「局部截图」编辑；「正常截图」=整屏直接保存；「长截图」=全屏长图";
        [self updateMask];
    }
}

// 进入长截图：宽度恒为全屏宽，上下由滑杆决定
- (void)setupLongDefaults {
    CGRect scr = [UIScreen mainScreen].bounds;
    _longX = 0;
    _longW = scr.size.width;
    _startRatio = 0.0;
    _endRatio = 1.0;
    _startSlider.value = 0;
    _endSlider.value = 1;
    [self syncLongBand];
}

- (void)onSlider:(UISlider *)s {
    CGFloat v = s.value;
    if (s == _startSlider) {
        _startRatio = MIN(v, _endRatio - 0.05);
        _startSlider.value = _startRatio;
    } else {
        _endRatio = MAX(v, _startRatio + 0.05);
        _endSlider.value = _endRatio;
    }
    [self syncLongBand];
}

- (void)syncLongBand {
    CGRect scr = [UIScreen mainScreen].bounds;
    _topY = _startRatio * scr.size.height;
    _bottomY = _endRatio * scr.size.height;
    [self updateBandLabel];
}

- (void)updateBandLabel {
    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat h = (_endRatio - _startRatio) * scr.size.height;
    _bandLabel.text = [NSString stringWithFormat:@"截取区间：全屏宽 · 高约 %.0f pt", h];
}

- (void)updateLongCounter {
    NSInteger n = [[LongShotCapture sharedInstance] frameCount];
    CGFloat est = [[LongShotCapture sharedInstance] estimatedHeight];
    _longCountLabel.text = [NSString stringWithFormat:@"已采集 %ld 帧 · 预计长图约 %.0f pt", (long)n, est];
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
        }
        [self updateMask];
        [self refreshChrome];
        NSLog(@"[SN3] crop pan ended: rect=(%.0f,%.0f,%.0f,%.0f) valid=%d",
              _cropRect.origin.x, _cropRect.origin.y,
              _cropRect.size.width, _cropRect.size.height, (int)_hasCrop);
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

#pragma mark - 按钮动作（框选模式）

// 正常截图：仿系统电源+音量键，截整屏直接存相册，不弹编辑工具栏
- (void)onNormalShot {
    [self captureFullScreenAndSave];
}

// 局部截图：先框选，再唤起窗口B 两排编辑工具栏
- (void)onFreeCrop {
    if (![self hasSelection]) {
        [Common toast:@"请先拖动画框，确定局部截取区域"];
        return;
    }
    [self captureShotAndEditWithRect:_cropRect];
}

- (void)onCancel {
    [self dismiss];
}

#pragma mark - 按钮动作（长截图面板）

// 长截图：直接弹悬浮面板，无需先画矩形（宽度恒全屏宽）
- (void)onLongShot {
    [self setMode:XZMaskModeLong];
    [Common toast:@"长截图：全屏宽。滑动页面→点采集下一屏→点生成长图"];
}

// 采集下一屏：隐藏面板 → 抓屏 → 按当前区间裁剪 → 加入长截图队列 → 恢复面板
- (void)onLongCaptureFrame {
    if (!_win) return;
    [self setWindowHidden:YES];          // 关键：抓屏前隐藏面板，避免面板被截入
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        UIImage *screen = [ImageUtils captureScreen];
        [ss setWindowHidden:NO];
        if (!screen) { [Common toast:@"截屏失败"]; return; }
        CGRect band = [ss bandScreenRect];
        UIImage *frame = [ImageUtils cropImage:screen screenRect:band];
        if (!frame) { [Common toast:@"裁剪失败"]; return; }
        BOOL added = [[LongShotCapture sharedInstance] addFrame:frame];
        [ss updateLongCounter];
        if (!added) [Common toast:@"未检测到新内容，请先滑动页面"];
    });
}

// 生成长图：拼接 → 销毁窗口A → 弹窗口B 两排编辑工具栏
- (void)onLongGenerate {
    if ([[LongShotCapture sharedInstance] frameCount] < 2) {
        [Common toast:@"请先采集至少 2 帧（滑动页面后点采集下一屏）"];
        return;
    }
    [Common toast:@"正在拼接长图..."];
    [self setWindowHidden:YES];
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

// 采集带：全屏宽 + 上下滑杆划定的 Y 轴垂直区间
- (CGRect)bandScreenRect {
    return CGRectMake(_longX, _topY, _longW, MAX(1, _bottomY - _topY));
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
