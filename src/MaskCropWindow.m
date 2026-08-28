//
//  MaskCropWindow.m — 窗口A：遮罩镂空框选（v4.0 超级截图架构）
//
//  关键设计（对照规格书）：
//   1. 遮罩是【半透明黑 + CAShapeLayer 镂空】：中间透出的是底层真实 App 画面，
//      绝不把截图贴在遮罩上。
//   2. 手指拖拽只画矩形；松手生成框；按住框内整体拖动（宽高不变、不旋转）。
//   3. 底部三按钮：长截图 / 正常截图 / 取消。
//   4. 任何截图动作前先 hidden 本窗口，防止把遮罩一并截入。
//   5. dismiss 必须完整销毁 UIWindow 并置空。
//

#import "MaskCropWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import "EditToolbarWindow.h"
#import "LongShotCapture.h"

// 手势模式
typedef NS_ENUM(NSInteger, MCPanMode) {
    MCPanNone = 0,
    MCPanDraw,   // 框外按下：画新矩形
    MCPanMove,   // 框内按下：整体拖动
};

@interface MaskCropWindow () <UIGestureRecognizerDelegate>
@end

@implementation MaskCropWindow {
    UIWindow *_win;
    UIView *_touchView;         // 全屏手势容器（承载 pan）
    CAShapeLayer *_maskLayer;   // 镂空遮罩（黑色 0.5）
    CAShapeLayer *_borderLayer; // 蓝色边框

    // 底部工具栏
    UIView *_toolbar;
    UIButton *_btnLong;         // 长截图
    UIButton *_btnNormal;       // 正常截图
    UIButton *_btnCancel;       // 取消
    // 长截图采集工具栏
    UIButton *_btnCapture;      // 采集下一屏
    UIButton *_btnPreview;      // 预览拼接
    UIButton *_btnLongDone;     // 完成
    UIButton *_btnLongCancel;   // 取消（回普通框选）

    // 选区状态（屏幕坐标）
    CGRect _cropRect;
    BOOL _hasCrop;

    // 手势状态
    MCPanMode _panMode;
    CGPoint _panStart;
    CGPoint _panGrab;

    // 长截图采集
    BOOL _longShotMode;
    NSMutableArray<UIImage *> *_capturedImages;
    CGFloat _maxPxHeight;       // 拼接最大像素高度（防内存溢出）
}

#pragma mark - 单例

+ (instancetype)sharedInstance {
    static MaskCropWindow *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [MaskCropWindow new]; });
    return inst;
}

#pragma mark - 生命周期

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxPxHeight = 12000;  // 长图最大像素高度上限
        _capturedImages = [NSMutableArray array];
    }
    return self;
}

// 弹出遮罩框选窗口
- (void)show {
    if (_win) [self dismiss];
    [LongShotCapture.sharedInstance reset];   // 清空上次采集

    _win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _win.windowLevel = UIWindowLevelAlert + 200;
    _win.backgroundColor = [UIColor clearColor];
    _win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) _win.windowScene = [Common activeWindowScene];

    _touchView = [[UIView alloc] initWithFrame:_win.bounds];
    _touchView.backgroundColor = [UIColor clearColor];
    [_win addSubview:_touchView];

    // 镂空遮罩：全屏路径 + 选区路径（evenOdd 规则 → 中间透出原屏幕）
    _maskLayer = [CAShapeLayer layer];
    _maskLayer.fillColor = [UIColor colorWithWhite:0 alpha:0.5].CGColor;
    _maskLayer.fillRule = kCAFillRuleEvenOdd;
    _maskLayer.frame = _win.bounds;
    [_touchView.layer addSublayer:_maskLayer];

    // 蓝色边框
    _borderLayer = [CAShapeLayer layer];
    _borderLayer.strokeColor = UIColor.systemBlueColor.CGColor;
    _borderLayer.lineWidth = 2;
    _borderLayer.fillColor = [UIColor clearColor].CGColor;
    [_touchView.layer addSublayer:_borderLayer];

    // 框选手势：框外=重画，框内=移动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [_touchView addGestureRecognizer:pan];

    [self installToolbar];
    [self updateMask];

    _win.hidden = NO;
}

// 完整销毁窗口A
- (void)dismiss {
    _hasCrop = NO;
    _cropRect = CGRectZero;
    _panMode = MCPanNone;
    _longShotMode = NO;
    [_capturedImages removeAllObjects];

    if (_win) {
        _win.hidden = YES;
        _win = nil;   // UIWindow 引用释放（配合 hidden 彻底销毁）
    }
    _touchView = nil;
    _maskLayer = nil;
    _borderLayer = nil;
    _toolbar = nil;
    _btnLong = _btnNormal = _btnCancel = nil;
    _btnCapture = _btnPreview = _btnLongDone = _btnLongCancel = nil;
}

