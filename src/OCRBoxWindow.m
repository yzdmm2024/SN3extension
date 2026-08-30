//
//  OCRBoxWindow.m — 文字块高亮 + 点击复制。Vision 坐标系（原点左下、0~1）
//  转换为 UIKit 坐标系（原点左上），按 aspect-fit 缩放绘制。
//
#import "OCRBoxWindow.h"
#import "Common.h"
#import <QuartzCore/QuartzCore.h>

@interface OCRBoxWindow ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UIView *overlay;           // 承载高亮框的层，frame == imageView.frame
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *boxLayers;
@property (nonatomic, strong) NSArray<OCRBlock *> *blocks;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, strong) UILabel *selectedLabel;   // 底部当前选中文字
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *boxToBlock; // boxLayer 下标 -> block 下标
@end

@implementation OCRBoxWindow

+ (instancetype)shared {
    static OCRBoxWindow *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [OCRBoxWindow new]; });
    return r;
}

+ (void)showForImage:(UIImage *)image blocks:(NSArray<OCRBlock *> *)blocks {
    [[self shared] show:image blocks:blocks];
}
+ (void)dismiss { [[self shared] hide]; }

// aspect-fit：返回 dst 内保持比例、居中的显示矩形
static CGRect aspectFitRect(CGSize src, CGRect dst) {
    CGFloat scale = MIN(dst.size.width / MAX(src.width, 1), dst.size.height / MAX(src.height, 1));
    CGFloat w = src.width * scale;
    CGFloat h = src.height * scale;
    return CGRectMake(dst.origin.x + (dst.size.width - w) / 2,
                      dst.origin.y + (dst.size.height - h) / 2, w, h);
}

