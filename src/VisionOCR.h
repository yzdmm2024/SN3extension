//
//  VisionOCR.h  — 本地 Vision 中文 OCR
//
#import <UIKit/UIKit.h>

// 单个文字块：文本 + 在图片中的归一化坐标（原点左下，0~1，Vision 坐标系）
@interface OCRBlock : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) CGRect normalizedBox; // {x,y,width,height} 均为 0~1
@end

@interface VisionOCR : NSObject
// 对图片做文字识别，返回纯文本。languages: 如 @[@"zh-Hans",@"zh-Hant",@"en-US"]
+ (void)recognizeImage:(UIImage *)image
             languages:(NSArray<NSString *> *)languages
            completion:(void (^)(NSString *text))completion;

// 返回带坐标的文字块，用于框选定位
+ (void)recognizeBlocks:(UIImage *)image
              languages:(NSArray<NSString *> *)languages
             completion:(void (^)(NSArray<OCRBlock *> *blocks))completion;
@end