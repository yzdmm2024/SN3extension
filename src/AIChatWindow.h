//
//  AIChatWindow.h — 问 AI 多轮对话浮层（保留上下文，可连续追问）
//
#import <UIKit/UIKit.h>

@interface AIChatWindow : NSObject
// firstText: 首轮问题（通常含 OCR 识别的图片文字）
+ (void)showWithTitle:(NSString *)title firstText:(NSString *)firstText;
+ (void)dismiss;
@end