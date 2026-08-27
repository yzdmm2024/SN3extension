//
//  SN3CCModule.m — 控制中心截图模块
//  CCUIToggleModule 子类，点击触发截屏 + 浮动菜单
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Common.h"
#import "FloatingMenu.h"
#import "ImageUtils.h"

// CCUIToggleModule 声明（ControlCenterUIKit 私有框架）
@interface CCUIToggleModule : NSObject
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, copy) UIColor *selectedColor;
@property (nonatomic, strong) UIImage *iconGlyph;
- (void)buttonTapped:(id)arg1;
@end

@interface SN3CCModule : CCUIToggleModule
@end

@implementation SN3CCModule

- (instancetype)init {
    self = [super init];
    if (self) {
        // 设置图标 - 使用 SF Symbol
        UIImage *glyph = [UIImage systemImageNamed:@"camera.viewfinder"];
        if (!glyph) glyph = [UIImage systemImageNamed:@"camera.fill"];
        self.iconGlyph = glyph;
        
        // 设置主题色
        self.selectedColor = [UIColor systemBlueColor];
        
        // 默认未选中
        self.selected = NO;
    }
    return self;
}

- (void)buttonTapped:(id)arg1 {
    [super buttonTapped:arg1];
    
    // 延迟一小段时间后截屏
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIImage *screenshot = [ImageUtils captureScreen];
            if (screenshot) {
                [FloatingMenu showWithImage:screenshot];
            }
        } @catch (NSException *e) {
            NSLog(@"[SN3] CC module screenshot failed: %@ %@", e.name, e.reason);
        }
    });
    
    // 重置选中状态
    self.selected = NO;
}

@end