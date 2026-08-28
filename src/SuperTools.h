//
//  SuperTools.h — 窗口B 全部按钮的底层实现
//  只使用 iOS 16 系统自带框架：Vision / PencilKit / PDFKit / Photos / CoreGraphics / UIKit
//  不引入任何第三方库。
//

#import <UIKit/UIKit.h>

@interface SuperTools : NSObject

#pragma mark 第一排：识别编辑

// 1. OCR：Vision VNRecognizeTextRequest 本地离线识别，text 可能为空
+ (void)ocr:(UIImage *)image completion:(void (^)(NSString *text))completion;

// 1b. OCR 带文字框：boxes 为 NSValue(CGRect)，坐标系是图片「像素」左上原点
+ (void)ocr:(UIImage *)image withBoxes:(void (^)(NSString *text, NSArray<NSValue *> *boxes))completion;

// 2. 翻译：OCR 取文 → 网络翻译接口 → src=原文 dst=译文
+ (void)translate:(UIImage *)image completion:(void (^)(NSString *src, NSString *dst))completion;

// 3. 画图：PencilKit 画板（画笔/箭头/矩形/文字/色块涂抹入口），edited=nil 表示取消
+ (void)draw:(UIImage *)image completion:(void (^)(UIImage *edited))completion;

// 4. 识码：Vision 识别 QR / 条码，返回 payload 文本
+ (void)codeScan:(UIImage *)image completion:(void (^)(NSString *code))completion;

// 5. 打码：手动色块涂抹 + 智能识别手机号/身份证自动脱敏，edited=nil 表示取消
+ (void)mosaic:(UIImage *)image completion:(void (^)(UIImage *edited))completion;

#pragma mark 第二排：输出操作

// 6. 复制：UIPasteboard 直接写剪贴板，不强制保存相册
+ (void)copy:(UIImage *)image;

// 7. 贴图：新建悬浮 UIWindow 贴纸，支持拖拽摆放
+ (void)floating:(UIImage *)image;

// 8. 保存：PHPhotoLibrary 写入相册
+ (void)save:(UIImage *)image completion:(void (^)(BOOL ok))completion;

// 9. 分享：原生 UIActivityViewController
+ (void)share:(UIImage *)image fromWindow:(UIWindow *)win;

#pragma mark 「更多」二级

// 10a. 导出 PDF：PDFKit 输出图片 PDF，返回文件路径
+ (NSString *)exportPDF:(UIImage *)image;

// 10b. 压缩：CGImageDestination 改 JPEG 质量
+ (UIImage *)compress:(UIImage *)image quality:(CGFloat)quality;

// 10c. 去状态栏：抹掉顶部状态栏
+ (UIImage *)stripStatusBar:(UIImage *)image;

// 10d. 取色器：拾取图片像素色值，展示 HEX 并可复制
+ (void)colorPicker:(UIImage *)image fromWindow:(UIWindow *)win;

@end
