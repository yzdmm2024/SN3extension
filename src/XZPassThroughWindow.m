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

    // 没命中任何东西：直接穿透
    if (!hit) return nil;

    // 命中窗口自身（说明点在了空白区）：穿透，让下层 App 收到触摸
    if (hit == self) return nil;

    // 命中子视图：只有白名单（工具栏/标尺/HUD）里的才保留，其余穿透
    if ([self isDescendantOfInteractive:hit]) return hit;
    return nil;
}

@end
