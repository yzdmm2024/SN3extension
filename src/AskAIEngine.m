//
//  AskAIEngine.m — OpenAI 兼容聊天补全网络层
//
#import "AskAIEngine.h"

@implementation AskAIEngine

+ (void)askMessages:(NSArray<NSDictionary *> *)messages
            baseURL:(NSString *)baseURL
             apiKey:(NSString *)apiKey
              model:(NSString *)model
         completion:(void (^)(NSString *answer, NSString *err))completion {
    if (!baseURL.length) baseURL = @"https://api.deepseek.com/v1";
    if (!model.length)   model   = @"deepseek-chat";

    // 规整 baseURL：确保末尾有 "/"，再拼 chat/completions
    NSString *u = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (u.length == 0) { if (completion) completion(nil, @"AI 接口地址为空"); return; }
    if (![u hasSuffix:@"/"]) u = [u stringByAppendingString:@"/"];
    u = [u stringByAppendingString:@"chat/completions"];

    NSURL *url = [NSURL URLWithString:u];
    if (!url) { if (completion) completion(nil, @"AI 接口地址无效"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setTimeoutInterval:90];                 // LLM 首字常慢，给足超时
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (apiKey.length) {
        [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    }

    NSDictionary *body = @{
        @"model"      : model,
        @"messages"   : messages ?: @[],
        @"stream"     : @NO,
        @"temperature": @0.7,
    };
    NSError *je = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&je];
    if (!payload) { if (completion) completion(nil, @"AI 请求构造失败"); return; }
    [req setHTTPBody:payload];

    NSLog(@"[SN3] AI 请求 → %@ model=%@", u, model);

    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSString *e = [NSString stringWithFormat:@"网络错误：%@", err.localizedDescription];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); });
            return;
        }
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        if (hr.statusCode != 200) {
            NSString *detail = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSString *e = [NSString stringWithFormat:@"接口返回 %ld：%@", (long)hr.statusCode, detail.length ? detail : @"(空)"];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); });
            return;
        }
        if (!data || data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, @"接口返回空内容"); });
            return;
        }
        NSError *pe = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&pe];
        if (!json) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [@"接口返回非 JSON：" stringByAppendingString:raw ?: @""]); });
            return;
        }
        NSArray *choices = json[@"choices"];
        if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) {
            id em = json[@"error"];
            NSString *e = em ? [NSString stringWithFormat:@"接口无结果：%@", em] : @"接口无 choices 字段";
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); });
            return;
        }
        NSDictionary *msg = choices[0][@"message"];
        NSString *ans = msg[@"content"];
        if (![ans isKindOfClass:[NSString class]]) ans = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ans ?: @"", nil); });
    }] resume];
}

@end
