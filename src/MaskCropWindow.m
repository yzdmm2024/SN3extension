//
//  MaskCropWindow.m — 窗口A：遮罩框选 + 长截图实时预览框（超级截图 v4.7）
//
//  ────────────────────────────────────────────────────────────────────────
//  v4.7 交互重设计（依据用户实测反馈）：
//    · 框选（遮罩）模式：
//        - 进入即局部截图模式，直接拖框；松手【立即】裁出选区 → 销毁窗口A → 弹窗口B
//          两排编辑工具栏（OCR/翻译/画图/识码/打码/复制/贴图/保存/分享/更多）。
//        - 底部常驻三个按钮：【正常截图】【长截图】【取消】。
//        - 正常截图：仿系统电源+音量键，截整屏直接存相册「SN3截图」，不弹编辑。
//    · 长截图 = 全屏宽「实时预览框」：
//        - 点【长截图】直接弹出全屏宽截取框；框外区域不参与输出。
//        - 框内触摸穿透，底层 App（微信群聊/单聊/朋友圈/公众号等）可上下滑动，
//          框内实时显示长截图内容预览；框内滚动的【最高点→最低点】即长截图起止范围。
//        - 框外【只保留 2 个按钮】：【保存长图】【复制】；方框右上角增加【关闭】按钮。
//        - 不出现双排编辑功能区；拼接完成后直接存相册 / 复制到剪贴板，不弹窗口B。
//        - 进入即启动自动抓帧定时器(~0.4s)：框内滑动期间逐帧采集、重叠去重；
//          建议从目标内容顶部开始向下滑动，松手静止即停采。
//    · 抓帧前临时隐藏边框，裁剪框内区域（已 inset 排除描边），绝不把暗色/控件截进图片。
//    · 退出时完整销毁窗口并置空，防 SpringBoard 泄漏 / respring。
//

#import "MaskCropWindow.h"
#import "XZPassThroughWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "EditToolbarWindow.h"
#import "LongShotCapture.h"

// ---------- 布局常量（pt） ----------
static const CGFloat kButtonH  = 46.0;   // 按钮高
static const CGFloat kMinCrop  = 16.0;   // 有效选区最小边长

// 长截图截取框留白（框全屏宽；上下留白给关闭按钮 / 底部两按钮）
static const CGFloat kFrameTopInset  = 54.0;   // 框顶距安全区上沿（留给关闭按钮）
static const CGFloat kFrameBotInset  = 86.0;   // 框底距屏幕底（留给底部两按钮）

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

    // ---- 框选模式：顶部提示 + 底部三按钮 ----
    UILabel  *_hintLabel;           // 顶部提示
    UIButton *_btnNormal;           // 正常截图
    UIButton *_btnLong;             // 长截图
    UIButton *_btnCancel;           // 取消

    // ---- 长截图：框外 2 按钮 + 关闭 + 计数 ----
    UIButton *_saveLongBtn;         // 保存长图
    UIButton *_copyLongBtn;         // 复制
    UIButton *_closeBtn;            // 关闭（框右上角）
    UILabel  *_longCountLabel;      // 已采集帧数

    // ---- 状态 ----
    XZMaskMode   _mode;
    XZDragTarget _drag;
    CGRect  _cropRect;              // 当前选区（屏幕点坐标）
    BOOL    _hasCrop;
    CGPoint _panStart;              // 画框起点
    CGPoint _panGrab;               // 拖动时手指在框内的相对偏移

    CGRect   _longFrameRect;        // 长截图截取框（屏幕坐标，全屏宽）
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

    [self installCropUI];
    [self installLongControls];
    [self setMode:XZMaskModeCrop];
    [self refreshChrome];

    _win.hidden = NO;
    [Common toast:@"拖出要截取的区域，松手即弹出编辑菜单"];
    NSLog(@"[SN3] mask window A shown (v4.7)");
}

