//
//  ImageUtils.m — 图片工具实现
//

#import "ImageUtils.h"
#import <Photos/Photos.h>

@implementation ImageUtils

#pragma mark - 截屏

+ (UIImage *)captureScreen {
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
    
    return win;
}

+ (void)dismissFloating:(UIButton *)btn {
    UIWindow *win = (UIWindow *)btn.superview;
    if ([win isKindOfClass:[UIWindow class]]) {
        win.hidden = YES;
    }
}

+ (void)panFloating:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}

@end