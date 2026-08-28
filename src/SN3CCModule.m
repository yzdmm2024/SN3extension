//
//  SN3CCModule.m — 控制中心截图模块
//
//  架构与 Snapper3 官方 CC 模块一致：
//    1. 编译期继承 CCUIToggleModule（符号延迟解析，运行时由 ControlCenterUIKit 提供）
//    2. 模块本身只做一件事：被点按时发一条 darwin 通知
//       com.axs.snapper3zhext.cc.capture
//    3. 真正的截屏 + 浮动菜单由主 tweak（Tweak.xm，SpringBoard 内）监听执行
//
//  关键修正（v3.07，修安全模式崩溃）：
//    - 绝不再 @property / @synthesize 一个 selected！父类 CCUIToggleModule 自带
//      selected 属性与 ivar，子类重复声明会改掉父类 ivar 布局，导致 setSelected:
//      调用时状态机错乱、SpringBoard 原生崩溃 → 进安全模式。
//    - setSelected: 只负责发通知，视觉状态交还给父类（始终回弹为未选中）。
//    - iconGlyph / selectedColor 用 KVC 赋值，包 @try（部分 iOS 版本为只读，忽略即可）。
//
//  Info.plist 要求：NSPrincipalClass = SN3CCModule（与类名一致）。
//  该 bundle 放 /var/jb/Library/ControlCenter/Bundles/，由 CCSupport 加载。
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 父类由 ControlCenterUIKit 在运行时提供，只前向声明我们用到的方法，
// 不要重复声明 selected 属性。
@interface CCUIToggleModule : NSObject
- (void)setSelected:(BOOL)arg1;
- (BOOL)isSelected;
@end

@interface SN3CCModule : CCUIToggleModule
@end

@implementation SN3CCModule

- (instancetype)init {
    self = [super init];
    if (self) {
        // 图标/颜色是父类私有属性，KVC 赋值；部分 iOS 版本只读或无此属性，
        // 失败就忽略（按钮依然可点，只是没图标）。
        @try {
            UIImage *glyph = [UIImage systemImageNamed:@"camera.viewfinder"];
            if (!glyph) glyph = [UIImage systemImageNamed:@"camera.fill"];
            if (glyph) [self setValue:glyph forKey:@"iconGlyph"];
            [self setValue:[UIColor systemBlueColor] forKey:@"selectedColor"];
        } @catch (NSException *e) {
            // 忽略：图标缺失不影响触发
        }
    }
    return self;
}

// 按钮型模块：点按一次即触发（不是持久开关）。
// 只发通知，视觉状态交给父类管理，并始终回弹为未选中。
- (void)setSelected:(BOOL)selected {
    if (selected) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.axs.snapper3zhext.cc.capture"),
            NULL, NULL, TRUE);
    }
    // 交还父类维护视觉状态；触发型按钮始终回弹为“未选中”
    [super setSelected:NO];
}

@end
