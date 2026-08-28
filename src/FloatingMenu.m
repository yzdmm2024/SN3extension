//
//  FloatingMenu.m — 截屏后浮动交互（v3.12 重构）
//
//  流程：
//    showChooser:    → 用户选择 长截图 / 自由截图
//    showLongShotPicker: → 长截图 4 边界独立窗口（上/下/左/右拖动）
//    doFreeCrop:     → 自由截图交互裁剪（冻结显示，可多次重选）
//    showActionRow:  → 操作行（OCR/翻译/问AI/保存/复制/分享/悬浮/重截）
//    doFloating:     → 悬浮贴图窗口（双击退出）
//
//  [v3.12 重大变更]
//    - 删除 doLongShot 的自动滚动拼接（已在 SB/CC 上下文触发 Safe Mode），
//      改为手动选 4 边界的独立窗口 showLongShotPicker:。
//    - 自由截图保持冻结逻辑；操作行新增"重截"按钮可随时回到自由截图。
//    - 选择器从屏幕中央改为屏幕底部（更顺手）。
//    - 按钮内图标改用用户提供的 PNG 模板图（longshot/freecut）。
//    - 悬浮贴图支持双击退出。
//

#import "FloatingMenu.h"
#import "Common.h"
#import "ImageUtils.h"
#import <Photos/Photos.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 资源 bundle

static NSBundle *SN3Bundle_(void) {
    return [NSBundle bundleWithPath:@"/var/jb/Library/Snapper3ZhExt.bundle"];
}

#pragma mark - 操作行 tag

typedef NS_ENUM(NSUInteger, XZRowAction) {
    XZRowOCR = 0,
    XZRowTranslate,
    XZRowAskAI,
    XZRowSave,
    XZRowCopy,
    XZRowShare,
    XZRowFloating,
    XZRowRecrop,
    XZRowCount
};

#pragma mark - 长截图 4 边界状态

@interface _LSState : NSObject
@property (nonatomic) CGFloat top, bottom, left, right;
@property (nonatomic, weak) UIImageView *iv;
@property (nonatomic, weak) UIView *hTop, *hBottom, *hLeft, *hRight;
@property (nonatomic, weak) UIView *lineTop, *lineBottom, *lineLeft, *lineRight;
@property (nonatomic, weak) UIView *maskTop, *maskBottom, *maskLeft, *maskRight;
@end
@implementation _LSState @end

#pragma mark - 自由截图状态（拖动暂存）

// cropPan 模式：1=手绘, 2=移动, 3=4角缩放
static NSInteger _cropMode = 0;
static CGPoint _cropStart = {0, 0};
static CGPoint _cropGrab = {0, 0};
static NSInteger _cropCorner = 0;   // 0=左上 1=右上 2=左下 3=右下

@implementation FloatingMenu

static UIWindow *_menuWindow;
static UIWindow *_cropWindow;
static UIWindow *_actionWindow;
static UIWindow *_longShotWindow;
static UIWindow *_floatingWindow;
static UIImage *_currentImage;

#pragma mark - 辅助

+ (UIImage *)_iconNamed:(NSString *)name {
    NSBundle *b = SN3Bundle_();
    UIImage *img = [UIImage imageNamed:name inBundle:b compatibleWithTraitCollection:nil];
    if (img) {
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return [UIImage systemImageNamed:name];
}

+ (UIColor *)_colorFromHex:(NSUInteger)hex {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

#pragma mark - 选择器

+ (void)showChooser:(UIImage *)screenshot {
    if (!screenshot) return;
    _currentImage = screenshot;
    [self dismissAll];

    CGRect scr = UIScreen.mainScreen.bounds;
    // v3.16：3 个图标——自由截图 / 整屏截图（类似 iOS 系统截图）/ 关闭
    NSArray *acts = @[
        @{@"img":@"freecut",  @"tag":@0},
        @{@"icon":@"iphone.gen3",  @"tag":@1},
        @{@"icon":@"xmark",   @"tag":@2},
    ];

    UIWindow *win = [[UIWindow alloc] initWithFrame:scr];
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    CGFloat iconS = 46;
    CGFloat gap = 28;
    CGFloat totalW = iconS * acts.count + gap * (acts.count - 1);
    CGFloat startX = (scr.size.width - totalW) / 2;
    CGFloat y = scr.size.height - iconS - 130;

    for (NSInteger i = 0; i < acts.count; i++) {
        NSDictionary *a = acts[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(startX + i * (iconS + gap), y, iconS, iconS);
        b.tag = [a[@"tag"] integerValue];
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        b.layer.cornerRadius = iconS / 2;
        b.layer.shadowColor = [UIColor blackColor].CGColor;
        b.layer.shadowOpacity = 0.3;
        b.layer.shadowRadius = 4;
        [b addTarget:self action:@selector(chooseTapped:) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:b];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectInset(b.bounds, 7, 7)];
        NSString *key = a[@"img"] ?: a[@"icon"];
        iv.image = [self _iconNamed:key];
        iv.tintColor = [UIColor whiteColor];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];
    }

    _menuWindow = win;
    win.hidden = NO;

    // 淡入
    for (UIView *sub in win.subviews) {
        sub.transform = CGAffineTransformMakeScale(0.4, 0.4);
        sub.alpha = 0;
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8
                         options:UIViewAnimationOptionCurveEaseOut
                      animations:^{
            sub.transform = CGAffineTransformIdentity;
            sub.alpha = 1;
        } completion:nil];
    }
}

