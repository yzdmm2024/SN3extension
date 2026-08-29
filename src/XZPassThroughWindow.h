//
//  XZPassThroughWindow.h — 触摸穿透窗口（超级截图 v4.1+）
//
//  为什么需要它：
//    规格书要求「长截图调节阶段，底层 App 页面依旧可以正常上下滑动」。
//    但普通 UIWindow 的 hitTest:withEvent: 在命中空白区时会返回【窗口自身】，
//    于是触摸被 SpringBoard 吃掉、下发不到下层 App，页面根本滑不动。
//
//  解决：重写 hitTest。穿透模式开启时：
//    · 命中窗口自身 / 非交互子视图：
//        - 若落在 passRect（长截图实时预览框）内 → 返回 nil（触摸穿透到下层 App 窗口，可滑动）；
//        - 否则返回 self（触摸被本窗口吞掉，框外暗色区不发生误触）。
//    · 命中白名单视图（顶部入口栏、生成长图/取消按钮、计数标签）→ 正常返回，按钮可用。
//
//  调用关系：
//    MaskCropWindow 创建本类实例作为「窗口A」，进入长截图实时预览时
//    passthrough = YES 且 passRect = 截取框；普通框选阶段 passthrough = NO。
//

#import <UIKit/UIKit.h>

@interface XZPassThroughWindow : UIWindow

// 是否开启触摸穿透（长截图实时预览 = YES；普通框选 = NO）
@property (nonatomic, assign) BOOL passthrough;

// v5.12：仅「交互白名单及其子视图」可响应触摸，其余位置一律穿透给下层窗口。
//        用于功能面板：面板只占它自己那一块，其余区域（选区框）可直接拖动。
@property (nonatomic, assign) BOOL gateInteractive;

// 穿透模式下仍然要接收触摸的视图集合（工具栏、按钮、HUD）
@property (nonatomic, strong) NSMutableArray<UIView *> *interactiveViews;

// 长截图实时预览框（窗口坐标）：落在框内才让下层 App 收到触摸，其余区域吞掉
@property (nonatomic, assign) CGRect passRect;

// 注册一个「穿透模式下依然可交互」的视图
- (void)addInteractiveView:(UIView *)view;

@end
