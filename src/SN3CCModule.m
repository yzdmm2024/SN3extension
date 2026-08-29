//
//  SN3CCModule.m — 控制中心截图模块
//
//  架构与 Snapper3 官方 CC 模块一致：
//    1. 编译期继承 CCUIToggleModule（符号延迟解析，运行时由 ControlCenterUIKit 提供）
//    2. 模块本身只做一件事：被点按时发一条 darwin 通知
//       com.axs.snapper3zhext.cc.capture
//    3. 真正的截屏 + 浮动菜单由主 tweak（Tweak.xm，SpringBoard 内）监听执行
//
//  关键修正（v3.09，修控制中心“空白/无图标/点不动”）：
//    - 之前用 KVC 给 iconGlyph 赋值，但现代 iOS 里 iconGlyph 多为只读属性，
//      setValue:forKey: 抛异常被 @try 吞掉 → 图标为 nil → 按钮既不显示也不响应点击。
//    - 现改为覆盖 glyphImageForState:（控制中心取图标的标准方法），并提供
//      SF Symbol → Core Graphics 兜底，保证永远返回非空图标，按钮必可点。
//    - 老 iOS 仍尝试 KVC 赋值 iconGlyph（可写时生效），双路兜底。
//
//  注意：绝不可 @property/@synthesize 一个 selected！父类 CCUIToggleModule 自带
//  该属性与 ivar，子类重复声明会改掉父类 ivar 布局，导致 setSelected: 状态机错乱、
//  SpringBoard 原生崩溃 → 进安全模式（v3.07 的坑）。
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

// 父类由 ControlCenterUIKit 在运行时提供，只前向声明用到的方法/返回类型。
@interface CCUIToggleModule : NSObject
- (void)setSelected:(BOOL)arg1;
- (BOOL)isSelected;
- (UIImage *)glyphImageForState:(UIControlState)state;
@end

// 关闭 SpringBoard 控制中心（iOS 13-16 均由 SBControlCenterController 管理）。
// 点按我们的模块后必须先把控制中心收起，否则截到的永远是控制中心界面。
static void SN3_DismissControlCenter(void) {
    @try {
        Class cls = NSClassFromString(@"SBControlCenterController");
        id cc = nil;
        if (cls) {
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                cc = [cls performSelector:@selector(sharedInstance)];
            } else if ([cls respondsToSelector:@selector(_sharedInstance)]) {
                cc = [cls performSelector:@selector(_sharedInstance)];
            }
        }
        if (!cc) { NSLog(@"[SN3] SBControlCenterController not found"); return; }
        SEL s1 = NSSelectorFromString(@"dismissAnimated:");
        if ([cc respondsToSelector:s1]) {
            ((void(*)(id, SEL, BOOL))objc_msgSend)(cc, s1, YES);
            NSLog(@"[SN3] control center dismissed (dismissAnimated:)");
            return;
        }
        SEL s2 = NSSelectorFromString(@"dismissAnimated:completion:");
        if ([cc respondsToSelector:s2]) {
            ((void(*)(id, SEL, BOOL, id))objc_msgSend)(cc, s2, YES, nil);
            NSLog(@"[SN3] control center dismissed (dismissAnimated:completion:)");
        }
    } @catch (NSException *e) {
        NSLog(@"[SN3] dismiss CC failed: %@ %@", e.name, e.reason);
    }
}

// 图标加载：优先用用户提供的模板 PNG（"/var/jb/Library/Snapper3ZhExt.bundle/Resources/icon.png"），
// 失败则用 SF Symbol 兜底，再失败则 Core Graphics 现场画一个蓝底相机。
static UIImage *SN3GlyphImage(void) {
    // v5.25.5：SF Symbol 优先，保证现代系统一定有图标（不再依赖可能缺失/损坏的自定义 PNG）
    UIImage *g = [UIImage systemImageNamed:@"camera.viewfinder"];
    if (g) return g;
    g = [UIImage systemImageNamed:@"camera.fill"];
    if (g) return g;
    // 可选：用户自定义模板 PNG（仅当存在且有效才用，避免坏图导致图标空白）
    NSString *bundlePath = @"/var/jb/Library/Snapper3ZhExt.bundle";
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (bundle) {
        UIImage *custom = [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil];
        if (custom && custom.size.width > 1) {
            return [custom imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(64.0, 64.0), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        [[UIColor systemBlueColor] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(2.0, 2.0, 60.0, 60.0));
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, CGRectMake(22.0, 26.0, 20.0, 14.0));   // 机身
        CGContextFillRect(ctx, CGRectMake(28.0, 20.0, 8.0, 8.0));    // 顶部凸起
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img ?: [[UIImage alloc] init];
}

@interface SN3CCModule : CCUIToggleModule
@end

@implementation SN3CCModule

- (instancetype)init {
    self = [super init];
    if (self) {
        // 老 iOS：iconGlyph 可写，直接赋值；失败忽略（现代 iOS 走 glyphImageForState:）
        @try { [self setValue:SN3GlyphImage() forKey:@"iconGlyph"]; } @catch (NSException *e) {}
        @try { [self setValue:[UIColor systemBlueColor] forKey:@"selectedColor"]; } @catch (NSException *e) {}
    }
    return self;
}

// 现代 iOS 控制中心取图标的标准入口：覆盖它最稳，确保按钮永远有图标、可点。
- (UIImage *)glyphImageForState:(UIControlState)state {
    return SN3GlyphImage();
}

// 触发型按钮：点按一次即触发（不是持久开关）。
// 1) 先关闭控制中心（否则截图永远是控制中心界面）；
// 2) 等收起动画完成后（~0.35s）再发通知，Tweak 截到的就是真实屏幕。
- (void)setSelected:(BOOL)selected {
    if (selected) {
        NSLog(@"[SN3] CC module tapped -> dismiss CC, post com.axs.snapper3zhext.cc.capture");
        SN3_DismissControlCenter();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.axs.snapper3zhext.cc.capture"),
                NULL, NULL, TRUE);
        });
    }
    // 交还父类维护视觉状态；触发型按钮始终回弹为“未选中”
    [super setSelected:NO];
}

@end