- (void)show:(UIImage *)image blocks:(NSArray<OCRBlock *> *)blocks {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideWithoutAnimation];
        self.blocks = blocks ?: @[];
        self.selectedIndex = -1;

        UIWindow *base = [Common topWindow];
        CGRect b = base.bounds;
        UIWindow *w = [[UIWindow alloc] initWithFrame:b];
        // v6.06：抬到 Alert+600（≈2600），稳盖过局部工具栏面板(_panelWin≈2000)，OCR 结果不再被工具栏挡住
        w.windowLevel = UIWindowLevelAlert + 600;
        w.hidden = NO;
        if (@available(iOS 13.0, *)) {
            UIScene *s = [[UIApplication sharedApplication] connectedScenes].allObjects.firstObject;
            if ([s isKindOfClass:[UIWindowScene class]]) w.windowScene = (UIWindowScene *)s;
        }
        UIView *vc = [UIView new];
        UIViewController *root = [UIViewController new];
        root.view = vc;
        w.rootViewController = root;
        self.window = w;

        UIView *dim = [[UIView alloc] initWithFrame:b];
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        [vc addSubview:dim];

        CGFloat sh = b.size.height * 0.84;
        UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height, b.size.width, sh)];
        sheet.backgroundColor = [UIColor systemBackgroundColor];
        sheet.layer.cornerRadius = 20;
        sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [vc addSubview:sheet];
        self.sheet = sheet;

        // 顶部：把手 + 标题 + 计数 + 关闭
        CGFloat y = 12;
        UIView *grip = [[UIView alloc] initWithFrame:CGRectMake(b.size.width/2-24, 8, 48, 5)];
        grip.backgroundColor = [UIColor systemGray3Color];
        grip.layer.cornerRadius = 2.5;
        [sheet addSubview:grip];

        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 160, 26)];
        tl.text = @"OCR 识别";
        tl.font = [UIFont boldSystemFontOfSize:18];
        tl.textColor = [UIColor labelColor];
        [sheet addSubview:tl];

        UILabel *cl = [[UILabel alloc] initWithFrame:CGRectMake(150, y+3, 60, 20)];
        cl.numberOfLines = 1;
        cl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        cl.textColor = [UIColor secondaryLabelColor];
        [sheet addSubview:cl];
        self.countLabel = cl;

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(b.size.width-56, y, 40, 28);
        if (@available(iOS 13.0, *)) [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        else [close setTitle:@"✕" forState:UIControlStateNormal];
        [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:close];

        y += 44;

        // 图片区
        CGRect imgRect = CGRectMake(12, y, b.size.width-24, sh - y - 96);
        UIView *imgArea = [[UIView alloc] initWithFrame:imgRect];
        imgArea.backgroundColor = [UIColor secondarySystemBackgroundColor];
        imgArea.layer.cornerRadius = 14;
        imgArea.clipsToBounds = YES;
        [sheet addSubview:imgArea];

        CGRect fit = image ? aspectFitRect(image.size, imgArea.bounds) : CGRectZero;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:fit];
        iv.image = image;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [imgArea addSubview:iv];

        // 高亮层（与图片同 frame）
        self.overlay = [[UIView alloc] initWithFrame:fit];
        self.overlay.userInteractionEnabled = NO;
        self.overlay.backgroundColor = [UIColor clearColor];
        [imgArea addSubview:self.overlay];

        // 画框 + 布局标签
        self.boxLayers = [NSMutableArray array];
        CGSize dv = fit.size;
        for (NSInteger i = 0; i < self.blocks.count; i++) {
            OCRBlock *blk = self.blocks[i];
            CGRect nb = blk.normalizedBox;
            CGRect local = CGRectMake(nb.origin.x * dv.width,
                                      (1 - nb.origin.y - nb.size.height) * dv.height,
                                      nb.size.width * dv.width,
                                      nb.size.height * dv.height);
            if (local.size.width < 4 || local.size.height < 4) continue;

            CAShapeLayer *layer = [CAShapeLayer layer];
            layer.frame = local;
            layer.path = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, local.size.width, local.size.height)].CGPath;
            layer.fillColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.12].CGColor;
            layer.strokeColor = [UIColor systemRedColor].CGColor;
            layer.lineWidth = 2;
            [self.overlay.layer addSublayer:layer];
            [self.boxLayers addObject:layer];
        }
        self.countLabel.text = [NSString stringWithFormat:@"%lu 块", (unsigned long)self.boxLayers.count];
        // self.blocks 与 boxLayers 已一一对应（跳过过小的），记录 boxIndex 到 blockIndex 映射
        self.boxToBlock = [NSMutableArray array];
        // 重建对应关系
        [self rebuildMapping];

        // 点击
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapOnImage:)];
        [iv addGestureRecognizer:tap];
        iv.userInteractionEnabled = YES;

        // 底栏
        CGFloat by = sh - 62;
        UIButton *copySel = [UIButton buttonWithType:UIButtonTypeSystem];
        copySel.frame = CGRectMake(12, by, (b.size.width-36)/2, 46);
        copySel.backgroundColor = [Common accentColor];
        [copySel setTitle:@"复制选中" forState:UIControlStateNormal];
        copySel.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [copySel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        copySel.layer.cornerRadius = 14;
        [copySel addTarget:self action:@selector(copySelected) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:copySel];

        UIButton *copyAll = [UIButton buttonWithType:UIButtonTypeSystem];
        copyAll.frame = CGRectMake(12+(b.size.width-36)/2+12, by, (b.size.width-36)/2, 46);
        copyAll.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [copyAll setTitle:@"复制全部" forState:UIControlStateNormal];
        copyAll.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [copyAll setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        copyAll.layer.cornerRadius = 14;
        [copyAll addTarget:self action:@selector(copyAll) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:copyAll];

        // 底部提示（当前选中文字）
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(16, sh-44, b.size.width-32, 40)];
        sl.numberOfLines = 2;
        sl.text = self.boxLayers.count ? @"点一下文字框可复制该处内容" : @"未识别到文字";
        sl.font = [UIFont systemFontOfSize:14];
        sl.textColor = [UIColor secondaryLabelColor];
        [sheet addSubview:sl];
        self.selectedLabel = sl;

        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ sheet.frame = CGRectMake(0, b.size.height-sh, b.size.width, sh); }
                         completion:nil];
    });
}

