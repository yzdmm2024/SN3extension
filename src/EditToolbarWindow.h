//
//  EditToolbarWindow.h — 窗口B：截图编辑两排工具栏
//  第一排（识别编辑）：OCR · 翻译 · 画图 · 识码 · 打码
//  第二排（输出操作）：复制 · 贴图 · 保存 · 分享 · 更多
//  更多二级弹窗：长截图 · 导出PDF · 压缩 · 去状态栏 · 取色器
//

#import <UIKit/UIKit.h>

@interface EditToolbarWindow : NSObject

// 用已裁剪图片弹窗口B（正常截图 / 长截图拼接完成后调用）
+ (void)showWithImage:(UIImage *)image;

// 销毁窗口B
+ (void)dismiss;

@end
