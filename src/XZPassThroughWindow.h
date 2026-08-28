//
//  XZPassThroughWindow.h — 触摸穿透窗口（超级截图 v4.1）
//
//  为什么需要它：
//    规格书要求「长截图调节阶段，底层 App 页面依旧可以正常上下滑动」。
//    但普通 UIWindow 的 hitTest:withEvent: 在命中空白区时会返回【窗口自身】，
//    于是触摸被 SpringBoard 吃掉、下发不到下层 App，页面根本滑不动
//    （v4.0 里 _touchView.userInteractionEnabled = NO 只是让全屏手势层不再响应，
//     窗口自己仍然会成为 hitTest 的结果，问题依旧）。
//
//  解决：重写 hitTest。穿透模式开启时：
//    · 命中窗口自身 / 非交互子视图 → 返回 nil（触摸穿透到下层 App 窗口）
//    · 命中白名单视图（底部工具栏、两条标尺、采集 HUD）→ 正常返回，按钮与拖动可用
//
//  调用关系：
//    MaskCropWindow 创建本类实例作为「窗口A」，进入长截图调节/自动采集时
//    passthrough = YES；普通框选阶段 passthrough = NO（需要全屏拖拽画框）。
//

#import <UIKit/UIKit.h>

@interface XZPassThroughWindow : UIWindow

// 是否开启触摸穿透（长截图调节 / 自动采集阶段 = YES；普通框选 = NO）
@property (nonatomic, assign) BOOL passthrough;

// 穿透模式下仍然要接收触摸的视图集合（工具栏、标尺、HUD）
@property (nonatomic, strong) NSMutableArray<UIView *> *interactiveViews;

// 注册一个「穿透模式下依然可交互」的视图
- (void)addInteractiveView:(UIView *)view;

@end