+ (void)chooseTapped:(UIButton *)sender {
    UIImage *img = _currentImage;
    [self dismissAll];
    if (sender.tag == 0) {
        // 自由截图：冻结画面 + 框选（拖动/4角缩放）+ 两排功能按钮
        if (img) [self doFreeCrop:img];
    } else if (sender.tag == 1) {
        // 整屏截图（iOS 系统截图风格）：截屏 + 保存相册 + 复制剪贴板
        if (img) [self doRegularCapture:img];
    } else {
        // 关闭
        // dismissAll 已调
    }
}

#pragma mark - 长截图（4 边界独立窗口）

+ (UIView *)_makeLine {
    UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
    line.backgroundColor = [UIColor systemYellowColor];
    line.userInteractionEnabled = NO;
    return line;
}

+ (UIView *)_makeHandle {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    h.backgroundColor = [UIColor systemYellowColor];
    h.layer.cornerRadius = 13;
    h.layer.borderColor = [UIColor whiteColor].CGColor;
    h.layer.borderWidth = 2;
    h.userInteractionEnabled = YES;
    return h;
}

+ (void)_lsRedraw:(_LSState *)st {
    CGFloat ivW = st.iv.bounds.size.width;
    CGFloat ivH = st.iv.bounds.size.height;
    st.maskTop.frame    = CGRectMake(0, 0, ivW, st.top);
    st.maskBottom.frame = CGRectMake(0, st.bottom, ivW, ivH - st.bottom);
    st.maskLeft.frame   = CGRectMake(0, st.top, st.left, st.bottom - st.top);
    st.maskRight.frame  = CGRectMake(st.right, st.top, ivW - st.right, st.bottom - st.top);
    st.lineTop.frame    = CGRectMake(0, st.top - 1, ivW, 2);
    st.lineBottom.frame = CGRectMake(0, st.bottom - 1, ivW, 2);
    st.lineLeft.frame   = CGRectMake(st.left - 1, 0, 2, ivH);
    st.lineRight.frame  = CGRectMake(st.right - 1, 0, 2, ivH);
    st.hTop.center    = CGPointMake(ivW / 2, st.top);
    st.hBottom.center = CGPointMake(ivW / 2, st.bottom);
    st.hLeft.center   = CGPointMake(st.left, ivH / 2);
    st.hRight.center  = CGPointMake(st.right, ivH / 2);
}

+ (_LSState *)_lsStateFromPan:(UIPanGestureRecognizer *)pan {
    if (!_longShotWindow) return nil;
    return objc_getAssociatedObject(_longShotWindow, "lsState");
}

+ (void)showLongShotPicker:(UIImage *)image {
    if (!image) return;
    [self dismissAll];

    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 200;
    win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    CGRect scr = UIScreen.mainScreen.bounds;
    CGFloat ratio = image.size.width / image.size.height;
    CGFloat ivW = scr.size.width - 20;
    CGFloat ivH = ivW / ratio;
    CGFloat maxH = scr.size.height - 200;
    if (ivH > maxH) { ivH = maxH; ivW = ivH * ratio; }
    CGFloat ivX = (scr.size.width - ivW) / 2;
    CGFloat ivY = (scr.size.height - 100 - ivH) / 2;

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(ivX, ivY, ivW, ivH)];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = YES;
    iv.backgroundColor = [UIColor blackColor];
    iv.layer.borderColor = [UIColor whiteColor].CGColor;
    iv.layer.borderWidth = 1;
    [win addSubview:iv];

    _LSState *st = [_LSState new];
    st.iv = iv;
    st.top = 0; st.bottom = ivH; st.left = 0; st.right = ivW;

    UIView *maskTop = [[UIView alloc] initWithFrame:CGRectMake(0, 0, ivW, st.top)];
    UIView *maskBottom = [[UIView alloc] initWithFrame:CGRectMake(0, st.bottom, ivW, ivH - st.bottom)];
    UIView *maskLeft = [[UIView alloc] initWithFrame:CGRectMake(0, st.top, st.left, st.bottom - st.top)];
    UIView *maskRight = [[UIView alloc] initWithFrame:CGRectMake(st.right, st.top, ivW - st.right, st.bottom - st.top)];
    for (UIView *m in @[maskTop, maskBottom, maskLeft, maskRight]) {
        m.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        m.userInteractionEnabled = NO;
        [iv addSubview:m];
    }
    st.maskTop = maskTop; st.maskBottom = maskBottom; st.maskLeft = maskLeft; st.maskRight = maskRight;

    UIView *lineTop = [self _makeLine];
    UIView *lineBottom = [self _makeLine];
    UIView *lineLeft = [self _makeLine];
    UIView *lineRight = [self _makeLine];
    [iv addSubview:lineTop]; [iv addSubview:lineBottom]; [iv addSubview:lineLeft]; [iv addSubview:lineRight];
    st.lineTop = lineTop; st.lineBottom = lineBottom; st.lineLeft = lineLeft; st.lineRight = lineRight;

    UIView *hTop = [self _makeHandle];
    UIView *hBottom = [self _makeHandle];
    UIView *hLeft = [self _makeHandle];
    UIView *hRight = [self _makeHandle];
    [iv addSubview:hTop]; [iv addSubview:hBottom]; [iv addSubview:hLeft]; [iv addSubview:hRight];
    st.hTop = hTop; st.hBottom = hBottom; st.hLeft = hLeft; st.hRight = hRight;

    [self _lsRedraw:st];

    UIPanGestureRecognizer *pT = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(lsDragTop:)];
    [hTop addGestureRecognizer:pT];
    UIPanGestureRecognizer *pB = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(lsDragBottom:)];
    [hBottom addGestureRecognizer:pB];
    UIPanGestureRecognizer *pL = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(lsDragLeft:)];
    [hLeft addGestureRecognizer:pL];
    UIPanGestureRecognizer *pR = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(lsDragRight:)];
    [hRight addGestureRecognizer:pR];

    objc_setAssociatedObject(win, "lsState", st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, "lsImg", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, ivY - 28, scr.size.width, 20)];
    tip.text = @"拖上/下边界选起止点 · 拖左/右边界选范围（默认全宽）";
    tip.textColor = [UIColor lightGrayColor];
    tip.font = [UIFont systemFontOfSize:12];
    tip.textAlignment = NSTextAlignmentCenter;
    [win addSubview:tip];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(20, scr.size.height - 70, 130, 46);
    cancel.backgroundColor = [UIColor systemGray3Color];
    cancel.layer.cornerRadius = 23;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [cancel addTarget:self action:@selector(dismissAll) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:cancel];

    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem];
    confirm.frame = CGRectMake(scr.size.width - 150, scr.size.height - 70, 130, 46);
    confirm.backgroundColor = [UIColor systemBlueColor];
    confirm.layer.cornerRadius = 23;
    [confirm setTitle:@"裁出长截图" forState:UIControlStateNormal];
    [confirm setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    confirm.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [confirm addTarget:self action:@selector(lsConfirm:) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:confirm];

    _longShotWindow = win;
    win.hidden = NO;
}