// 记录每个 boxLayer 对应的 block 下标
- (void)rebuildMapping {
    [_boxToBlock removeAllObjects];
    NSInteger layerIdx = 0;
    CGSize dv = self.overlay.frame.size;
    for (NSInteger i = 0; i < self.blocks.count; i++) {
        CGRect nb = self.blocks[i].normalizedBox;
        CGRect local = CGRectMake(nb.origin.x * dv.width, (1 - nb.origin.y - nb.size.height) * dv.height,
                                  nb.size.width * dv.width, nb.size.height * dv.height);
        if (local.size.width < 4 || local.size.height < 4) continue;
        if (layerIdx < self.boxLayers.count) {
            [_boxToBlock addObject:@(i)];
            layerIdx++;
        }
    }
}

- (void)tapOnImage:(UITapGestureRecognizer *)g {
    UIView *iv = g.view;
    CGPoint p = [g locationInView:iv];
    NSInteger hit = -1;
    for (NSInteger i = 0; i < self.boxLayers.count; i++) {
        if (CGRectContainsPoint([self.boxLayers[i] frame], p)) { hit = i; break; }
    }
    if (hit < 0) { [Common toast:@"点文字框复制对应内容"]; return; }
    self.selectedIndex = hit;
    NSInteger blockIdx = [(NSNumber *)self.boxToBlock[hit] integerValue];
    OCRBlock *blk = self.blocks[blockIdx];
    self.selectedLabel.text = blk.text;
    [self refreshHighlight:hit];
    [UIPasteboard generalPasteboard].string = blk.text;
    NSString *tip = blk.text.length > 26 ? [NSString stringWithFormat:@"%@…", [blk.text substringToIndex:26]] : blk.text;
    [Common toast:[NSString stringWithFormat:@"已复制：%@", tip]];
}

- (void)refreshHighlight:(NSInteger)selected {
    for (NSInteger i = 0; i < self.boxLayers.count; i++) {
        CAShapeLayer *layer = self.boxLayers[i];
        if (i == selected) {
            layer.lineWidth = 3.5;
            layer.strokeColor = [UIColor systemOrangeColor].CGColor;
            layer.fillColor = [UIColor colorWithRed:1 green:0.55 blue:0 alpha:0.22].CGColor;
        } else {
            layer.lineWidth = 2;
            layer.strokeColor = [UIColor systemRedColor].CGColor;
            layer.fillColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.10].CGColor;
        }
    }
}

- (void)copySelected {
    if (self.selectedIndex >= 0 && self.selectedIndex < self.boxLayers.count) {
        NSInteger blockIdx = [(NSNumber *)self.boxToBlock[self.selectedIndex] integerValue];
        [UIPasteboard generalPasteboard].string = self.blocks[blockIdx].text;
        [Common toast:@"已复制选中"];
        return;
    }
    [Common toast:@"请先点选一个文字框"];
}

- (void)copyAll {
    NSMutableString *all = [NSMutableString string];
    for (OCRBlock *b in self.blocks) {
        if (b.text.length) {
            if (all.length) [all appendString:@"\n"];
            [all appendString:b.text];
        }
    }
    if (all.length) { [UIPasteboard generalPasteboard].string = all; [Common toast:@"已复制全部"]; }
    else [Common toast:@"没有可复制的文字"];
}

- (void)closeTapped { [self hide]; }

- (void)hideWithoutAnimation {
    [self.window.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.window.hidden = YES;
    self.window = nil;
    self.sheet = nil; self.overlay = nil; self.boxLayers = nil;
    self.blocks = nil; self.boxToBlock = nil; self.selectedLabel = nil; self.countLabel = nil;
    self.selectedIndex = -1;
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.sheet) return;
        UIView *sheet = self.sheet;
        CGRect b = self.window.bounds;
        [UIView animateWithDuration:0.25 animations:^{
            sheet.frame = CGRectMake(0, b.size.height, b.size.width, sheet.bounds.size.height);
            sheet.alpha = 0;
        } completion:^(BOOL f){ [self hideWithoutAnimation]; }];
    });
}

@end