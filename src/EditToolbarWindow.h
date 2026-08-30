//
//  EditToolbarWindow.h — 窗口B：截图编辑两排工具栏
//
//  【规格书对应】
//   只有「截图 / 长图生成完成之后」才弹出本窗口。框选、长截图调节阶段绝不出现。
//
//   三排工具栏（全部平铺，无二级菜单）：
//     第1排（识别编辑）：OCR · 翻译 · 画图 · 识码 · 打码
//     第2排（输出操作）：复制 · 贴图 · 保存 · 分享 · 加壳
//     第3排（更多工具）：PDF · 压缩 · 打开豆包 · 取色 · 还原
//
//  调用关系：
//    MaskCropWindow（正常截图 / 长截图拼接完成）
//        └─> [EditToolbarWindow showWithImage:]
//                 └─> toolTapped ──> SuperTools.*（OCR/翻译/画图/识码/打码/复制/贴图/保存/分享/加壳/PDF/压缩/打开豆包/取色/还原）
//

#import <UIKit/UIKit.h>

@interface EditToolbarWindow : NSObject

// 用已裁剪 / 已拼接好的图片弹窗口B
+ (void)showWithImage:(UIImage *)image;

// 销毁窗口B（置空所有引用，防 SpringBoard 内存泄漏）
+ (void)dismiss;

@end