+ (void)lsDragTop:(UIPanGestureRecognizer *)pan {
    _LSState *st = [self _lsStateFromPan:pan];
    if (!st) return;
    CGPoint loc = [pan locationInView:st.iv];
    CGFloat y = MAX(0, MIN(loc.y, st.bottom - 30));
    st.top = y;
    [self _lsRedraw:st];
}

+ (void)lsDragBottom:(UIPanGestureRecognizer *)pan {
    _LSState *st = [self _lsStateFromPan:pan];
    if (!st) return;
    CGPoint loc = [pan locationInView:st.iv];
    CGFloat y = MAX(st.top + 30, MIN(loc.y, st.iv.bounds.size.height));
    st.bottom = y;
    [self _lsRedraw:st];
}

+ (void)lsDragLeft:(UIPanGestureRecognizer *)pan {
    _LSState *st = [self _lsStateFromPan:pan];
    if (!st) return;
    CGPoint loc = [pan locationInView:st.iv];
    CGFloat x = MAX(0, MIN(loc.x, st.right - 30));
    st.left = x;
    [self _lsRedraw:st];
}

+ (void)lsDragRight:(UIPanGestureRecognizer *)pan {
    _LSState *st = [self _lsStateFromPan:pan];
    if (!st) return;
    CGPoint loc = [pan locationInView:st.iv];
    CGFloat x = MAX(st.left + 30, MIN(loc.x, st.iv.bounds.size.width));
    st.right = x;
    [self _lsRedraw:st];
}

+ (void)lsConfirm:(UIButton *)btn {
    if (!_longShotWindow) return;
    _LSState *st = objc_getAssociatedObject(_longShotWindow, "lsState");
    UIImage *image = objc_getAssociatedObject(_longShotWindow, "lsImg");
    if (!st || !image) { [self dismissAll]; return; }

    CGRect box = CGRectMake(st.left, st.top, st.right - st.left, st.bottom - st.top);
    CGFloat sx = image.size.width / st.iv.bounds.size.width;
    CGFloat sy = image.size.height / st.iv.bounds.size.height;
    CGRect cropRect = CGRectMake(box.origin.x * sx, box.origin.y * sy,
                                 box.size.width * sx, box.size.height * sy);
    cropRect = CGRectIntersection(cropRect, CGRectMake(0, 0, image.size.width, image.size.height));
    if (cropRect.size.width < 4 || cropRect.size.height < 4) {
        [Common toast:@"选区太小"];
        return;
    }

    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    UIImage *cropped = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);

    [self dismissAll];
    if (cropped) {
        _currentImage = cropped;
        [self showActionRow:cropped];
    }
}

#pragma mark - 自由截图（冻结+可重选）

+ (void)doFreeCrop:(UIImage *)image {
    UIWindow *win = nil;
    @try {
    if (!image) return;

    win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 200;
    win.backgroundColor = [UIColor blackColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    // 冻结画面：截图全屏铺满
    UIImageView *iv = [[UIImageView alloc] initWithFrame:win.bounds];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleToFill;
    iv.userInteractionEnabled = YES;
    [win addSubview:iv];

    CGRect scr = win.bounds;
    // 默认选区：屏幕 82% × 62% 居中（偏上给下方工具栏留空间）
    CGFloat boxW = scr.size.width * 0.82;
    CGFloat boxH = scr.size.height * 0.62;
    CGFloat boxX = (scr.size.width - boxW) / 2;
    CGFloat boxY = (scr.size.height - boxH) / 2 - 50;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(boxX, boxY, boxW, boxH)];
    box.layer.borderColor = [UIColor systemYellowColor].CGColor;
    box.layer.borderWidth = 2;
    box.layer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12].CGColor;
    [iv addSubview:box];

    // 4 角调整点（黄圆白边）
    UIView *hTL = [self _cornerAt:CGPointMake(boxX, boxY)];
    UIView *hTR = [self _cornerAt:CGPointMake(boxX+boxW, boxY)];
    UIView *hBL = [self _cornerAt:CGPointMake(boxX, boxY+boxH)];
    UIView *hBR = [self _cornerAt:CGPointMake(boxX+boxW, boxY+boxH)];
    [iv addSubview:hTL]; [iv addSubview:hTR]; [iv addSubview:hBL]; [iv addSubview:hBR];

    // 统一手势：iv 上一个 pan 处理 draw/move/resize 三种模式
    UIPanGestureRecognizer *ivPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cropPan:)];
    [iv addGestureRecognizer:ivPan];

    objc_setAssociatedObject(win, "cropIV", iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, "cropBox", box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, "cropImage", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, "cropCorners", @[hTL, hTR, hBL, hBR], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 顶部 X 关闭
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(16, 50, 36, 36);
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor whiteColor];
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    close.layer.cornerRadius = 18;
    [close addTarget:self action:@selector(dismissAll) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:close];

    // 两排功能按钮（在 box 下方，紧贴；空间不够则放框上方）
    [self _installToolbarsForBox:box inContainer:iv];

    _cropWindow = win;
    win.hidden = NO;
    } @catch (NSException *e) {
        NSLog(@"[SN3] doFreeCrop crashed: %@ %@", e.name, e.reason);
        if (win) { win.hidden = YES; }
    }
}

