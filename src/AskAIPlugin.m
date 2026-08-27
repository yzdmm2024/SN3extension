//
//  AskAIPlugin.m
//
#import "AskAIPlugin.h"
#import "VisionOCR.h"
#import "AIChatWindow.h"
#import "Common.h"

@implementation AskAIPlugin

- (NSString *)pluginIdentifier { return XZ_ID_AI; }
- (BOOL)shouldRegister { return YES; }
- (UIImage *)imageForMenuAndSettings { return [Common systemIcon:@"sparkles"]; }

- (BOOL)configured {
    return [Common stringPref:XZ_KEY_AI_KEY default:@""].length > 0;
}

- (void)runWithImage:(UIImage *)image {
    if (![self configured]) {
        [Common toast:@"请先在设置中填写 AI 接口地址 / Key / 模型"];
        return;
    }
    [Common toast:@"AI 分析中…"];
    [VisionOCR recognizeImage:image languages:[Common ocrLanguages] completion:^(NSString *text) {
        NSString *prompt = [Common stringPref:XZ_KEY_AI_PROMPT default:@""];
        if (!prompt.length) prompt = @"请总结图片中的文字内容，并回答：";
        NSString *first = [NSString stringWithFormat:@"%@\n\n【图片识别到的文字】\n%@", prompt, text];
        [AIChatWindow showWithTitle:@"AI 对话" firstText:first];
    }];
}

@end