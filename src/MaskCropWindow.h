//
//  MaskCropWindow.h — 窗口A：遮罩镂空框选 + 长截图实时预览框
//
//  【v4.6 交互】
//   1. 点击控制中心「超级截图」→ 拉起本窗口：全屏半黑变暗，底层保留真实 App 画面。
//   2. 默认即「局部截图」模式：拖拽绘制矩形选区，松手【立即】裁出选区并弹窗口B
//      两排编辑工具栏（不再需要二次确认按钮）。顶部小入口栏可切【正常截图】【长截图】。
//   3. 正常截图：仿系统电源+音量键截整屏直接存相册，不弹编辑。
//   4. 长截图：点【长截图】直接弹全屏宽「截取框」；框内触摸穿透可滑动底层 App 实时预览；
//      框外只有【生成长图】【取消】两按钮；自动抓帧定时器(~0.4s)按帧采集、重叠去重，
//      框内滑动即完成范围选取，取消标尺与手动采集。
//   5. 任何抓帧前必须临时隐藏边框，绝不把暗色/控件截进图片。
//   6. 退出时完整销毁窗口并置空，防 SpringBoard 内存泄漏 / respring。
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XZMaskMode) {
    XZMaskModeCrop = 0,   // 普通矩形框选
    XZMaskModeLong,       // 长截图调节（双标尺）
};

@interface MaskCropWindow : NSObject

+ (instancetype)sharedInstance;

// 弹出窗口A（控制中心点按「超级截图」后调用）
- (void)show;

// 完整销毁窗口A（置空所有引用）
- (void)dismiss;

// 当前矩形选区（屏幕点坐标）
- (CGRect)cropRect;

// 是否已有有效选区
- (BOOL)hasSelection;

@end