+ (void)cropPan:(UIPanGestureRecognizer *)pan {
    UIImageView *iv = (UIImageView *)pan.view;
    if (!_cropWindow) return;
    UIView *box = objc_getAssociatedObject(_cropWindow, "cropBox");
    if (!box) return;
    CGPoint loc = [pan locationInView:iv];
    CGRect bf = box.frame;
    CGRect b = iv.bounds;

    // v3.16：单 pan 多模式——框外点=重选, 框内点=移动, 4 角=缩放
    if (pan.state == UIGestureRecognizerStateBegan) {
        CGFloat cornerR = 36;   // 4 角判定距离
        BOOL inBox = CGRectContainsPoint(bf, loc);
        if (!inBox && bf.size.width > 30 && bf.size.height > 30) {
            // 框外 → 判断是 4 角还是空白
            NSArray *corners = objc_getAssociatedObject(_cropWindow, "cropCorners");
            __block NSInteger which = -1;
            __block CGFloat minD = cornerR;
            for (NSInteger i = 0; i < (NSInteger)corners.count; i++) {
                UIView *h = corners[i];
                CGFloat d = hypot(loc.x - h.center.x, loc.y - h.center.y);
                if (d < minD) { minD = d; which = i; }
            }
            if (which >= 0) {
                _cropMode = 3; _cropCorner = which; _cropStart = loc;  // resize
            } else {
                _cropMode = 1; _cropStart = loc;                       // 重画
                box.frame = CGRectMake(loc.x, loc.y, 0, 0);
            }
        } else if (inBox) {
            _cropMode = 2;                                            // 移动
            _cropGrab = CGPointMake(loc.x - bf.origin.x, loc.y - bf.origin.y);
        } else {
            _cropMode = 1; _cropStart = loc;                            // 初始没选区 → 画
            box.frame = CGRectMake(loc.x, loc.y, 0, 0);
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (_cropMode == 1) {
            CGFloat x = MIN(_cropStart.x, loc.x);
            CGFloat y = MIN(_cropStart.y, loc.y);
            CGFloat w = fabs(loc.x - _cropStart.x);
            CGFloat h = fabs(loc.y - _cropStart.y);
            box.frame = CGRectMake(MAX(0, x), MAX(0, y), MIN(w, b.size.width), MIN(h, b.size.height));
            [self _updateCornersForBox:box];
        } else if (_cropMode == 2) {
            CGFloat x = loc.x - _cropGrab.x;
            CGFloat y = loc.y - _cropGrab.y;
            x = MAX(0, MIN(x, b.size.width - bf.size.width));
            y = MAX(0, MIN(y, b.size.height - bf.size.height));
            box.frame = CGRectMake(x, y, bf.size.width, bf.size.height);
            [self _updateCornersForBox:box];
        } else if (_cropMode == 3) {
            CGFloat minS = 30;
            CGFloat x0 = bf.origin.x, y0 = bf.origin.y, x1 = CGRectGetMaxX(bf), y1 = CGRectGetMaxY(bf);
            if (_cropCorner == 0)      { x0 = MIN(loc.x, x1 - minS); y0 = MIN(loc.y, y1 - minS); }
            else if (_cropCorner == 1) { x1 = MAX(loc.x, x0 + minS); y0 = MIN(loc.y, y1 - minS); }
            else if (_cropCorner == 2) { x0 = MIN(loc.x, x1 - minS); y1 = MAX(loc.y, y0 + minS); }
            else                       { x1 = MAX(loc.x, x0 + minS); y1 = MAX(loc.y, y0 + minS); }
            box.frame = CGRectMake(MAX(0,x0), MAX(0,y0), MIN(x1-x0, b.size.width), MIN(y1-y0, b.size.height));
            [self _updateCornersForBox:box];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        [self clampBox:box inView:iv];
        [self _updateCornersForBox:box];
        _cropMode = 0;
    }
}

+ (void)clampBox:(UIView *)box inView:(UIImageView *)iv {
    CGRect b = iv.bounds;
    CGFloat x = MAX(0, box.frame.origin.x);
    CGFloat y = MAX(0, box.frame.origin.y);
    CGFloat w = MIN(box.frame.size.width, b.size.width - x);
    CGFloat h = MIN(box.frame.size.height, b.size.height - y);
    box.frame = CGRectMake(x, y, MAX(20, w), MAX(20, h));
}

+ (void)cropConfirm:(UIButton *)btn {
    @try {
        if (!_cropWindow) return;
        UIImageView *iv = objc_getAssociatedObject(_cropWindow, "cropIV");
        UIView *box = objc_getAssociatedObject(_cropWindow, "cropBox");
        UIImage *image = objc_getAssociatedObject(_cropWindow, "cropImage");
        if (!iv || !box || !image) { [self dismissAll]; return; }

        CGRect boxInIV = box.frame;
        CGFloat sx = image.size.width / MAX(1, iv.bounds.size.width);
        CGFloat sy = image.size.height / MAX(1, iv.bounds.size.height);
        CGRect cropRect = CGRectMake(boxInIV.origin.x * sx, boxInIV.origin.y * sy,
                                     boxInIV.size.width * sx, boxInIV.size.height * sy);
        cropRect = CGRectIntersection(cropRect, CGRectMake(0, 0, image.size.width, image.size.height));
        if (cropRect.size.width < 4 || cropRect.size.height < 4) { [Common toast:@"选区太小"]; return; }

        if (!image.CGImage) { [Common toast:@"裁剪失败（无图像数据）"]; return; }
        CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, cropRect);
        if (!cg) { [Common toast:@"裁剪失败"]; return; }
        UIImage *cropped = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
        CGImageRelease(cg);

        [self dismissAll];
        if (cropped) {
            _currentImage = cropped;
            [self showActionRow:cropped];
        }
    } @catch (NSException *e) {
        NSLog(@"[SN3] cropConfirm crashed: %@ %@", e.name, e.reason);
        [self dismissAll];
    }
}

#pragma mark - v3.16: 4 角点 + 双排工具栏 + 整屏截图

// 4 角调整点（黄圆白边）
+ (UIView *)_cornerAt:(CGPoint)center {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(center.x - 11, center.y - 11, 22, 22)];
    h.backgroundColor = [UIColor systemYellowColor];
    h.layer.cornerRadius = 11;
    h.layer.borderColor = [UIColor whiteColor].CGColor;
    h.layer.borderWidth = 2;
    h.userInteractionEnabled = NO;
    return h;
}

