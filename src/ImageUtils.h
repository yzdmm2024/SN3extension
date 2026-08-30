//
//  ImageUtils.h — 图片工具
//
//  截屏、相册、裁剪、悬浮贴图等功能
//

#import <UIKit/UIKit.h>

@interface ImageUtils : NSObject

// 截取当前屏幕（优先私有 UIGetScreenImage，失败回退 keyWindow 快照）
+ (UIImage *)captureScreen;

#pragma mark - v4.1 新增：坐标空间换算（修复裁剪失败的根因）

// 把「屏幕点坐标」的 rect 换算成 image 自身坐标系的 rect。
// ⚠️ 关键：UIGetScreenImage() 返回的 UIImage，其 size 可能是【点】也可能是【像素】
//    （取决于系统版本与 scale），所以绝不能假设。这里统一用
//    ratio = image.size.width / 屏幕宽(点) 来推导，两种情况下都正确。
+ (CGRect)imageRectForScreenRect:(CGRect)screenRect image:(UIImage *)image;

// 按屏幕点坐标 rect 裁剪图片；跨坐标系安全。尺寸不合法返回 nil。
+ (UIImage *)cropImage:(UIImage *)image screenRect:(CGRect)screenRect;

// 读取图片在「点坐标」pt 处的像素颜色（取色器用），越界返回 nil
+ (UIColor *)pixelColorAtPoint:(CGPoint)pt inImage:(UIImage *)image;

#pragma mark - 其它

// 保存到自定义相册（创建「SN3截图」相册）
+ (void)saveToCustomAlbum:(UIImage *)image completion:(void (^)(BOOL success, NSError *error))completion;

// 图片加手机外壳（可选指定壳型 id；@"none"/未知=不加壳）
+ (UIImage *)applyPhoneFrame:(UIImage *)image caseId:(NSString *)caseId;

// 图片加手机外壳（默认不加壳，向后兼容）
+ (UIImage *)applyPhoneFrame:(UIImage *)image;

// 创建悬浮窗口（带图片）
+ (UIWindow *)createFloatingWindowWithImage:(UIImage *)image;

@end