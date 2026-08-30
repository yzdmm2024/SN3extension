//
//  AIChatWindow.m — 自底向上弹出的对话面板。保留 messages 上下文，底部输入框连续追问。
//
#import "AIChatWindow.h"
#import "AskAIEngine.h"
#import "Common.h"
#import <QuartzCore/QuartzCore.h>

@interface AIChatWindow ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UITextField *input;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *messages;
@property (nonatomic, copy) NSString *systemPrompt;
@property (nonatomic, assign) BOOL busy;
@end

@implementation AIChatWindow

+ (instancetype)shared {
    static AIChatWindow *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [AIChatWindow new]; });
    return c;
}

+ (void)showWithTitle:(NSString *)title firstText:(NSString *)firstText {
    [[self shared] show:title firstText:firstText image:nil];
}
+ (void)showWithTitle:(NSString *)title firstText:(NSString *)firstText image:(UIImage *)image {
    [[self shared] show:title firstText:firstText image:image];
}
+ (void)appendContext:(NSString *)text {
    [[self shared] appendContext:text];
}
+ (void)dismiss { [[self shared] hide]; }

- (void)show:(NSString *)title firstText:(NSString *)firstText image:(UIImage *)image {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideWithoutAnimation];
        self.busy = NO;
        NSString *custom = [Common stringPref:XZ_KEY_AI_PROMPT default:@""];
        self.systemPrompt = custom.length ? custom : @"你是手机上截图助手中的 AI；中文回复，语言简洁准确。";
        self.messages = [NSMutableArray array];
        [self.messages addObject:@{ @"role" : @"system", @"content" : self.systemPrompt }];
        if (image) {
            // v6.20.4：带图问 AI —— 首条 user 消息写成多模态数组（文字 + 图片），
            // AskAIEngine 原样把 messages 塞进 JSON，OpenAI 兼容视觉模型即可看图。
            NSString *dataURL = [[self class] sn3ImageDataURL:image];
            NSMutableArray<NSDictionary *> *parts = [NSMutableArray array];
            if (firstText.length) [parts addObject:@{ @"type" : @"text", @"text" : firstText }];
            if (dataURL.length)  [parts addObject:@{ @"type" : @"image_url", @"image_url" : @{ @"url" : dataURL } }];
            [self.messages addObject:@{ @"role" : @"user", @"content" : parts }];
        } else {
            [self.messages addObject:@{ @"role" : @"user", @"content" : firstText ?: @"" }];
        }

        UIWindow *base = [Common topWindow];
        CGRect b = base.bounds;
        UIWindow *w = [[UIWindow alloc] initWithFrame:b];
        // v6.05：AI 对话必须盖在局部工具栏(_panelWin≈Alert)之上，否则被压在下层看不见/点不动。
        //        用固定高层级（高于浮窗+300、分享+400），保证始终在最上层。
        w.windowLevel = UIWindowLevelAlert + 500;
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

        CGFloat sh = b.size.height * 0.80;
        UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height, b.size.width, sh)];
        sheet.backgroundColor = [UIColor systemBackgroundColor];
        sheet.layer.cornerRadius = 20;
        sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [vc addSubview:sheet];
        self.sheet = sheet;

        // 顶栏
        CGFloat y = 12;
        UIView *grip = [[UIView alloc] initWithFrame:CGRectMake(b.size.width/2-24, 8, 48, 5)];
        grip.backgroundColor = [UIColor systemGray3Color];
        grip.layer.cornerRadius = 2.5;
        [sheet addSubview:grip];

        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 180, 26)];
        tl.text = title ?: @"AI 对话";
        tl.font = [UIFont boldSystemFontOfSize:18];
        tl.textColor = [UIColor labelColor];
        [sheet addSubview:tl];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(b.size.width-56, y, 40, 28);
        if (@available(iOS 13.0, *)) [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        else [close setTitle:@"✕" forState:UIControlStateNormal];
        [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:close];

        y += 42;

        // 对话区
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(12, y, b.size.width-24, sh - y - 72)];
        tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
        tv.layer.cornerRadius = 14;
        tv.font = [UIFont systemFontOfSize:15];
        tv.textColor = [UIColor labelColor];
        tv.editable = NO;
        tv.selectable = YES;
        [sheet addSubview:tv];
        self.textView = tv;

        // 底栏：输入框 + 发送
        CGFloat by = sh - 58;
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(12, by+6, b.size.width-104, 46)];
        tf.placeholder = @"继续追问…";
        tf.font = [UIFont systemFontOfSize:15];
        tf.borderStyle = UITextBorderStyleNone;
        tf.backgroundColor = [UIColor secondarySystemBackgroundColor];
        tf.layer.cornerRadius = 14;
        tf.leftViewMode = UITextFieldViewModeAlways;
        tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,12,0)];
        tf.returnKeyType = UIReturnKeySend;
        [tf addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventEditingDidEndOnExit];
        [sheet addSubview:tf];
        self.input = tf;

        UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem];
        send.frame = CGRectMake(b.size.width-80, by+6, 66, 46);
        send.backgroundColor = [Common accentColor];
        [send setTitle:@"发送" forState:UIControlStateNormal];
        send.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [send setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        send.layer.cornerRadius = 14;
        [send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
        [sheet addSubview:send];
        self.sendBtn = send;

        [tf becomeFirstResponder];

        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ sheet.frame = CGRectMake(0, b.size.height-sh, b.size.width, sh); }
                         completion:nil];

        [self performFirstRequest];
    });
}

- (void)performFirstRequest {
    self.textView.text = @"AI 思考中…";
    [self ask];
}

