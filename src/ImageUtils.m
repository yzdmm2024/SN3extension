//
//  ImageUtils.m — 图片工具实现
//

#import "ImageUtils.h"
#import "Common.h"
#import <Photos/Photos.h>
#import <dlfcn.h>

@implementation ImageUtils

#pragma mark - 截屏

+ (UIImage *)captureScreen {
    // 优先：私有 UIGetScreenImage 抓真实整屏（含控制中心下层 App 内容）。
    // 用 dlsym 动态解析，避免链接私有符号导致编译/链接失败；符号不存在时回退。
    UIImage *(*getScreenImage)(void) = NULL;
    getScreenImage = (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    if (getScreenImage) {
        UIImage *img = getScreenImage();
        if (img) return img;
    }

    // 回退：抓关键 window 层级（SpringBoard 内通常抓到的是控制中心自身，仅作兜底）
    UIWindow *keyWin = [self topWindow];
    if (!keyWin) return nil;

    UIGraphicsBeginImageContextWithOptions(keyWin.bounds.size, NO, 0);
    [keyWin drawViewHierarchyInRect:keyWin.bounds afterScreenUpdates:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

+ (UIWindow *)topWindow {
    if (@available(iOS 13.0, *)) {
        NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

#pragma mark - v4.1：坐标空间换算 / 裁剪 / 取色
//
// 【v4.0 的致命 bug】
//   旧代码 screenCropInPixels 把选区 (点) × UIScreen.scale 得到「像素 rect」，
//   然后 cropImage:toPixelRect: 里又拿它跟 img.size（UIGetScreenImage 返回的图
//   size 通常是【点】，scale 可能是 1）做 CGRectIntersection：
//       CGRectIntersection(像素rect, 点bounds)
//   -> 落在屏幕下半部分的选区会被裁成空/极小 -> 返回 nil -> 弹「裁剪失败」
//   -> 窗口B 永远不出现（用户反馈「圈选范围后没有两排功能按钮区域」）。
//
// 【修法】
//   不再做任何「点↔像素」的假设，一律用比例换算：
//       ratio = image.size.width / 屏幕宽(点)
//   这样无论 image.size 是点还是像素，结果都在 image 自身坐标系里。
//
+ (CGRect)imageRectForScreenRect:(CGRect)screenRect image:(UIImage *)image {
    if (!image) return CGRectZero;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) return CGRectZero;
    CGFloat ratio = image.size.width / screenW;

    CGRect r = CGRectMake(screenRect.origin.x * ratio,
                          screenRect.origin.y * ratio,
                          screenRect.size.width * ratio,
                          screenRect.size.height * ratio);
    // 取整，避免半像素导致 CGImageCreateWithImageInRect 结果偏 1px
    r = CGRectIntegral(r);
    CGRect bounds = CGRectMake(0, 0, image.size.width, image.size.height);
    r = CGRectIntersection(r, bounds);
    if (CGRectIsNull(r)) return CGRectZero;
    return r;
}

+ (UIImage *)cropImage:(UIImage *)image screenRect:(CGRect)screenRect {
    if (!image) return nil;
    CGImageRef cgimg = image.CGImage;
    if (!cgimg) return nil;

    CGRect r = [self imageRectForScreenRect:screenRect image:image];
    if (r.size.width < 4 || r.size.height < 4) {
        NSLog(@"[SN3] crop failed: rect=(%.1f,%.1f,%.1f,%.1f) image=(%.0f,%.0f)",
              screenRect.origin.x, screenRect.origin.y,
              screenRect.size.width, screenRect.size.height,
              image.size.width, image.size.height);
        return nil;
    }
    CGImageRef cut = CGImageCreateWithImageInRect(cgimg, r);
    if (!cut) return nil;
    UIImage *out = [UIImage imageWithCGImage:cut
                                       scale:image.scale
                                 orientation:image.imageOrientation];
    CGImageRelease(cut);
    return out;
}

+ (UIColor *)pixelColorAtPoint:(CGPoint)pt inImage:(UIImage *)image {
    CGImageRef cgimg = image.CGImage;
    if (!cgimg) return nil;
    if (image.size.width <= 0 || image.size.height <= 0) return nil;

    CGFloat pxW = (CGFloat)CGImageGetWidth(cgimg);
    CGFloat pxH = (CGFloat)CGImageGetHeight(cgimg);
    if (pxW <= 0 || pxH <= 0) return nil;

    // pt 是 image 自身坐标系（image.size）下的位置 -> 归一化 -> 映射到像素
    CGFloat x = floor((pt.x / image.size.width) * pxW);
    CGFloat y = floor((pt.y / image.size.height) * pxH);
    if (x < 0 || y < 0 || x >= pxW || y >= pxH) return nil;

    unsigned char raw[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(raw, 1, 1, 8, 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    // 把整张图按 1:1 像素画进 1×1 的画布，并把目标像素推到画布原点
    CGContextDrawImage(ctx, CGRectMake(-x, -y, pxW, pxH), cgimg);
    CGContextRelease(ctx);

    return [UIColor colorWithRed:raw[0] / 255.0
                           green:raw[1] / 255.0
                            blue:raw[2] / 255.0
                           alpha:raw[3] / 255.0];
}

#pragma mark - 相册

+ (void)saveToCustomAlbum:(UIImage *)image completion:(void (^)(BOOL, NSError *))completion {
    // 先检查相册权限
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized) {
                if (completion) completion(NO, [NSError errorWithDomain:@"ImageUtils" code:-1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"没有相册权限"}]);
                return;
            }
            
            // 查找或创建「SN3截图」相册
            __block PHAssetCollection *targetAlbum = nil;
            PHFetchResult *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                 subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                                 options:nil];
            [collections enumerateObjectsUsingBlock:^(PHAssetCollection *obj, NSUInteger idx, BOOL *stop) {
                if ([obj.localizedTitle isEqualToString:@"SN3截图"]) {
                    targetAlbum = obj;
                    *stop = YES;
                }
            }];
            
            if (!targetAlbum) {
                // 创建新相册
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:@"SN3截图"];
                } completionHandler:^(BOOL success, NSError *error) {
                    if (success) {
                        // 重新查找
                        PHFetchResult *newCol = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                        subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                                        options:nil];
                        [newCol enumerateObjectsUsingBlock:^(PHAssetCollection *obj, NSUInteger idx, BOOL *stop) {
                            if ([obj.localizedTitle isEqualToString:@"SN3截图"]) {
                                targetAlbum = obj;
                                *stop = YES;
                            }
                        }];
                        [self saveImage:image toAlbum:targetAlbum completion:completion];
                    } else {
                        if (completion) completion(NO, error);
                    }
                }];
            } else {
                [self saveImage:image toAlbum:targetAlbum completion:completion];
            }
        });
    }];
}

