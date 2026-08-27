//
//  FloatingMenu.h — 截屏后浮动操作菜单
//

#import <UIKit/UIKit.h>

@interface FloatingMenu : NSObject

// 显示浮动菜单（传入截屏图片）
+ (void)showWithImage:(UIImage *)screenshot;

// 关闭菜单
+ (void)dismiss;

@end