+ (void)_updateCornersForBox:(UIView *)box {
    if (!_cropWindow) return;
    NSArray *corners = objc_getAssociatedObject(_cropWindow, "cropCorners");
    if (corners.count != 4) return;
    CGRect b = box.frame;
    ((UIView *)corners[0]).center = CGPointMake(b.origin.x, b.origin.y);
    ((UIView *)corners[1]).center = CGPointMake(CGRectGetMaxX(b), b.origin.y);
    ((UIView *)corners[2]).center = CGPointMake(b.origin.x, CGRectGetMaxY(b));
    ((UIView *)corners[3]).center = CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b));
}

// 安装两排工具栏（4+3 布局，OCR/翻译/复制/贴图 / 保存/分享/更多），紧贴 box 下方
+ (void)_installToolbarsForBox:(UIView *)box inContainer:(UIView *)iv {
    CGRect b = box.frame;
    CGRect scr = UIScreen.mainScreen.bounds;
    CGFloat bw = 56, bh = 70, gap = 12;
    CGFloat row1W = 4*bw + 3*gap;
    CGFloat row2W = 3*bw + 2*gap;
    CGFloat y1 = CGRectGetMaxY(b) + 24;
    CGFloat y2 = y1 + bh + 14;
    if (y2 + bh > scr.size.height - 20) {
        // 空间不够放框上方
        y1 = b.origin.y - 2*bh - 14 - 24;
        y2 = y1 + bh + 14;
    }

    NSArray *row1 = @[
        @{@"icon":@"text.viewfinder",      @"label":@"OCR",   @"color":@0x007AFF, @"tag":@1},
        @{@"icon":@"translate",            @"label":@"翻译", @"color":@0x34C759, @"tag":@2},
        @{@"icon":@"doc.on.doc",           @"label":@"复制", @"color":@0x4CD964, @"tag":@3},
        @{@"icon":@"pin",                  @"label":@"贴图", @"color":@0xFF9500, @"tag":@4},
    ];
    NSArray *row2 = @[
        @{@"icon":@"square.and.arrow.down",@"label":@"保存", @"color":@0x5AC8FA, @"tag":@5},
        @{@"icon":@"square.and.arrow.up",  @"label":@"分享", @"color":@0x007AFF, @"tag":@6},
        @{@"icon":@"ellipsis",             @"label":@"更多", @"color":@0x8E8E93, @"tag":@7},
    ];

    CGFloat x1 = (scr.size.width - row1W) / 2;
    for (NSInteger i = 0; i < row1.count; i++) {
        NSDictionary *a = row1[i];
        UIButton *btn = [self _makeToolButton:a];
        btn.frame = CGRectMake(x1 + i*(bw+gap), y1, bw, bh);
        [iv addSubview:btn];
    }
    CGFloat x2 = (scr.size.width - row2W) / 2;
    for (NSInteger i = 0; i < row2.count; i++) {
        NSDictionary *a = row2[i];
        UIButton *btn = [self _makeToolButton:a];
        btn.frame = CGRectMake(x2 + i*(bw+gap), y2, bw, bh);
        [iv addSubview:btn];
    }
}

+ (UIButton *)_makeToolButton:(NSDictionary *)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = [a[@"tag"] integerValue];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    b.layer.cornerRadius = 14;
    [b addTarget:self action:@selector(toolTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((56-26)/2, 8, 26, 26)];
    iv.image = [UIImage systemImageNamed:a[@"icon"]];
    iv.tintColor = [self _colorFromHex:[a[@"color"] unsignedIntegerValue]];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [b addSubview:iv];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 40, 56, 18)];
    lb.text = a[@"label"];
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.userInteractionEnabled = NO;
    [b addSubview:lb];
    return b;
}