- (CGRect)cropRect { return _cropRect; }
- (BOOL)hasSelection { return _hasCrop && _cropRect.size.width >= 8 && _cropRect.size.height >= 8; }

#pragma mark - 底部工具栏

- (void)installToolbar {
    CGRect scr = UIScreen.mainScreen.bounds;
    _toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, scr.size.height - 110, scr.size.width, 110)];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    [_win addSubview:_toolbar];

    // 普通模式三按钮
    _btnLong   = [self makeBarButton:@"长截图" color:UIColor.systemYellowColor action:@selector(onLongShot)];
    _btnNormal = [self makeBarButton:@"正常截图" color:UIColor.systemBlueColor action:@selector(onNormalShot)];
    _btnCancel = [self makeBarButton:@"取消" color:UIColor.systemGrayColor action:@selector(onCancel)];
    [self layoutButtons:@[_btnLong, _btnNormal, _btnCancel]];

    // 长截图采集模式四按钮（先隐藏）
    _btnCapture   = [self makeBarButton:@"采集下一屏" color:UIColor.systemGreenColor action:@selector(onCaptureFrame)];
    _btnPreview   = [self makeBarButton:@"预览拼接" color:UIColor.systemOrangeColor action:@selector(onPreviewStitch)];
    _btnLongDone  = [self makeBarButton:@"完成" color:UIColor.systemBlueColor action:@selector(onLongDone)];
    _btnLongCancel = [self makeBarButton:@"取消" color:UIColor.systemGrayColor action:@selector(onLongCancel)];
    for (UIButton *b in @[_btnCapture, _btnPreview, _btnLongDone, _btnLongCancel]) b.hidden = YES;
}

- (UIButton *)makeBarButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = color;
    b.layer.cornerRadius = 22;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_toolbar addSubview:b];
    return b;
}

- (void)layoutButtons:(NSArray<UIButton *> *)btns {
    CGFloat bw = 120, gap = 16;
    CGFloat totalW = btns.count * bw + (btns.count - 1) * gap;
    CGFloat x = (_toolbar.bounds.size.width - totalW) / 2;
    CGFloat y = 30;
    for (UIButton *b in btns) {
        b.frame = CGRectMake(x, y, bw, 44);
        x += bw + gap;
    }
}

// 切换普通框选模式 / 长截图采集模式
- (void)setLongShotMode:(BOOL)mode {
    _longShotMode = mode;
    _btnLong.hidden = mode;
    _btnNormal.hidden = mode;
    _btnCancel.hidden = mode;
    _btnCapture.hidden = !mode;
    _btnPreview.hidden = !mode;
    _btnLongDone.hidden = !mode;
    _btnLongCancel.hidden = !mode;
    if (mode) {
        [self layoutButtons:@[_btnCapture, _btnPreview, _btnLongDone, _btnLongCancel]];
        // 采集模式：关闭框选手势触摸，让触摸穿透到底层 App 以手动滑动页面
        _touchView.userInteractionEnabled = NO;
    } else {
        [self layoutButtons:@[_btnLong, _btnNormal, _btnCancel]];
        _touchView.userInteractionEnabled = YES;
    }
}

#pragma mark - 手势（画矩形 / 拖动）

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint loc = [pan locationInView:_touchView];
    CGRect b = _touchView.bounds;

    if (pan.state == UIGestureRecognizerStateBegan) {
        if ([self hasSelection] && CGRectContainsPoint(_cropRect, loc)) {
            _panMode = MCPanMove;
            _panGrab = CGPointMake(loc.x - _cropRect.origin.x, loc.y - _cropRect.origin.y);
        } else {
            _panMode = MCPanDraw;
            _panStart = loc;
            _cropRect = CGRectMake(loc.x, loc.y, 0, 0);
            _hasCrop = YES;
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (_panMode == MCPanDraw) {
            CGFloat x = MIN(_panStart.x, loc.x);
            CGFloat y = MIN(_panStart.y, loc.y);
            CGFloat w = fabs(loc.x - _panStart.x);
            CGFloat h = fabs(loc.y - _panStart.y);
            _cropRect = CGRectMake(MAX(0,x), MAX(0,y), MIN(w, b.size.width), MIN(h, b.size.height));
        } else if (_panMode == MCPanMove) {
            // 整体拖动：宽高不变、不旋转
            CGFloat x = loc.x - _panGrab.x;
            CGFloat y = loc.y - _panGrab.y;
            x = MAX(0, MIN(x, b.size.width - _cropRect.size.width));
            y = MAX(0, MIN(y, b.size.height - _cropRect.size.height));
            _cropRect = CGRectMake(x, y, _cropRect.size.width, _cropRect.size.height);
        }
        [self updateMask];
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        _panMode = MCPanNone;
        if (_cropRect.size.width < 8 || _cropRect.size.height < 8) {
            _hasCrop = NO;          // 太小当作没画
            _cropRect = CGRectZero;
        }
        [self updateMask];
    }
}

