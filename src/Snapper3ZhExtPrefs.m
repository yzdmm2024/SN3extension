//
//  Snapper3ZhExtPrefs.m — 设置面板（运行时动态创建 PSViewController 子类）
//  PSViewController 是 PreferenceLoader 正确基类，不会触发
//  "There appears to be an error with these preferences!" 错误
//  完全参考 NotifyManager 的 NTMPrincipalController 方案
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// 在构造函数中动态创建 PSViewController 子类
__attribute__((constructor)) static void sn3_prefs_init() {
    @autoreleasepool {
        // 获取 PSViewController 类
        Class psCtrl = NSClassFromString(@"PSViewController");
        if (!psCtrl) {
            void *handle = dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
            if (handle) {
                psCtrl = NSClassFromString(@"PSViewController");
            }
            if (!psCtrl) {
                NSLog(@"[SN3] PSViewController not found");
                return;
            }
        }
        
        // 检查是否已注册
        Class existing = NSClassFromString(@"SN3PrefsController");
        if (existing) return;
        
        // 动态创建子类
        Class newClass = objc_allocateClassPair(psCtrl, "SN3PrefsController", 0);
        if (!newClass) {
            NSLog(@"[SN3] Failed to allocate SN3PrefsController class");
            return;
        }
        
        // 添加 ivar 用于存储数据
        class_addIvar(newClass, "_tableView", sizeof(id), rint(log2(sizeof(id))), @encode(id));
        class_addIvar(newClass, "_sections", sizeof(id), rint(log2(sizeof(id))), @encode(id));
        
        // viewDidLoad 方法
        SEL viewDidLoadSel = @selector(viewDidLoad);
        Method superViewDidLoadMethod = class_getInstanceMethod(psCtrl, viewDidLoadSel);
        IMP superViewDidLoad = method_getImplementation(superViewDidLoadMethod);
        
        class_addMethod(newClass, viewDidLoadSel, imp_implementationWithBlock(^(id self) {
            // 调用 super viewDidLoad
            ((void(*)(id, SEL))superViewDidLoad)(self, viewDidLoadSel);
            
            // 设置标题
            [self setTitle:@"SN3延伸板"];
            
            self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1];
            
            // 构建数据
            NSArray *sections = @[
                @{@"title": @"API 配置", @"rows": @[
                    @{@"label": @"百度翻译 AppID", @"key": @"trans_appid", @"placeholder": @"输入百度翻译 AppID"},
                    @{@"label": @"百度翻译密钥", @"key": @"trans_key", @"placeholder": @"输入百度翻译密钥"},
                    @{@"label": @"AI 接口地址", @"key": @"ai_baseurl", @"placeholder": @"如 https://api.openai.com/v1"},
                    @{@"label": @"AI API Key", @"key": @"ai_apikey", @"placeholder": @"sk-..."},
                    @{@"label": @"AI 模型", @"key": @"ai_model", @"placeholder": @"如 gpt-4o-mini"},
                ]},
                @{@"title": @"OCR 配置", @"rows": @[
                    @{@"label": @"OCR 语言", @"key": @"ocr_lang", @"placeholder": @"zh-Hans,zh-Hant,en-US"},
                ]},
                @{@"title": @"关于", @"rows": @[
                    @{@"label": @"版本", @"key": @"version", @"placeholder": @"3.04"},
                    @{@"label": @"说明", @"key": @"info", @"placeholder": @"独立插件，截屏弹出浮动菜单"},
                ]},
            ];
            
            object_setIvar(self, class_getInstanceVariable([self class], "_sections"), sections);
            
            UITableView *tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
            tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            tv.backgroundColor = [UIColor clearColor];
            tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
            tv.dataSource = (id)self;
            tv.delegate = (id)self;
            [self.view addSubview:tv];
            
            object_setIvar(self, class_getInstanceVariable([self class], "_tableView"), tv);
        }), "v@:");
        
        // PSController 协议桩方法（必须实现，否则 PreferenceLoader 崩溃）
        SEL stubSels[] = {
            @selector(setRootController:),
            @selector(setParentController:),
            @selector(setSpecifier:),
            @selector(setPreferenceLoader:),
        };
        for (int i = 0; i < 4; i++) {
            class_addMethod(newClass, stubSels[i], imp_implementationWithBlock(^(id self, id arg){}), "v@:@");
        }
        // setParentController:specifier:
        SEL setParentSpecSel = NSSelectorFromString(@"setParentController:specifier:");
        class_addMethod(newClass, setParentSpecSel, imp_implementationWithBlock(^(id self, id parent, id spec){}), "v@:@@");
        
        // UITableViewDataSource 方法
        SEL numberOfSectionsSel = @selector(numberOfSectionsInTableView:);
        class_addMethod(newClass, numberOfSectionsSel, imp_implementationWithBlock(^NSInteger(id self, UITableView *tv) {
            NSArray *s = object_getIvar(self, class_getInstanceVariable([self class], "_sections"));
            return s.count;
        }), "l@:@");
        
        SEL numberOfRowsSel = @selector(tableView:numberOfRowsInSection:);
        class_addMethod(newClass, numberOfRowsSel, imp_implementationWithBlock(^NSInteger(id self, UITableView *tv, NSInteger sec) {
            NSArray *s = object_getIvar(self, class_getInstanceVariable([self class], "_sections"));
            return [s[sec][@"rows"] count];
        }), "l@:@l");
        
        SEL cellForRowSel = @selector(tableView:cellForRowAtIndexPath:);
        class_addMethod(newClass, cellForRowSel, imp_implementationWithBlock(^id(id self, UITableView *tv, NSIndexPath *ip) {
            NSArray *s = object_getIvar(self, class_getInstanceVariable([self class], "_sections"));
            NSDictionary *row = s[ip.section][@"rows"][ip.row];
            NSString *key = row[@"key"];
            
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = row[@"label"];
            cell.textLabel.font = [UIFont systemFontOfSize:15];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor whiteColor];
            
            if ([key isEqualToString:@"version"] || [key isEqualToString:@"info"]) {
                cell.detailTextLabel.text = row[@"placeholder"];
                cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
            } else {
                UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
                tf.placeholder = row[@"placeholder"];
                tf.font = [UIFont systemFontOfSize:14];
                tf.textAlignment = NSTextAlignmentRight;
                tf.textColor = [UIColor colorWithWhite:0.4 alpha:1];
                tf.returnKeyType = UIReturnKeyDone;
                tf.clearButtonMode = UITextFieldViewModeWhileEditing;
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
                tf.tag = ip.section * 100 + ip.row;
                
                // 读取已保存的值
                NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.axs.snapper3zhext"];
                NSString *saved = [prefs stringForKey:[NSString stringWithFormat:@"SN3_%@", key]] ?: @"";
                tf.text = saved;
                
                // 保存回调
                [tf addTarget:self action:NSSelectorFromString(@"textFieldDidEndEditing:") forControlEvents:UIControlEventEditingDidEnd];
                
                cell.accessoryView = tf;
            }
            
            return cell;
        }), "@@:@@");
        
        SEL titleForHeaderSel = @selector(tableView:titleForHeaderInSection:);
        class_addMethod(newClass, titleForHeaderSel, imp_implementationWithBlock(^id(id self, UITableView *tv, NSInteger sec) {
            NSArray *s = object_getIvar(self, class_getInstanceVariable([self class], "_sections"));
            return s[sec][@"title"];
        }), "@@:@l");
        
        // textFieldDidEndEditing:
        SEL textFieldEndSel = @selector(textFieldDidEndEditing:);
        class_addMethod(newClass, textFieldEndSel, imp_implementationWithBlock(^(id self, UITextField *tf) {
            NSArray *s = object_getIvar(self, class_getInstanceVariable([self class], "_sections"));
            NSInteger sec = tf.tag / 100;
            NSInteger row = tf.tag % 100;
            if (sec < s.count && row < [s[sec][@"rows"] count]) {
                NSString *key = s[sec][@"rows"][row][@"key"];
                if (![key isEqualToString:@"version"] && ![key isEqualToString:@"info"]) {
                    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.axs.snapper3zhext"];
                    [prefs setObject:tf.text ?: @"" forKey:[NSString stringWithFormat:@"SN3_%@", key]];
                    [prefs synchronize];
                }
            }
        }), "v@:@");
        
        // 注册类
        objc_registerClassPair(newClass);
        NSLog(@"[SN3] SN3PrefsController registered (PSViewController subclass)");
    }
}