- (void)refreshChrome {
    if (!_win) return;

    if (_mode == XZMaskModeCrop) {
        _hintLabel.hidden   = NO;
        _btnNormal.hidden   = NO;
        _btnLong.hidden     = NO;
        _btnCancel.hidden   = NO;
        _saveLongBtn.hidden = YES;
        _copyLongBtn.hidden = YES;
        _closeBtn.hidden    = YES;
        _longCountLabel.hidden = YES;
        _win.passthrough      = NO;              // 框选阶段吃下全屏拖拽
        _contentView.userInteractionEnabled = YES;
        _borderLayer.hidden = !_hasCrop;
        [self updateMask];
        [_win bringSubviewToFront:_hintLabel];
        [_win bringSubviewToFront:_btnNormal];
        [_win bringSubviewToFront:_btnLong];
        [_win bringSubviewToFront:_btnCancel];
    } else {
        _hintLabel.hidden   = YES;
        _btnNormal.hidden   = YES;
        _btnLong.hidden     = YES;
        _btnCancel.hidden   = YES;
        _saveLongBtn.hidden = NO;
        _copyLongBtn.hidden = NO;
        _closeBtn.hidden    = NO;
        _longCountLabel.hidden = NO;
        _win.passthrough      = YES;             // 长截图：框内穿透、框外吞咽
        _win.passRect        = _longFrameRect;   // 框内坐标 → 穿透给 App
        _contentView.userInteractionEnabled = NO; // 不拦截手势，交给 hitTest 决定
        _borderLayer.hidden = NO;
        [self updateMask];
        [self updateLongCounter];
        [_win bringSubviewToFront:_saveLongBtn];
        [_win bringSubviewToFront:_copyLongBtn];
        [_win bringSubviewToFront:_closeBtn];
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

    [self stopCaptureTimer];

    if (_win) {
        _win.hidden = YES;          // UIWindow 必须先隐藏再从视图树摘除，直接置 nil 会留下可见层
        _win = nil;                 // 置空，交还内存（防 SpringBoard 泄漏 / respring）
    }
    _contentView = nil;
    _dimLayer = nil;
    _borderLayer = nil;

    _hintLabel = nil;
    _btnNormal = _btnLong = _btnCancel = nil;
    _saveLongBtn = _copyLongBtn = _closeBtn = nil;
    _longCountLabel = nil;

    [[LongShotCapture sharedInstance] reset];
    NSLog(@"[SN3] mask window A destroyed");
}

- (CGRect)cropRect { return _cropRect; }
- (BOOL)hasSelection { return _hasCrop && _cropRect.size.width >= kMinCrop && _cropRect.size.height >= kMinCrop; }

#pragma mark - 框选模式 UI（顶部提示 + 底部三按钮）

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

- (void)installCropUI {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safe.top, scr.size.width, 22)];
    _hintLabel.textColor = [UIColor whiteColor];
    _hintLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    _hintLabel.text = @"拖框选区域，松手即编辑 · 底部可切「正常截图 / 长截图」";
    [_win addSubview:_hintLabel];
    [_win addInteractiveView:_hintLabel];

    CGFloat pad = 12.0, gap = 8.0;
    CGFloat by = scr.size.height - safe.bottom - 60;
    CGFloat bw = (scr.size.width - pad * 2 - gap * 2) / 3.0;
    CGFloat x = pad;
    _btnNormal = [self makeBarButton:@"正常截图" bg:[UIColor systemBlueColor]   action:@selector(onNormalShot)];
    _btnNormal.frame = CGRectMake(x, by, bw, kButtonH); x += bw + gap;
    _btnLong   = [self makeBarButton:@"长截图"   bg:[UIColor systemYellowColor] action:@selector(onLongShot)];
    _btnLong.frame = CGRectMake(x, by, bw, kButtonH); x += bw + gap;
    _btnCancel = [self makeBarButton:@"取消"     bg:[UIColor systemGrayColor]   action:@selector(onCancel)];
    _btnCancel.frame = CGRectMake(x, by, bw, kButtonH);
}

#pragma mark - 长截图 UI（全屏宽框 + 框外 2 按钮 + 关闭）

- (void)installLongControls {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIEdgeInsets safe = [Common screenSafeInsets];

    // 长截图截取框（全屏宽，上下留白给关闭按钮 / 底部两按钮）
    CGFloat top = safe.top + kFrameTopInset;
    CGFloat bot = safe.bottom + kFrameBotInset;
    _longFrameRect = CGRectMake(0, top,
                                scr.size.width,
                                MAX(60, scr.size.height - top - bot));

    // 关闭按钮：框右上角，置于框【上方暗色区】，保证可点（不落入 passRect）
    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(scr.size.width - 52, top - 38, 40, 40);
    [_closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    _closeBtn.tintColor = [UIColor whiteColor];
    _closeBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    _closeBtn.layer.cornerRadius = 20;
    [_closeBtn addTarget:self action:@selector(onLongClose) forControlEvents:UIControlEventTouchUpInside];
    [_win addSubview:_closeBtn];
    [_win addInteractiveView:_closeBtn];

    // 框外底部两按钮：保存长图 / 复制
    CGFloat pad = 16.0, gap = 12.0;
    CGFloat by = scr.size.height - safe.bottom - 76;
    CGFloat bw = (scr.size.width - pad * 2 - gap) / 2.0;
    _saveLongBtn = [self makeBarButton:@"保存长图" bg:[UIColor systemGreenColor] action:@selector(onSaveLong)];
    _saveLongBtn.frame = CGRectMake(pad, by, bw, kButtonH);
    _copyLongBtn = [self makeBarButton:@"复制"     bg:[UIColor systemBlueColor]   action:@selector(onCopyLong)];
    _copyLongBtn.frame = CGRectMake(pad + bw + gap, by, bw, kButtonH);

    // 计数提示（框底下方暗色区）
    _longCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, _longFrameRect.origin.y + _longFrameRect.size.height + 8,
                                                                scr.size.width, 18)];
    _longCountLabel.textColor = [UIColor whiteColor];
    _longCountLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _longCountLabel.textAlignment = NSTextAlignmentCenter;
    _longCountLabel.text = @"已采集 0 屏";
    [_win addSubview:_longCountLabel];
    [_win addInteractiveView:_longCountLabel];
}

