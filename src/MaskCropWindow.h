//
//  MaskCropWindow.h — 窗口A：遮罩镂空框选 + 长截图双标尺调节
//
//  【规格书对照】
//   1. 点击控制中心「超级截图」→ 不立刻截图，拉起本窗口：全屏半黑变暗，
//      底层保留真实 App 画面（CAShapeLayer evenOdd 镂空，不贴静态截图）。
//   2. 拖拽绘制矩形选区；松开手指后可按住框内部整体拖动（宽高不变、不能旋转）；
//      反向绘制自动矫正 CGRect；框不能超出屏幕。
//   3. 普通框选模式底部按钮：【长截图】【正常截图】【取消】
//      ⚠️ 这个阶段绝对不能出现 OCR/翻译那两排工具栏（两排工具栏只在窗口B）。
//   4. 长截图模式【复用本窗口，不新建独立窗口】：
//      · 选区左右边界与宽度完全锁死，禁止左右修改；
//      · 出现 2 条只能上下拖动的水平标尺（起始上线 / 结束下线），禁止横向移动；
//      · 底层 App 页面依旧可以正常上下滑动（靠 XZPassThroughWindow 穿透）；
//      · 底部按钮：【生成长图】【重置】【取消】。
//   5. 任何抓帧前必须临时隐藏遮罩，绝不把半透明黑截进图片。
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