// v5.25.5：把截图 OCR 结果作为上下文追加到对话（仅当用户尚未开始追问时注入，避免打断）
- (void)appendContext:(NSString *)text {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.window || !self.messages) return;
        NSString *ctx = [NSString stringWithFormat:@"（这是截图里识别到的文字，供参考）\n%@", text];
        [self.messages addObject:@{ @"role" : @"system", @"content" : ctx }];
        // 若首轮请求尚未发出（仍在“AI 思考中…”占位），不影响后续真实对话
        NSMutableString *cur = [NSMutableString stringWithString:self.textView.text ?: @""];
        if ([cur rangeOfString:@"AI 思考中"].location != NSNotFound) {
            [cur appendString:[NSString stringWithFormat:@"\n\n【截图上下文】\n%@", text]];
            self.textView.text = cur;
        }
    });
}

- (NSString *)renderedConversation {
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *m in self.messages) {
        NSString *role = m[@"role"];
        id raw = m[@"content"];
        NSString *content;
        if ([raw isKindOfClass:[NSArray class]]) {
            // v6.20.4：多模态消息 content 是 parts 数组，抽取其中的 text 段渲染
            NSMutableString *txt = [NSMutableString string];
            for (NSDictionary *p in raw) {
                if ([p isKindOfClass:[NSDictionary class]] && [p[@"type"] isEqualToString:@"text"]) {
                    NSString *t = p[@"text"];
                    if ([t isKindOfClass:[NSString class]]) [txt appendString:t];
                }
            }
            content = txt;
        } else if ([raw isKindOfClass:[NSString class]]) {
            content = raw;
        } else {
            content = @"";
        }
        if ([role isEqualToString:@"system"]) continue;
        NSString *label = [role isEqualToString:@"assistant"] ? @"AI 助手" : @"你";
        if (s.length) [s appendString:@"\n\n"];
        [s appendString:[NSString stringWithFormat:@"【%@】\n%@", label, content]];
    }
    return s;
}

// v6.20.4：把 UIImage 压成 JPEG data URL（长边缩到 2048，质量 0.8），供视觉模型多模态输入。
+ (NSString *)sn3ImageDataURL:(UIImage *)image {
    if (!image) return nil;
    CGFloat maxSide = 2048;
    CGFloat w = image.size.width, h = image.size.height;
    CGFloat scale = MIN(1.0, maxSide / MAX(w, h));
    CGSize ts = CGSizeMake((NSInteger)(w * scale), (NSInteger)(h * scale));
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ts];
    UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [image drawInRect:CGRectMake(0, 0, ts.width, ts.height)];
    }];
    NSData *jpeg = UIImageJPEGRepresentation(small, 0.8);
    if (!jpeg || jpeg.length == 0) return nil;
    NSString *b64 = [jpeg base64EncodedStringWithOptions:0];
    return [NSString stringWithFormat:@"data:image/jpeg;base64,%@", b64];
}

- (void)ask {
    self.busy = YES;
    self.sendBtn.enabled = NO;
    // v6.07：问 AI 改走「大模型库」——从 ModelAI_ID 取选中的模型配置
    NSDictionary *cfg = [Common sn3AIConfig];
    if (!cfg) {
        self.busy = NO;
        self.sendBtn.enabled = YES;
        self.textView.text = [NSString stringWithFormat:@"%@\n\n【提示】尚未选择 AI 模型：请到「设置 → 大模型库 → 问AI·使用模型」选一个模型（也可一键导入 DeepSeek / OpenAI / 智谱 等预设）。", [self renderedConversation]];
        return;
    }
    NSString *base  = [Common sn3ModelField:cfg key:@"baseURL" def:@"https://api.deepseek.com/v1"];
    NSString *key   = [Common sn3ModelField:cfg key:@"apiKey"  def:@""];
    NSString *model = [Common sn3ModelField:cfg key:@"model"   def:@"deepseek-chat"];
    if (!key.length) {
        self.busy = NO;
        self.sendBtn.enabled = YES;
        self.textView.text = [NSString stringWithFormat:@"%@\n\n【提示】所选模型未填 API Key：请到「设置 → 大模型库」编辑该模型填入 Key。", [self renderedConversation]];
        return;
    }
    NSArray *snapshotM = [self.messages copy];

    [AskAIEngine askMessages:snapshotM baseURL:base apiKey:key model:model completion:^(NSString *answer, NSString *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.sendBtn.enabled = YES;
            if (err) {
                [self.messages removeObjectAtIndex:self.messages.count-1]; // 去掉未成功的提问保留？保留便于重试，仅提示
                self.textView.text = [NSString stringWithFormat:@"%@\n\n【错误】%@", [self renderedConversation], err];
                return;
            }
            [self.messages addObject:@{ @"role" : @"assistant", @"content" : answer ?: @"" }];
            self.textView.text = [self renderedConversation];
            [self scrollToBottom];
        });
    }];
}

- (void)sendTapped {
    if (self.busy) return;
    NSString *q = [self.input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    self.input.text = @"";
    [self.messages addObject:@{ @"role" : @"user", @"content" : q }];
    self.textView.text = [NSString stringWithFormat:@"%@\n\n【你】\n%@\n\nAI 思考中…", [self renderedConversation], q];
    [self scrollToBottom];
    [self ask];
}

- (void)scrollToBottom {
    NSRange r = NSMakeRange(self.textView.text.length - 1, 1);
    [self.textView scrollRangeToVisible:r];
}

- (void)closeTapped { [self hide]; }

- (void)hideWithoutAnimation {
    [self.window.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.window.hidden = YES;
    self.window = nil;
    self.sheet = nil; self.textView = nil; self.input = nil; self.sendBtn = nil;
    self.messages = nil;
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.input resignFirstResponder];
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