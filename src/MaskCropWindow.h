//
//  MaskCropWindow.h — 窗口A：遮罩镂空框选
//  全屏半透明黑遮罩，底层真实 App 画面透过来；手指画矩形选区（CAShapeLayer 镂空+蓝框）
//  底部三按钮：长截图 / 正常截图 / 取消；长截图模式下切换为采集工具栏。
//

#import <UIKit/UIKit.h>

@interface MaskCropWindow : NSObject

+ (instancetype)sharedInstance;

// 弹出遮罩框选窗口（控制中心点按「超级截图」后调用）
- (void)show;

// 完整销毁窗口A（置空所有引用，防 SpringBoard 内存泄漏）
- (void)dismiss;

// 当前矩形选区（屏幕坐标，点）
- (CGRect)cropRect;

// 是否已有有效选区
- (BOOL)hasSelection;

@end
