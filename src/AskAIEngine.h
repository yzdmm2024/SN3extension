//
//  AskAIEngine.h — 通用类 OpenAI 兼容的对话补全
//
#import <Foundation/Foundation.h>

@interface AskAIEngine : NSObject
// baseURL: 如 https://api.openai.com/v1 或 https://api.deepseek.com/v1
+ (void)askText:(NSString *)prompt
        baseURL:(NSString *)baseURL
         apiKey:(NSString *)apiKey
          model:(NSString *)model
     completion:(void (^)(NSString *answer, NSString *error))completion;

// 传入完整对话（messages: 数组元素为 @{@"role":@"user"/@"assistant"/@"system", @"content":@"..."}）
// 用于多轮对话保持上下文
+ (void)askMessages:(NSArray<NSDictionary *> *)messages
            baseURL:(NSString *)baseURL
             apiKey:(NSString *)apiKey
              model:(NSString *)model
         completion:(void (^)(NSString *answer, NSString *error))completion;
@end