//
//  TranslateEngine.h — 百度通用翻译
//
#import <UIKit/UIKit.h>

@interface TranslateEngine : NSObject
// text: 待翻译，fromLang/toLang: 如 auto/zh
+ (void)translateText:(NSString *)text
             fromLang:(NSString *)from
               toLang:(NSString *)to
                appid:(NSString *)appid
                appKey:(NSString *)appKey
           completion:(void (^)(NSString *translated, NSString *error))completion;
@end