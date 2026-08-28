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

// 父类由 ControlCenterUIKit 在运行时提供，只前向声明用到的方法/返回类型。
@interface CCUIToggleModule : NSObject
- (void)setSelected:(BOOL)arg1;
- (BOOL)isSelected;
- (UIImage *)glyphImageForState:(UIControlState)state;
@end

// 保证返回一个非空图标：SF Symbol 优先，失败则用 Core Graphics 画一个蓝色圆底相机。
static UIImage *SN3GlyphImage(void) {
    UIImage *g = [UIImage systemImageNamed:@"camera.viewfinder"];
    if (g) return g;
    g = [UIImage systemImageNamed:@"camera.fill"];
    if (g) return g;

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
// 只发通知，视觉状态交还给父类，并始终回弹为未选中。
- (void)setSelected:(BOOL)selected {
    if (selected) {
        NSLog(@"[SN3] CC module tapped -> post com.axs.snapper3zhext.cc.capture");
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.axs.snapper3zhext.cc.capture"),
            NULL, NULL, TRUE);
    }
    // 交还父类维护视觉状态；触发型按钮始终回弹为“未选中”
    [super setSelected:NO];
}

@end
