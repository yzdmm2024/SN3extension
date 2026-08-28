//
//  EditToolbarWindow.h — 窗口B：截图编辑两排工具栏
//
//  【规格书对应】
//   只有「截图 / 长图生成完成之后」才弹出本窗口。框选、长截图调节阶段绝不出现。
//
//   第一排（识别编辑）：OCR · 翻译 · 画图 · 识码 · 打码
//   第二排（输出操作）：复制 · 贴图 · 保存 · 分享 · 更多
//   「更多」二级弹窗：导出PDF · 压缩 · 去状态栏 · 取色器
//
//  调用关系：
//    MaskCropWindow（正常截图 / 长截图拼接完成）
//        └─> [EditToolbarWindow showWithImage:]
//                 └─> toolTapped ──> SuperTools.*（OCR/翻译/画图/识码/打码/…）
//                 └─> showMoreMenu ──> SuperTools.exportPDF/compress/stripStatusBar/colorPicker
//

#import <UIKit/UIKit.h>

@interface EditToolbarWindow : NSObject

// 用已裁剪 / 已拼接好的图片弹窗口B
+ (void)showWithImage:(UIImage *)image;

// 销毁窗口B（置空所有引用，防 SpringBoard 内存泄漏）
+ (void)dismiss;

@end