// 工具按钮点击：按选区裁剪后分发给对应功能
+ (void)toolTapped:(UIButton *)btn {
    if (!_cropWindow) return;
    UIImageView *iv = objc_getAssociatedObject(_cropWindow, "cropIV");
    UIView *box = objc_getAssociatedObject(_cropWindow, "cropBox");
    UIImage *image = objc_getAssociatedObject(_cropWindow, "cropImage");
    if (!iv || !box || !image) return;

    CGRect boxInIV = box.frame;
    if (boxInIV.size.width < 4 || boxInIV.size.height < 4) {
        [Common toast:@"请先框选区域"]; return;
    }
    CGFloat sx = image.size.width / MAX(1, iv.bounds.size.width);
    CGFloat sy = image.size.height / MAX(1, iv.bounds.size.height);
    CGRect cropRect = CGRectMake(boxInIV.origin.x*sx, boxInIV.origin.y*sy,
                                 boxInIV.size.width*sx, boxInIV.size.height*sy);
    cropRect = CGRectIntersection(cropRect, CGRectMake(0, 0, image.size.width, image.size.height));
    if (cropRect.size.width < 4 || cropRect.size.height < 4) {
        [Common toast:@"选区太小"]; return;
    }
    if (!image.CGImage) { [Common toast:@"裁剪失败"]; return; }
    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    if (!cg) { [Common toast:@"裁剪失败"]; return; }
    UIImage *cropped = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    _currentImage = cropped;

    switch (btn.tag) {
        case 1: [self doOCR:cropped];       break;
        case 2: [self doTranslate:cropped]; break;
        case 3: [self doCopy:cropped];      break;
        case 4: [self doFloating:cropped];  break;
        case 5: [self doSaveAlbum:cropped]; break;
        case 6: [self doShare:cropped];     break;
        case 7: [self showMoreMenuForImage:cropped]; break;
    }
}

// 「更多」弹窗：问AI / 重选区域
+ (void)showMoreMenuForImage:(UIImage *)image {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更多功能" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"问AI" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self doAskAI:image];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重选区域" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        // 拿原图重进 doFreeCrop
        if (_cropWindow) {
            UIImage *orig = objc_getAssociatedObject(_cropWindow, "cropImage");
            if (orig) {
                [self dismissAll];
                [self doFreeCrop:orig];
            }
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIWindow *keyWin = [Common topWindow];
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (root) {
        [root presentViewController:ac animated:YES completion:nil];
    } else {
        // 兜底：toast 提示
        [Common toast:@"问AI/重选：请在 App 内操作"];
    }
}

// 整屏截图（iOS 系统截图风格）：保存到相册 + 复制到剪贴板
+ (void)doRegularCapture:(UIImage *)image {
    if (!image) return;
    [UIPasteboard generalPasteboard].image = image;

    Class imgUtils = NSClassFromString(@"ImageUtils");
    SEL sel = @selector(saveToCustomAlbum:completion:);
    if (imgUtils && [imgUtils respondsToSelector:sel]) {
        void (*func)(id, SEL, UIImage*, void(^)(BOOL, NSError*)) =
            (void(*)(id, SEL, UIImage*, void(^)(BOOL, NSError*)))[imgUtils methodForSelector:sel];
        func(imgUtils, sel, image, ^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [Common toast:success ? @"已保存+已复制" : @"已复制（保存失败）"];
            });
        });
    } else {
        [Common toast:@"已复制到剪贴板"];
    }
}

#pragma mark - 操作行

+ (void)showActionRow:(UIImage *)image {
    if (!image) return;
    @try {
    _currentImage = image;
    [self dismissAll];

    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 150;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];

    UIButton *mask = [UIButton buttonWithType:UIButtonTypeCustom];
    mask.frame = win.bounds;
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [mask addTarget:self action:@selector(dismissAll) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:mask];

    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    CGFloat barH = 104;
    bar.frame = CGRectMake(0, UIScreen.mainScreen.bounds.size.height - barH, UIScreen.mainScreen.bounds.size.width, barH);
    bar.layer.cornerRadius = 18;
    bar.clipsToBounds = YES;
    [win addSubview:bar];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 0, bar.bounds.size.width - 20, barH)];
    scroll.showsHorizontalScrollIndicator = NO;
    [bar addSubview:scroll];

    NSArray *acts = @[
        @{@"icon": @"text.viewfinder", @"label": @"OCR",       @"color": @0x007AFF},
        @{@"icon": @"translate",      @"label": @"翻译",      @"color": @0x34C759},
        @{@"icon": @"brain",          @"label": @"问AI",      @"color": @0xAF52DE},
        @{@"icon": @"photo.badge.arrow.down", @"label": @"保存", @"color": @0x5AC8FA},
        @{@"icon": @"doc.on.doc",     @"label": @"复制",      @"color": @0x4CD964},
        @{@"icon": @"square.and.arrow.up", @"label": @"分享",  @"color": @0x007AFF},
        @{@"icon": @"pin",            @"label": @"悬浮贴图",  @"color": @0xFF9500},
        @{@"icon": @"scissors",       @"label": @"重截",      @"color": @0xFFCC00},
    ];

    CGFloat bw = 72, gap = 8;
    for (NSInteger i = 0; i < acts.count; i++) {
        NSDictionary *a = acts[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8 + i * (bw + gap), 8, bw, barH - 16);
        b.tag = i;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        b.layer.cornerRadius = 14;
        [b addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(bw/2 - 16, 10, 32, 32)];
        iv.image = [UIImage systemImageNamed:a[@"icon"]];
        iv.tintColor = [self _colorFromHex:[a[@"color"] unsignedIntegerValue]];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [b addSubview:iv];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 46, bw, 18)];
        lb.text = a[@"label"];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:11];
        lb.textAlignment = NSTextAlignmentCenter;
        [b addSubview:lb];

        [scroll addSubview:b];
    }
    scroll.contentSize = CGSizeMake(8 + acts.count * (bw + gap) + 8, barH);

    _actionWindow = win;
    win.hidden = NO;

    bar.transform = CGAffineTransformMakeTranslation(0, barH);
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.6
                     options:UIViewAnimationOptionCurveEaseOut
                  animations:^{ bar.transform = CGAffineTransformIdentity; } completion:nil];
    } @catch (NSException *e) {
        NSLog(@"[SN3] showActionRow crashed: %@ %@", e.name, e.reason);
    }
}

