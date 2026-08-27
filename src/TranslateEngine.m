//
//  TranslateEngine.m — 百度翻译开放平台 API（通用翻译文本接口）
//  需自备 AppID / 密钥：https://fanyi-api.baidu.com
//
#import <CommonCrypto/CommonDigest.h>
#import <string.h>
#import "TranslateEngine.h"

@implementation TranslateEngine

static NSString *md5(NSString *s) {
    const char *c = s.UTF8String;
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), d);
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            d[0],d[1],d[2],d[3],d[4],d[5],d[6],d[7],
            d[8],d[9],d[10],d[11],d[12],d[13],d[14],d[15]];
}

+ (NSMutableURLRequest *)requestWithQuery:(NSDictionary *)params {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in params) {
        NSString *v = [params[k] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, v ?: @""]];
    }
    NSString *query = [parts componentsJoinedByString:@"&"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://fanyi-api.baidu.com/api/trans/vip/translate?%@", query]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 20;
    return r;
}

+ (void)translateText:(NSString *)text
             fromLang:(NSString *)from
               toLang:(NSString *)to
                appid:(NSString *)appid
                appKey:(NSString *)appKey
           completion:(void (^)(NSString *, NSString *))completion {

    if (!text.length) { if (completion) completion(@"", @"无文本"); return; }
    NSString *salt = [NSString stringWithFormat:@"%d", (int)[NSDate date].timeIntervalSince1970 * 1000 + arc4random()%1000];
    NSString *sign = md5([NSString stringWithFormat:@"%@%@%@%@", appid, text, salt, appKey]);

    NSDictionary *params = @{
        @"q" : text, @"from" : from ?: @"auto", @"to" : to ?: @"zh",
        @"appid" : appid, @"salt" : salt, @"sign" : sign
    };
    NSURLRequest *req = [self requestWithQuery:params];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err) {
            if (completion) completion(nil, err.localizedDescription);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json[@"error_msg"]) {
            if (completion) completion(nil, json[@"error_msg"]);
            return;
        }
        NSArray *arr = json[@"trans_result"];
        NSMutableString *out_ = [NSMutableString string];
        for (NSDictionary *item in arr) {
            if (out_.length) [out_ appendString:@"\n"];
            [out_ appendString:item[@"dst"] ?: @""];
        }
        if (completion) completion(out_ , nil);
    }] resume];
}

@end