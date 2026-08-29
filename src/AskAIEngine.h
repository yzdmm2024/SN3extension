//
//  AskAIEngine.h — OpenAI 兼容聊天补全网络层（问 AI 用）
//
//  支持任意 OpenAI 兼容接口（DeepSeek / OpenAI / 通义 / 本地 Ollama 等）。
//  请求体：{ model, messages, stream:false }；鉴权：Authorization: Bearer <key>。
//
#import <Foundation/Foundation.h>

@interface AskAIEngine : NSObject

// messages: @[ @{@"role":@"system"/@"user"/@"assistant", @"content":NSString} ]
// completion 在主线程回调：answer 成功文本，err 非空表示失败原因。
+ (void)askMessages:(NSArray<NSDictionary *> *)messages
            baseURL:(NSString *)baseURL
             apiKey:(NSString *)apiKey
              model:(NSString *)model
         completion:(void (^)(NSString *answer, NSString *err))completion;

@end
