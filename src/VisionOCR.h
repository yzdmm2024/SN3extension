//
//  VisionOCR.h — OCR 数据模型 + 识别入口（类型声明，供 OCRBoxWindow / 各 plugin 引用）
//
//  说明：本文件只声明类型与接口，不提供实现（识别实现在 ZhOCRPlugin / BigModel 等 plugin 内）。
//  主 OCR 入口自 v5.23.0 起已改走智谱 BigModel，本类仅作为数据载体与兼容接口保留。
//

#import <UIKit/UIKit.h>

// 单个识别文字块：归一化坐标(0~1, 原点左下, 与 Vision 一致) + 文本内容
@interface OCRBlock : NSObject
@property (nonatomic, assign) CGRect normalizedBox;   // 归一化包围盒 (0~1)
@property (nonatomic, copy)   NSString *text;         // 该块识别出的文字
@property (nonatomic, assign) float confidence;        // 置信度 (0~1, 可选)
@end

// OCR 识别入口（兼容接口；实际实现由 plugin 提供，tweak dylib 内不调用）
@interface VisionOCR : NSObject
+ (void)recognizeBlocks:(UIImage *)image
             languages:(NSArray<NSString *> *)langs
            completion:(void (^)(NSArray<OCRBlock *> *blocks))completion;
@end
