//
//  VisionOCR.m  — 使用 Apple Vision VNRecognizeTextRequest 做离线文字识别。
//  与 Snapper3 内置 OCR 相同框架，但显式纳入中文语言，并提高精度等级。
//
#import <Vision/Vision.h>
#import "VisionOCR.h"

@implementation OCRBlock
@end

@implementation VisionOCR

// 统一识别，返回观察结果数组（含坐标），在主线程回调
+ (void)runRecognition:(UIImage *)image
             languages:(NSArray<NSString *> *)languages
              observer:(void (^)(NSArray<VNRecognizedTextObservation *> *obs))observer {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGImageRef cg = image.CGImage;
        if (!cg) { dispatch_async(dispatch_get_main_queue(), ^{ if (observer) observer(nil); }); return; }

        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *r, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (observer) observer(err ? nil : r.results); });
        }];

        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = YES;

        NSArray<NSString *> *supported = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:req.recognitionLevel revision:req.revision error:NULL];
        NSMutableArray *valid = [NSMutableArray array];
        for (NSString *l in languages) {
            if ([supported containsObject:l]) [valid addObject:l];
        }
        if (!valid.count) valid = [NSMutableArray arrayWithArray:supported];
        if (valid.count && ![valid containsObject:@"en-US"]) [valid addObject:@"en-US"];
        req.recognitionLanguages = valid;

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        [handler performRequests:@[req] error:NULL];
    });
}

+ (void)recognizeImage:(UIImage *)image
             languages:(NSArray<NSString *> *)languages
            completion:(void (^)(NSString *))completion {

    if (!image) { if (completion) completion(@""); return; }
    [self runRecognition:image languages:languages observer:^(NSArray<VNRecognizedTextObservation *> *obs) {
        NSMutableString *all = [NSMutableString string];
        for (VNRecognizedTextObservation *o in obs) {
            NSArray *cands = [o topCandidates:1];
            NSString *s = cands.count ? ((VNRecognizedText *)cands[0]).string : nil;
            if (s.length) {
                if (all.length) [all appendString:@"\n"];
                [all appendString:s];
            }
        }
        if (completion) completion(all);
    }];
}

+ (void)recognizeBlocks:(UIImage *)image
              languages:(NSArray<NSString *> *)languages
             completion:(void (^)(NSArray<OCRBlock *> *))completion {

    if (!image) { if (completion) completion(@[]); return; }
    [self runRecognition:image languages:languages observer:^(NSArray<VNRecognizedTextObservation *> *obs) {
        NSMutableArray *blocks = [NSMutableArray array];
        for (VNRecognizedTextObservation *o in obs) {
            NSArray *cands = [o topCandidates:1];
            NSString *s = cands.count ? ((VNRecognizedText *)cands[0]).string : nil;
            if (!s.length) continue;
            OCRBlock *b = [OCRBlock new];
            b.text = s;
            b.normalizedBox = o.boundingBox; // Vision 坐标系：原点左下，0~1
            [blocks addObject:b];
        }
        if (completion) completion(blocks);
    }];
}

@end