#pragma mark - 模式切换

- (void)setMode:(XZMaskMode)mode {
    _mode = mode;
    if (mode == XZMaskModeLong) {
        [self startCaptureTimer];
        [self refreshChrome];
        [Common toast:@"长截图：框内从顶部向下滑动预览，点「保存长图」"];
    } else {
        [self stopCaptureTimer];
        [self refreshChrome];
    }
}

- (void)startCaptureTimer {
    [self stopCaptureTimer];
    _captureTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                    target:self
                                                  selector:@selector(longCaptureTick)
                                                  userInfo:nil
                                                   repeats:YES];
    [self longCaptureTick];   // 立即采一帧（初始画面）
}

- (void)stopCaptureTimer {
    if (_captureTimer) { [_captureTimer invalidate]; _captureTimer = nil; }
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
        // v4.6/4.7：松手【立即】进入编辑，不再需要二次确认
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

// 长截图：直接弹全屏宽截取框（框外区域不参与输出）
- (void)onLongShot {
    [self setMode:XZMaskModeLong];
}

// 关闭长截图框：清空已采集帧，回到框选模式（可重新选择）
- (void)onLongClose {
    [[LongShotCapture sharedInstance] reset];
    [self setMode:XZMaskModeCrop];
    [Common toast:@"已退出长截图"];
}

// 保存长图：拼接 → 直接存相册「SN3截图」→ 销毁窗口A（不弹编辑）
- (void)onSaveLong {
    if ([[LongShotCapture sharedInstance] frameCount] < 1) {
        [Common toast:@"请先在框内滑动页面采集内容"];
        return;
    }
    [Common toast:@"正在拼接长图..."];
    [self stopCaptureTimer];
    __weak typeof(self) ws = self;
    [[LongShotCapture sharedInstance] stitchWithCompletion:^(UIImage *result) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        UIImage *img = result ?: [[LongShotCapture sharedInstance] stitchFallback];
        [ss dismiss];
        if (img) {
            [ImageUtils saveToCustomAlbum:img completion:^(BOOL ok, NSError *e) {
                [Common toast: ok ? @"长图已保存到相册「SN3截图」" : @"保存失败，请检查相册权限"];
            }];
        } else {
            [Common toast:@"拼接失败，请重试"];
        }
    }];
}

// 复制长图：拼接 → 复制到剪贴板 → 销毁窗口A（不弹编辑）
- (void)onCopyLong {
    if ([[LongShotCapture sharedInstance] frameCount] < 1) {
        [Common toast:@"请先在框内滑动页面采集内容"];
        return;
    }
    [Common toast:@"正在拼接长图..."];
    [self stopCaptureTimer];
    __weak typeof(self) ws = self;
    [[LongShotCapture sharedInstance] stitchWithCompletion:^(UIImage *result) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        UIImage *img = result ?: [[LongShotCapture sharedInstance] stitchFallback];
        [ss dismiss];
        if (img) {
            [[UIPasteboard generalPasteboard] setImage:img];
            [Common toast:@"长图已复制到剪贴板"];
        } else {
            [Common toast:@"拼接失败，请重试"];
        }
    }];
}

// 自动抓帧：隐藏边框 → 抓屏 → 按截取框内区域裁剪(inset 排除描边) → 加入长截图队列（重叠去重）
- (void)longCaptureTick {
    if (!_win || _mode != XZMaskModeLong || _capturing) return;
    _capturing = YES;

    BOOL borderHidden = _borderLayer.hidden;
    _borderLayer.hidden = YES;                 // 抓帧时去掉边框，避免被截进长图

    UIImage *screen = [ImageUtils captureScreen];
    _borderLayer.hidden = borderHidden;

    if (!screen) { _capturing = NO; return; }
    // 框内裁剪：inset 3pt 排除描边；框外暗色区本就不在裁剪范围内（框外不参与输出）
    CGRect clip = CGRectInset(_longFrameRect, 3, 3);
    UIImage *tile = [ImageUtils cropImage:screen screenRect:clip];
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
