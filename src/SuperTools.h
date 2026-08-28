//
//  SuperTools.h — 超级截图全部工具（窗口B 各按钮逻辑）
//  全部基于 iOS16 系统框架：Vision / PencilKit / PDFKit / Photos / CoreGraphics / UIKit
//

#import <UIKit/UIKit.h>

@interface SuperTools : NSObject

// 1. OCR：Vision 本地离线识别，completion 返回文本（可能空）
+ (void)ocr:(UIImage *)image completion:(void (^)(NSString *text))completion;

// 2. 翻译：OCR 文本 → 网络翻译（预留入口），dst=译文 src=原文
+ (void)translate:(UIImage *)image completion:(void (^)(NSString *dst, NSString *src))completion;

// 3. 画图：PencilKit 画板，edited=合成结果（可能 nil=取消）
+ (void)draw:(UIImage *)image completion:(void (^)(UIImage *edited))completion;

// 4. 识码：Vision 识别 QR/条码，返回 payload 文本
+ (void)codeScan:(UIImage *)image completion:(void (^)(NSString *code))completion;

// 5. 打码：马赛克（手动涂抹 / 智能脱敏），edited=处理后的图
+ (void)mosaic:(UIImage *)image completion:(void (^)(UIImage *edited))completion;

// 6. 复制：图片写入剪贴板
+ (void)copy:(UIImage *)image;

// 7. 贴图：悬浮 UIWindow 贴纸（可拖拽）
+ (void)floating:(UIImage *)image;

// 8. 保存：PHPhotoLibrary 写入相册
+ (void)save:(UIImage *)image completion:(void (^)(BOOL ok))completion;

// 9. 分享：UIActivityViewController
+ (void)share:(UIImage *)image fromWindow:(UIWindow *)win;

// 10a. 导出PDF：PDFKit 生成 PDF 文件，返回路径
+ (NSString *)exportPDF:(UIImage *)image;

// 10b. 压缩：CGImageDestination 改 JPEG 质量
+ (UIImage *)compress:(UIImage *)image quality:(CGFloat)quality;

// 10c. 去状态栏：裁剪顶部状态栏区域
+ (UIImage *)stripStatusBar:(UIImage *)image;

// 10d. 取色器：拾取图片像素色值（骨架）
+ (void)colorPicker:(UIImage *)image;

@end
