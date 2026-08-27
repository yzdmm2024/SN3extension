//
//  ImageUtils.h — 图片工具
//
//  截屏、相册、裁剪、悬浮贴图等功能
//

#import <UIKit/UIKit.h>

@interface ImageUtils : NSObject

// 截取当前屏幕
+ (UIImage *)captureScreen;

// 保存到自定义相册（创建「SN3截图」相册）
+ (void)saveToCustomAlbum:(UIImage *)image completion:(void (^)(BOOL success, NSError *error))completion;

// 图片加手机外壳（简易圆角+刘海）
+ (UIImage *)applyPhoneFrame:(UIImage *)image;

// 创建悬浮窗口（带图片）
+ (UIWindow *)createFloatingWindowWithImage:(UIImage *)image;

@end