+ (void)rowTapped:(UIButton *)sender {
    UIImage *img = _currentImage;
    if (!img) return;
    switch (sender.tag) {
        case XZRowOCR:       [self dismissAll]; [self doOCR:img]; break;
        case XZRowTranslate: [self dismissAll]; [self doTranslate:img]; break;
        case XZRowAskAI:     [self dismissAll]; [self doAskAI:img]; break;
        case XZRowSave:      [self dismissAll]; [self doSaveAlbum:img]; break;
        case XZRowCopy:      [self dismissAll]; [self doCopy:img]; break;
        case XZRowShare:     [self dismissAll]; [self doShare:img]; break;
        case XZRowFloating:  [self dismissAll]; [self doFloating:img]; break;
        case XZRowRecrop:
            // 重截：直接回到自由截图（不 dismissAll 让它过渡平滑）
            [self doFreeCrop:img];
            break;
    }
}

#pragma mark - 功能实现

+ (void)doOCR:(UIImage *)image {
    [Common toast:@"正在OCR识别中..."];
    Class visionOCR = NSClassFromString(@"VisionOCR");
    if (!visionOCR) { [Common toast:@"OCR模块未加载"]; return; }
    SEL sel = @selector(recognizeImage:languages:completion:);
    if ([visionOCR respondsToSelector:sel]) {
        void (*func)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)) =
        (void(*)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)))[visionOCR methodForSelector:sel];
        func(visionOCR, sel, image, [Common ocrLanguages], ^(NSString *text) {
            if (text.length) {
                [UIPasteboard generalPasteboard].string = text;
                [Common toast:[NSString stringWithFormat:@"OCR完成，已复制\n%@",
                                [text substringToIndex:MIN(60, text.length)]]];
            } else {
                [Common toast:@"OCR未识别到文字"];
            }
        });
    }
}

+ (void)doTranslate:(UIImage *)image {
    NSString *appid = [Common stringPref:XZ_KEY_TRANS_APPID default:@""];
    NSString *key   = [Common stringPref:XZ_KEY_TRANS_KEY   default:@""];
    NSString *target= [Common stringPref:XZ_KEY_TRANS_TARGET default:@"zh"];
    if (!appid.length || !key.length) {
        [Common toast:@"翻译需先在「设置→SN3延伸板」填百度翻译 AppID/密钥"];
        return;
    }
    [Common toast:@"正在翻译中..."];
    Class visionOCR   = NSClassFromString(@"VisionOCR");
    Class transEngine = NSClassFromString(@"TranslateEngine");
    if (!visionOCR || !transEngine) { [Common toast:@"翻译模块未加载"]; return; }

    SEL ocrSel = @selector(recognizeImage:languages:completion:);
    void (*ocrFunc)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)) =
    (void(*)(id, SEL, UIImage*, NSArray*, void(^)(NSString*)))[visionOCR methodForSelector:ocrSel];
    ocrFunc(visionOCR, ocrSel, image, [Common ocrLanguages], ^(NSString *text) {
        if (!text.length) { [Common toast:@"未识别到文字"]; return; }
        SEL transSel = @selector(translateText:fromLang:toLang:appid:appKey:completion:);
        void (*transFunc)(id, SEL, NSString*, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)) =
        (void(*)(id, SEL, NSString*, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)))[transEngine methodForSelector:transSel];
        transFunc(transEngine, transSel, text, @"auto", target, appid, key, ^(NSString *translated, NSString *error) {
            if (translated.length) {
                [UIPasteboard generalPasteboard].string = translated;
                [Common toast:[NSString stringWithFormat:@"翻译完成：%@",
                                [translated substringToIndex:MIN(50, translated.length)]]];
            } else {
                [Common toast:error ?: @"翻译失败"];
            }
        });
    });
}

+ (void)doAskAI:(UIImage *)image {
    NSString *baseURL = [Common stringPref:XZ_KEY_AI_BASEURL default:@""];
    NSString *apiKey  = [Common stringPref:XZ_KEY_AI_KEY     default:@""];
    NSString *model   = [Common stringPref:XZ_KEY_AI_MODEL   default:@""];
    NSString *prompt  = [Common stringPref:XZ_KEY_AI_PROMPT  default:@"请描述这张图片中的内容"];
    if (!baseURL.length || !apiKey.length) {
        [Common toast:@"AI需先在「设置→SN3延伸板」填接口地址和密钥"];
        return;
    }
    [Common toast:@"正在询问AI..."];
    Class aiEngine = NSClassFromString(@"AskAIEngine");
    if (!aiEngine) { [Common toast:@"AI模块未加载"]; return; }

    NSString *b64 = @"";
    if (image) {
        NSData *d = UIImageJPEGRepresentation(image, 0.8);
        if (d) b64 = [d base64EncodedStringWithOptions:0];
    }
    NSString *fullPrompt = b64.length
        ? [NSString stringWithFormat:@"%@\n\n[图片 base64] %@", prompt, b64]
        : prompt;

    SEL sel = @selector(askText:baseURL:apiKey:model:completion:);
    void (*func)(id, SEL, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)) =
    (void(*)(id, SEL, NSString*, NSString*, NSString*, NSString*, void(^)(NSString*, NSString*)))[aiEngine methodForSelector:sel];
    func(aiEngine, sel, fullPrompt, baseURL, apiKey, model, ^(NSString *answer, NSString *error) {
        if (answer.length) {
            [UIPasteboard generalPasteboard].string = answer;
            [Common toast:[NSString stringWithFormat:@"AI回复：%@",
                            [answer substringToIndex:MIN(50, answer.length)]]];
        } else {
            [Common toast:error ?: @"AI请求失败"];
        }
    });
}

