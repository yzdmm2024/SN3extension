//
//  OCRBoxWindow.h — 识别结果框选定位：在原图上按文字块画高亮框，点框复制该处文字
//
#import <UIKit/UIKit.h>
#import "VisionOCR.h"

@interface OCRBoxWindow : NSObject
+ (void)showForImage:(UIImage *)image blocks:(NSArray<OCRBlock *> *)blocks;
+ (void)dismiss;
@end