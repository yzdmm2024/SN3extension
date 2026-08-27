//
//  AskAIEngine.m
//
#import "AskAIEngine.h"

@implementation AskAIEngine

+ (void)askText:(NSString *)prompt
        baseURL:(NSString *)baseURL
         apiKey:(NSString *)apiKey
          model:(NSString *)model
     completion:(void (^)(NSString *, NSString *))completion {

    NSArray *messages = @[
        @{ @"role" : @"system", @"content" : @"你是手机上截图助手中的 AI；中文回复，语言简洁准确。" },
        @{ @"role" : @"user", @"content" : prompt ?: @"" }
    ];
    [self askMessages:messages baseURL:baseURL apiKey:apiKey model:model completion:completion];
}

+ (void)askMessages:(NSArray<NSDictionary *> *)messages
            baseURL:(NSString *)baseURL
             apiKey:(NSString *)apiKey
              model:(NSString *)model
         completion:(void (^)(NSString *, NSString *))completion {

    if (!apiKey.length) { if (completion) completion(nil, @"未配置 API Key"); return; }
    NSString *b = baseURL.length ? [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if (b.length && [b hasSuffix:@"/"]) b = [b substringToIndex:b.length-1];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/chat/completions", b.length ? b : @"https://api.openai.com/v1"]];

    NSDictionary *body = @{
        @"model" : model.length ? model : @"gpt-4o-mini",
        @"messages" : (messages && messages.count) ? messages :
            @[ @{ @"role" : @"user", @"content" : @"" } ]
    };

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    req.timeoutInterval = 60;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err) { if (completion) completion(nil, err.localizedDescription); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json[@"error"]) {
            if (completion) completion(nil, [json[@"error"] description]);
            return;
        }
        NSArray *choices = json[@"choices"];
        NSString *answer = choices && choices.count ? choices[0][@"message"][@"content"] : nil;
        if (completion) completion(answer ?: @"(无回复)", nil);
    }] resume];
}

@end