+ (void)saveImage:(UIImage *)image toAlbum:(PHAssetCollection *)album completion:(void (^)(BOOL, NSError *))completion {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *assetReq = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        PHAssetCollectionChangeRequest *albumReq = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
        [albumReq addAssets:@[assetReq.placeholderForCreatedAsset]];
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, error);
        });
    }];
}

#pragma mark - 手机外壳

+ (UIImage *)applyPhoneFrame:(UIImage *)image {
    CGFloat frameW = image.size.width + 40;
    CGFloat frameH = image.size.height + 100;
    CGFloat notchH = 34;
    CGFloat bottomBarH = 20;
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(frameW, frameH), NO, image.scale);
    
    // 背景（外壳）
    UIBezierPath *framePath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, frameW, frameH)
                                                         cornerRadius:30];
    [[UIColor blackColor] setFill];
    [framePath fill];
    
    // 屏幕区域
    CGRect screenRect = CGRectMake(20, notchH + 10, image.size.width, image.size.height);
    [image drawInRect:screenRect];
    
    // 刘海（notch）
    CGFloat notchW = 120;
    CGFloat notchX = (frameW - notchW) / 2;
    UIBezierPath *notchPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(notchX, 0, notchW, notchH * 1.5)
                                                         byRoundingCorners:UIRectCornerBottomLeft | UIRectCornerBottomRight
                                                               cornerRadii:CGSizeMake(12, 12)];
    [[UIColor blackColor] setFill];
    [notchPath fill];
    
    // 底部横条
    CGFloat barW = 120, barH = 4;
    UIBezierPath *barPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake((frameW - barW)/2, frameH - bottomBarH - 8, barW, barH)
                                                       cornerRadius:2];
    [[UIColor colorWithWhite:0.3 alpha:1] setFill];
    [barPath fill];
    
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark - 悬浮窗口

+ (UIWindow *)createFloatingWindowWithImage:(UIImage *)image {
    CGFloat fw = 120, fh = 120 * image.size.height / image.size.width;
    if (fh > 200) { fh = 200; fw = 200 * image.size.width / image.size.height; }
    CGFloat fx = UIScreen.mainScreen.bounds.size.width - fw - 20;
    CGFloat fy = UIScreen.mainScreen.bounds.size.height / 2 - fh / 2;
    
    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(fx, fy, fw, fh)];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *)) win.windowScene = [Common activeWindowScene];
    
    UIImageView *iv = [[UIImageView alloc] initWithFrame:win.bounds];
    iv.image = image;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12;
    iv.clipsToBounds = YES;
    iv.layer.borderColor = [UIColor whiteColor].CGColor;
    iv.layer.borderWidth = 2;
    [win addSubview:iv];
    
    // 关闭按钮
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(fw - 28, 0, 28, 28);
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor redColor];
    [closeBtn addTarget:self action:@selector(dismissFloating:) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:closeBtn];
    
    // 拖拽
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panFloating:)];
    [win addGestureRecognizer:pan];

    // 双击退出（v4.1 修正：手势的 sender 是 UITapGestureRecognizer，
    // 不能复用 dismissFloating: 里 btn.superview 的写法，否则 unrecognized selector 崩溃）
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissFloatingByGesture:)];
    dt.numberOfTapsRequired = 2;
    [win addGestureRecognizer:dt];

    return win;
}

+ (void)dismissFloating:(UIButton *)btn {
    UIView *v = btn.superview;
    if ([v isKindOfClass:[UIWindow class]]) {
        ((UIWindow *)v).hidden = YES;
    }
}

+ (void)dismissFloatingByGesture:(UITapGestureRecognizer *)gesture {
    UIView *v = gesture.view;
    if ([v isKindOfClass:[UIWindow class]]) {
        ((UIWindow *)v).hidden = YES;
    }
}

+ (void)panFloating:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}

@end