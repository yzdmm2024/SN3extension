//
//  LongScreenshotPlugin.m — “长截图”动作：对当前页面主滚动区域做滚动拼接，
//  结果保存到相册并弹出结果浮层。
//
#import "LongScreenshotPlugin.h"
#import "LongShotController.h"
#import "ResultWindow.h"
#import "Common.h"
#import "ImageUtils.h"
#import <Photos/Photos.h>

@implementation LongScreenshotPlugin

- (NSString *)pluginIdentifier { return XZ_ID_LONG; }
- (BOOL)shouldRegister { return YES; }
- (UIImage *)imageForMenuAndSettings { return [Common systemIcon:@"arrow.up.left.and.arrow.down.right"]; }

- (void)runWithImage:(UIImage *)image {
    // 长截图基于实时屏幕，忽略传入的 Snapper 选区小图
    [Common toast:@"长截图拼接中…"];
    [LongShotController captureFromKeyWindowCompletion:^(UIImage *stitched) {
        if (!stitched) { [Common toast:@"长截图失败"]; return; }
        // 先预览，点击“保存到相册”再落盘
        [ResultWindow showWithTitle:@"长截图预览" text:[NSString stringWithFormat:@"尺寸 %.0f×%.0f\n点击下方保存到相册", stitched.size.width, stitched.size.height] image:stitched
                        actionTitle:@"保存到相册" onAction:^{
            [ImageUtils saveToCustomAlbum:stitched completion:^(BOOL ok, NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) [Common toast:@"已保存到相册「SN3截图」"];
                    else [Common toast:err ? [NSString stringWithFormat:@"保存失败：%@", err.localizedDescription] : @"保存失败"];
                });
            }];
        }];
    }];
}

@end