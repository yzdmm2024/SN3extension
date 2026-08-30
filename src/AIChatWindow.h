//
//  AIChatWindow.h — 问 AI 多轮对话浮层（保留上下文，可连续追问）
//
#import <UIKit/UIKit.h>

@interface AIChatWindow : NSObject
// firstText: 首轮问题（通常含 OCR 识别的图片文字）
+ (void)showWithTitle:(NSString *)title firstText:(NSString *)firstText;
// v6.20.4：带图问 AI —— image 非 nil 时，首条 user 消息写成多模态数组（文字 + image_url）
+ (void)showWithTitle:(NSString *)title firstText:(NSString *)firstText image:(UIImage *)image;
// 把截图里识别到的文字追加为对话上下文（v5.25.5：AI 对话按钮后台 OCR 后注入）
+ (void)appendContext:(NSString *)text;
+ (void)dismiss;
@end