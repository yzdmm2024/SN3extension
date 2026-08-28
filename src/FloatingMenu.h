//
//  FloatingMenu.h — 截屏后浮动操作菜单
//

#import <UIKit/UIKit.h>

@interface FloatingMenu : NSObject

// 显示选择器（传入截屏图片）：长截图 / 自由截图 两个图标
+ (void)showChooser:(UIImage *)screenshot;

// 显示操作行（传入已选图片）：OCR/翻译/问AI/保存/复制/分享/悬浮/重截
+ (void)showActionRow:(UIImage *)image;

// 关闭所有 SN3 窗口
+ (void)dismissAll;

@end
