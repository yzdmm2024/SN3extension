//
//  SN3CCModule.m — 控制中心截图模块
//
//  架构与 Snapper3 官方 CC 模块（Snapper3CCSupportFreeze 等）完全一致：
//    1. 编译期直接继承 CCUIToggleModule（符号延迟解析，加载时由
//       ControlCenterUIKit 提供，Makefile 中 PRIVATE_FRAMEWORKS 显式链接）
//    2. 模块本身只做一件事：被点按时发一条 darwin 通知
//       com.axs.snapper3zhext.cc.capture
//    3. 真正的截屏 + 浮动菜单由主 tweak（Tweak.xm，SpringBoard 内）监听执行
//
//  Info.plist 要求：NSPrincipalClass = SN3CCModule（与类名一致）。
//  该 bundle 放 /var/jb/Library/ControlCenter/Bundles/，由 CCSupport 加载。
//

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 私有类前向声明（不链接头文件，运行时由 ControlCenterUIKit 解析）
@interface CCUIToggleModule : NSObject
@end

@interface SN3CCModule : CCUIToggleModule
@property (nonatomic, assign) BOOL selected;   // 覆盖父类 selected，自身持 ivar
@end

@implementation SN3CCModule
@synthesize selected = _selected;

- (instancetype)init {
    if ((self = [super init])) {
        // iconGlyph / selectedColor 是父类私有属性，用 KVC 赋值最稳
        // （Snapper3 官方模块同样只用字符串 key，无 setter 选择器依赖）
        UIImage *glyph = [UIImage systemImageNamed:@"camera.viewfinder"];
        if (!glyph) glyph = [UIImage systemImageNamed:@"camera.fill"];
        [self setValue:glyph forKey:@"iconGlyph"];
        [self setValue:[UIColor systemBlueColor] forKey:@"selectedColor"];
        _selected = NO;
    }
    return self;
}

// 控制中心点按 → CCUIToggleModule 内部调用 setSelected:YES
// 这里拦截：发通知后立刻回弹为 NO（按钮型模块，不是状态开关）
- (void)setSelected:(BOOL)selected {
    _selected = selected;
    if (selected) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.axs.snapper3zhext.cc.capture"),
            NULL, NULL, TRUE);
        _selected = NO;
    }
}

@end
