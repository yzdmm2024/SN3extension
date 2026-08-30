//
//  SN3ModelStore.h — 大模型库 预置 bundle 侧共享工具（自包含，仅用 NSUserDefaults + UIKit）
//  与 tweak 侧 Common 的 sn3Model* 解析对称：同一份 JSON(XZ_KEY_MODEL_LIB) 两端各自读写。
//
#import <UIKit/UIKit.h>

// 预置域名与 tweak 侧 Common.h 保持一致
#define SN3_DOMAIN      @"com.axs.snapper3zhext"
#define SN3_K_LIB       @"ModelLibrary_JSON"
#define SN3_K_AI        @"ModelAI_ID"
#define SN3_K_OCR       @"ModelOCR_ID"
#define SN3_K_TRANS     @"ModelTrans_ID"
#define SN3_K_MIGRATED  @"ModelLib_Migrated"

// —— 模型库读写（预置 bundle 侧）——
NSUserDefaults *SN3Defs(void);
NSArray<NSDictionary *> *SN3LoadModels(void);
void SN3SaveModels(NSArray *models);
NSString *SN3ModelField(NSDictionary *m, NSString *k, NSString *def);
NSDictionary *SN3ModelById(NSArray *models, NSString *mid);
void SN3MigrateIfNeeded(void);                 // 一次性把旧 AskAI_*/BigModel_* 并入库
NSArray<NSDictionary *> *SN3Presets(void);     // 一键导入的预设厂商列表
NSString *SN3NewUUID(void);

@interface SN3ModelLibController : UIViewController
@end

@interface SN3ModelPickerController : UIViewController
- (instancetype)initWithFeatureKey:(NSString *)key title:(NSString *)title;
@end
