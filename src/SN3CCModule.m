//
//  SN3CCModule.m — 控制中心截图模块（运行时动态创建 CCUIToggleModule 子类）
//  完全避免编译期链接 ControlCenterUIKit.framework
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "Common.h"
#import "FloatingMenu.h"
#import "ImageUtils.h"

// 在构造函数中动态创建 CCUIToggleModule 子类
__attribute__((constructor)) static void sn3_cc_init() {
    @autoreleasepool {
        // 检查是否在 SpringBoard 进程中
        NSString *procName = [NSProcessInfo processInfo].processName;
        if (![procName isEqualToString:@"SpringBoard"]) return;
        
        // 获取 CCUIToggleModule 类
        Class toggleClass = NSClassFromString(@"CCUIToggleModule");
        if (!toggleClass) {
            NSLog(@"[SN3] CCUIToggleModule not found, trying to load ControlCenterUIKit");
            // 尝试手动加载框架
            void *handle = dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit", RTLD_NOW);
            if (handle) {
                toggleClass = NSClassFromString(@"CCUIToggleModule");
                NSLog(@"[SN3] ControlCenterUIKit loaded: %@", toggleClass ? @"YES" : @"NO");
            }
            if (!toggleClass) return;
        }
        
        // 检查是否已注册
        Class existing = NSClassFromString(@"SN3CCModule");
        if (existing) return;
        
        // 动态创建子类
        Class newClass = objc_allocateClassPair(toggleClass, "SN3CCModule", 0);
        if (!newClass) {
            NSLog(@"[SN3] Failed to allocate SN3CCModule class");
            return;
        }
        
        // init 方法
        SEL initSel = @selector(init);
        class_addMethod(newClass, initSel, imp_implementationWithBlock(^(id self) {
            // 调用 super init
            id (*superInit)(id, SEL) = (void*)[toggleClass instanceMethodForSelector:initSel];
            self = superInit(self, initSel);
            if (self) {
                // 设置图标
                UIImage *glyph = [UIImage systemImageNamed:@"camera.viewfinder"];
                if (!glyph) glyph = [UIImage systemImageNamed:@"camera.fill"];
                [self setValue:glyph forKey:@"iconGlyph"];
                
                // 设置主题色
                [self setValue:[UIColor systemBlueColor] forKey:@"selectedColor"];
                
                // 默认未选中
                [self setValue:@NO forKey:@"selected"];
            }
            return self;
        }), "@@:");
        
        // buttonTapped: 方法
        SEL tapSel = @selector(buttonTapped:);
        class_addMethod(newClass, tapSel, imp_implementationWithBlock(^(id self, id arg) {
            // 调用 super buttonTapped:
            void (*superTap)(id, SEL, id) = (void*)[toggleClass instanceMethodForSelector:tapSel];
            if (superTap) superTap(self, tapSel, arg);
            
            // 延迟后截屏
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    UIImage *ss = [ImageUtils captureScreen];
                    if (ss) {
                        [FloatingMenu showWithImage:ss];
                    }
                } @catch (NSException *e) {
                    NSLog(@"[SN3] CC screenshot error: %@ %@", e.name, e.reason);
                }
            });
            
            // 重置选中状态
            [self setValue:@NO forKey:@"selected"];
        }), "v@:@");
        
        // 注册类
        objc_registerClassPair(newClass);
        NSLog(@"[SN3] SN3CCModule CC module registered");
    }
}