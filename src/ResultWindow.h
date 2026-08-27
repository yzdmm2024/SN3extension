//
//  ResultWindow.h  — 可复用的结果浮层（半屏，可选文字，一键复制）
//
#import <UIKit/UIKit.h>

@interface ResultWindow : NSObject
+ (void)showWithTitle:(NSString *)title text:(NSString *)text image:(UIImage *)image;
// 带自定义动作按钮（如“保存到相册”），传 nil 时退化为“复制文字”
+ (void)showWithTitle:(NSString *)title text:(NSString *)text image:(UIImage *)image
          actionTitle:(NSString *)actionTitle
             onAction:(dispatch_block_t)action;
+ (void)dismiss;
@end