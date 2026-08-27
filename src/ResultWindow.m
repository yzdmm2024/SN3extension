//
//  ResultWindow.m
//
#import "ResultWindow.h"
#import "Common.h"
#import <QuartzCore/QuartzCore.h>

@interface ResultWindow ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, copy) dispatch_block_t actionBlock;
@end

@implementation ResultWindow

+ (instancetype)shared {
    static ResultWindow *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [ResultWindow new]; });
    return r;
}

+ (void)showWithTitle:(NSString *)title text:(NSString *)text image:(UIImage *)image {
    [[self shared] show:title text:text image:image actionTitle:nil onAction:nil];
}
+ (void)showWithTitle:(NSString *)title text:(NSString *)text image:(UIImage *)image
          actionTitle:(NSString *)actionTitle
             onAction:(dispatch_block_t)action {
    [[self shared] show:title text:text image:image actionTitle:actionTitle onAction:action];
}
+ (void)dismiss { [[self shared] hide]; }

- (void)show:(NSString *)title text:(NSString *)text image:(UIImage *)image
  actionTitle:(NSString *)actionTitle onAction:(dispatch_block_t)action {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideWithoutAnimation];
        UIWindow *base = [Common topWindow];
        CGRect b = base.bounds;
        self.actionBlock = action;
        UIWindow *w = [[UIWindow alloc] initWithFrame:b];
        w.windowLevel = base.windowLevel + 100;
        w.hidden = NO;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
                if ([sc isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)sc; break; }
            }
        }
        UIView *v = [[UIView alloc] initWithFrame:b];
        v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        w.rootViewController = [UIViewController new];
        [w.rootViewController.view addSubview:v];
        self.window = w;

        CGFloat sh = b.size.height * 0.55;
        UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height, b.size.width, sh)];
        sheet.backgroundColor = [UIColor systemBackgroundColor];
        if (@available(iOS 13.0, *)) {
            sheet.backgroundColor = [UIColor systemBackgroundColor];
        }
        sheet.layer.cornerRadius = 20;
        sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [v addSubview:sheet];
        self.sheet = sheet;

        // 顶部把手 + 标题
        CGFloat y = 14;
        UIView *grip = [[UIView alloc] initWithFrame:CGRectMake(b.size.width/2-24, 8, 48, 5)];
        grip.backgroundColor = [UIColor systemGray3Color];
        grip.layer.cornerRadius = 2.5;
        [sheet addSubview:grip];

        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, b.size.width-120, 24)];
        tl.text = title ?: @"结果";
        tl.font = [UIFont boldSystemFontOfSize:17];
        tl.textColor = [UIColor labelColor];
        [sheet addSubview:tl];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(b.size.width-56, y, 40, 24);
        [close setImage:[Common systemIcon:@"xmark.circle.fill"] forState:UIControlStateNormal];
        [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:close];

        y += 36;

        // 缩略图（可选）
        CGFloat th = 0;
        if (image) {
            CGFloat iw = 84;
            UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(16, y, iw, iw*0.8)];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.image = image;
            iv.layer.cornerRadius = 10;
            iv.clipsToBounds = YES;
            iv.backgroundColor = [UIColor systemGray6Color];
            [sheet addSubview:iv];
            self.thumb = iv;
            th = 70;
        }

        // 文本
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(12, y+th+8, b.size.width-24, sh-(y+th+8)-64)];
        tv.text = text ?: @"(无内容)";
        tv.font = [UIFont systemFontOfSize:16];
        tv.textColor = [UIColor labelColor];
        tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
        tv.layer.cornerRadius = 12;
        tv.editable = NO;
        tv.selectable = YES;
        [sheet addSubview:tv];
        self.textView = tv;

        // 底部操作按钮（有自定义动作时显示动作，否则复制文字）
        UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
        copy.frame = CGRectMake(16, sh-56, (b.size.width-48)/2, 44);
        copy.backgroundColor = [Common accentColor];
        copy.tintColor = [UIColor whiteColor];
        [copy setTitle:(actionTitle.length ? actionTitle : @"复制文字") forState:UIControlStateNormal];
        copy.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [copy setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        copy.layer.cornerRadius = 12;
        [copy addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:copy];

        UIButton *close2 = [UIButton buttonWithType:UIButtonTypeSystem];
        close2.frame = CGRectMake(16+(b.size.width-48)/2+16, sh-56, (b.size.width-48)/2, 44);
        close2.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [close2 setTitle:@"关闭" forState:UIControlStateNormal];
        [close2 setTitleColor:[UIColor systemGrayColor] forState:UIControlStateNormal];
        close2.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        close2.layer.cornerRadius = 12;
        [close2 addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:close2];

        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            sheet.frame = CGRectMake(0, b.size.height-sh, b.size.width, sh);
        } completion:nil];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped)];
        tap.cancelsTouchesInView = NO;
        [v addGestureRecognizer:tap];
    });
}

- (void)copyTapped {
    if (self.actionBlock) {
        dispatch_block_t act = self.actionBlock;
        [self hide];
        act();
        return;
    }
    if (self.textView && self.textView.text.length) {
        [UIPasteboard generalPasteboard].string = self.textView.text;
    }
    [Common toast:@"已复制"];
}

- (void)closeTapped { [self hide]; }

- (void)hideWithoutAnimation {
    [self.window.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.window.hidden = YES;
    self.window = nil;
    self.sheet = nil; self.textView = nil; self.thumb = nil; self.actionBlock = nil;
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.sheet) return;
        UIView *sheet = self.sheet;
        CGFloat h = self.window.bounds.size.height;
        [UIView animateWithDuration:0.25 animations:^{
            sheet.frame = CGRectMake(0, h, self.window.bounds.size.width, sheet.bounds.size.height);
            sheet.alpha = 0;
        } completion:^(BOOL f){ [self hideWithoutAnimation]; }];
    });
}

@end