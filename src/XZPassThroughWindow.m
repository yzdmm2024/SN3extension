//
//  XZPassThroughWindow.m — 触摸穿透窗口实现
//

#import "XZPassThroughWindow.h"

@implementation XZPassThroughWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _passthrough = NO;
        _interactiveViews = [NSMutableArray array];
        _passRect = CGRectZero;
    }
    return self;
}

- (void)addInteractiveView:(UIView *)view {
    if (!view) return;
    if (![_interactiveViews containsObject:view]) {
        [_interactiveViews addObject:view];
    }
}

// 判断命中视图 view 是否属于交互白名单（自身或其任一祖先在白名单里）
- (BOOL)isDescendantOfInteractive:(UIView *)view {
    UIView *t = view;
    NSInteger guard = 0;
    while (t && guard++ < 32) {
        for (UIView *iv in _interactiveViews) {
            if (iv == t) return YES;
        }
        t = t.superview;
    }
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];

    // 非穿透模式：完全按系统默认行为（普通框选阶段需要吃下全屏拖拽）
    if (!_passthrough) return hit;

    // v5.12：仅交互白名单子树可响应，其余全部穿透（功能面板用：面板外可拖选区框）
    if (_gateInteractive) {
        UIView *g = hit;
        if (g && [self isDescendantOfInteractive:g]) return g;
        return nil;
    }

    // 命中白名单视图（顶部入口栏、生成长图/取消按钮、计数标签）→ 正常响应
    if (hit && [self isDescendantOfInteractive:hit]) return hit;

    // 落在实时预览框内 → 穿透给下层 App，可直接滑动页面
    if (CGRectContainsPoint(_passRect, point)) return nil;

    // 框外暗色区：吞掉触摸，避免误触下层 App
    return self;
}

@end
