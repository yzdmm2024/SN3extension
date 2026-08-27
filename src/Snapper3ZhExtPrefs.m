//
//  Snapper3ZhExtPrefs.m — 设置面板（运行时动态创建 PSListController 子类）
//  避免编译期链接 Preferences.framework（CI 构建机没有此框架）
//  参考 Axon iOS 16 方案，但使用运行时技术避免链接依赖
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// 在构造函数中动态创建 PSListController 子类
__attribute__((constructor)) static void sn3_prefs_init() {
    @autoreleasepool {
        // 获取 PSListController 类
        Class psListCtrl = NSClassFromString(@"PSListController");
        if (!psListCtrl) {
            // 尝试加载 Preferences.framework
            void *handle = dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
            if (handle) {
                psListCtrl = NSClassFromString(@"PSListController");
            }
            if (!psListCtrl) {
                NSLog(@"[SN3] PSListController not found");
                return;
            }
        }
        
        // 检查是否已注册
        Class existing = NSClassFromString(@"SN3PrefsController");
        if (existing) return;
        
        // 动态创建子类
        Class newClass = objc_allocateClassPair(psListCtrl, "SN3PrefsController", 0);
        if (!newClass) {
            NSLog(@"[SN3] Failed to allocate SN3PrefsController class");
            return;
        }
        
        // specifiers 方法
        SEL specSel = @selector(specifiers);
        class_addMethod(newClass, specSel, imp_implementationWithBlock(^id(id self) {
            // 获取 _specifiers ivar
            Ivar ivar = class_getInstanceVariable(psListCtrl, "_specifiers");
            if (!ivar) {
                // 尝试使用 KVC
                id existing = [self valueForKey:@"specifiers"];
                if (existing) return existing;
            } else {
                id existing = object_getIvar(self, ivar);
                if (existing) return existing;
            }
            
            // 加载 Root.plist 中的 specifiers
            SEL loadSel = @selector(loadSpecifiersFromPlistName:target:);
            if ([self respondsToSelector:loadSel]) {
                id (*loadFunc)(id, SEL, NSString *, id) = (void*)[self methodForSelector:loadSel];
                NSArray *specs = loadFunc(self, loadSel, @"Root", self);
                if (specs) {
                    if (ivar) {
                        object_setIvar(self, ivar, specs);
                    } else {
                        [self setValue:specs forKey:@"specifiers"];
                    }
                }
                return specs;
            }
            
            return nil;
        }), "@@:");
        
        // viewDidLoad 方法
        SEL viewDidLoadSel = @selector(viewDidLoad);
        class_addMethod(newClass, viewDidLoadSel, imp_implementationWithBlock(^(id self) {
            // 调用 super viewDidLoad
            void (*superViewDidLoad)(id, SEL) = (void*)[psListCtrl instanceMethodForSelector:viewDidLoadSel];
            if (superViewDidLoad) superViewDidLoad(self, viewDidLoadSel);
            
            // 设置标题
            [self setTitle:@"SN3延伸板"];
        }), "v@:");
        
        // 注册类
        objc_registerClassPair(newClass);
        NSLog(@"[SN3] SN3PrefsController registered (runtime PSListController subclass)");
    }
}