// 重绘镂空遮罩 + 蓝色边框
- (void)updateMask {
    CGRect full = _touchView.bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:full];
    if (_hasCrop) {
        [path appendPath:[UIBezierPath bezierPathWithRect:_cropRect]];
    }
    _maskLayer.path = path.CGPath;

    if (_hasCrop) {
        _borderLayer.path = [UIBezierPath bezierPathWithRect:_cropRect].CGPath;
        _borderLayer.hidden = NO;
    } else {
        _borderLayer.hidden = YES;
    }
}

#pragma mark - 按钮动作

// 正常截图：隐藏遮罩 → 抓屏 → cropRect 裁剪 → 销毁窗口A → 弹窗口B
- (void)onNormalShot {
    if (![self hasSelection]) { [Common toast:@"请先框选区域"]; return; }
    [self captureAndEdit];   // 与采集共用：抓当前屏 → 裁剪 → 弹编辑
}

// 长截图：进入采集模式
- (void)onLongShot {
    if (![self hasSelection]) { [Common toast:@"请先框选区域"]; return; }
    [self setLongShotMode:YES];
    [Common toast:@"已进入长截图采集：滑到目标位置后点「采集下一屏」"];
}

// 取消：直接销毁退出
- (void)onCancel {
    [self dismiss];
}

// 采集下一屏：隐藏遮罩 → 抓屏 → cropRect 裁剪 → 存入数组
- (void)onCaptureFrame {
    if (![self hasSelection]) { [Common toast:@"请先框选区域"]; return; }
    CGRect r = [self screenCropInPixels];
    _win.hidden = YES;                       // 关键：先隐藏遮罩
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIImage *screen = [ImageUtils captureScreen];
        _win.hidden = NO;
        if (!screen) { [Common toast:@"采集失败"]; return; }
        UIImage *frame = [self cropImage:screen toPixelRect:r];
        if (frame) {
            [LongShotCapture.sharedInstance addFrame:frame];
            [Common toast:[NSString stringWithFormat:@"已采集 %lu 屏，滑动页面后可再采",
                           (unsigned long)LongShotCapture.sharedInstance.frameCount]];
        }
    });
}

// 预览拼接（可选，骨架）
- (void)onPreviewStitch {
    // TODO: 调用 LongShotCapture stitch 的预览模式
    [Common toast:@"预览拼接（v4.1 实现）"];
}

// 完成：Vision 拼接 → 销毁窗口A → 弹窗口B
- (void)onLongDone {
    if (LongShotCapture.sharedInstance.frameCount < 2) {
        [Common toast:@"至少采集 2 屏才能拼接"];
        return;
    }
    [Common toast:@"正在拼接长图..."];
    __weak typeof(self) ws = self;
    [LongShotCapture.sharedInstance stitchWithCompletion:^(UIImage *result) {
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        if (result) {
            [ss dismiss];
            [EditToolbarWindow showWithImage:result];   // 弹窗口B
        } else {
            [Common toast:@"拼接失败"];
        }
    }];
}

// 长截图取消：清空数组，回普通框选模式
- (void)onLongCancel {
    [LongShotCapture.sharedInstance reset];
    [self setLongShotMode:NO];
    [Common toast:@"已取消长截图，回到框选"];
}

#pragma mark - 截图裁剪工具

// 把屏幕坐标选区换算成像素（乘 scale）
- (CGRect)screenCropInPixels {
    CGFloat sc = UIScreen.mainScreen.scale;
    return CGRectMake(_cropRect.origin.x * sc, _cropRect.origin.y * sc,
                      _cropRect.size.width * sc, _cropRect.size.height * sc);
}

- (UIImage *)cropImage:(UIImage *)img toPixelRect:(CGRect)r {
    if (!img.CGImage) return nil;
    r = CGRectIntersection(r, CGRectMake(0, 0, img.size.width, img.size.height));
    if (r.size.width < 4 || r.size.height < 4) return nil;
    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, r);
    UIImage *out = [UIImage imageWithCGImage:cg scale:img.scale orientation:img.imageOrientation];
    CGImageRelease(cg);
    return out;
}

// 抓当前屏 → 裁剪 → 销毁窗口A → 弹窗口B（正常截图路径）
- (void)captureAndEdit {
    CGRect r = [self screenCropInPixels];
    _win.hidden = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIImage *screen = [ImageUtils captureScreen];
        _win.hidden = NO;
        if (!screen) { [Common toast:@"截图失败"]; return; }
        UIImage *cropped = [self cropImage:screen toPixelRect:r];
        if (cropped) {
            [self dismiss];
            [EditToolbarWindow showWithImage:cropped];   // 弹窗口B
        } else {
            [Common toast:@"裁剪失败"];
        }
    });
}

@end