+ (void)doSaveAlbum:(UIImage *)image {
    [Common toast:@"正在保存到相册..."];
    Class imgUtils = NSClassFromString(@"ImageUtils");
    if (!imgUtils) { [Common toast:@"保存模块未加载"]; return; }
    SEL sel = @selector(saveToCustomAlbum:completion:);
    void (*func)(id, SEL, UIImage*, void(^)(BOOL, NSError*)) =
    (void(*)(id, SEL, UIImage*, void(^)(BOOL, NSError*)))[imgUtils methodForSelector:sel];
    func(imgUtils, sel, image, ^(BOOL success, NSError *error) {
        if (success) {
            [Common toast:@"已保存到「SN3截图」相册"];
        } else {
            [Common toast:[NSString stringWithFormat:@"保存失败: %@",
                            error.localizedDescription ?: @"未知错误"]];
        }
    });
}

+ (void)doCopy:(UIImage *)image {
    [UIPasteboard generalPasteboard].image = image;
    [Common toast:@"图片已复制到剪贴板"];
}

+ (void)doShare:(UIImage *)image {
    UIWindow *keyWin = [Common topWindow];
    if (!keyWin) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc]
                                      initWithActivityItems:@[image] applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        avc.popoverPresentationController.sourceView = keyWin;
        avc.popoverPresentationController.sourceRect =
            CGRectMake(keyWin.bounds.size.width/2, keyWin.bounds.size.height/2, 0, 0);
    }
    UIViewController *presenter = keyWin.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:avc animated:YES completion:nil];
}

+ (void)doFloating:(UIImage *)image {
    if (_floatingWindow) { _floatingWindow.hidden = YES; _floatingWindow = nil; }

    CGFloat fw = 120, fh = 120 * image.size.height / image.size.width;
    if (fh > 200) { fh = 200; fw = 200 * image.size.width / image.size.height; }
    CGFloat fx = UIScreen.mainScreen.bounds.size.width - fw - 20;
    CGFloat fy = UIScreen.mainScreen.bounds.size.height / 2 - fh / 2;

    UIWindow *fwin = [[UIWindow alloc] initWithFrame:CGRectMake(fx, fy, fw, fh)];
    fwin.windowLevel = UIWindowLevelAlert + 300;
    fwin.backgroundColor = [UIColor clearColor];
    fwin.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) fwin.windowScene = [Common activeWindowScene];

    UIImageView *fiv = [[UIImageView alloc] initWithFrame:fwin.bounds];
    fiv.image = image;
    fiv.contentMode = UIViewContentModeScaleAspectFit;
    fiv.layer.cornerRadius = 12;
    fiv.clipsToBounds = YES;
    fiv.layer.borderColor = [UIColor whiteColor].CGColor;
    fiv.layer.borderWidth = 2;
    [fwin addSubview:fiv];

    UIButton *fb = [UIButton buttonWithType:UIButtonTypeSystem];
    fb.frame = CGRectMake(fw - 28, 0, 28, 28);
    [fb setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    fb.tintColor = [UIColor redColor];
    [fb addTarget:self action:@selector(closeFloating) forControlEvents:UIControlEventTouchUpInside];
    [fwin addSubview:fb];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloating:)];
    [fwin addGestureRecognizer:pan];

    // 双击退出
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeFloating)];
    dt.numberOfTapsRequired = 2;
    [fwin addGestureRecognizer:dt];

    _floatingWindow = fwin;
    fwin.hidden = NO;

    fwin.transform = CGAffineTransformMakeScale(0.3, 0.3);
    fwin.alpha = 0;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8
                     options:UIViewAnimationOptionCurveEaseOut
                  animations:^{
        fwin.transform = CGAffineTransformIdentity;
        fwin.alpha = 1;
    } completion:nil];
}

+ (void)closeFloating {
    if (_floatingWindow) {
        _floatingWindow.hidden = YES;
        _floatingWindow = nil;
    }
}

+ (void)panFloating:(UIPanGestureRecognizer *)pan {
    if (!_floatingWindow) return;
    CGPoint t = [pan translationInView:_floatingWindow.superview];
    _floatingWindow.center = CGPointMake(_floatingWindow.center.x + t.x, _floatingWindow.center.y + t.y);
    [pan setTranslation:CGPointZero inView:_floatingWindow.superview];
}

#pragma mark - 关闭

+ (void)dismissAll {
    if (_menuWindow)     { _menuWindow.hidden = YES;     _menuWindow = nil; }
    if (_cropWindow)     { _cropWindow.hidden = YES;     _cropWindow = nil; }
    if (_actionWindow)   { _actionWindow.hidden = YES;   _actionWindow = nil; }
    if (_longShotWindow) { _longShotWindow.hidden = YES; _longShotWindow = nil; }
    // 悬浮贴图保留，由用户手动关闭（双击或点 X）
}

@end