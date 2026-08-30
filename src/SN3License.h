//
//  SN3License.h — 设备授权（UDID 解锁码验证）
//
//  算法（与「验证的逻辑/gen_license.py」「dylib_GC函数.m」完全一致）：
//    解锁码 = SHA256(UDID) → 取前 15 字节 → 映射到 56 字符集 → 15 位解锁码
//    字符集去除易混淆字符 0/O/1/l/I，共 56 个。
//  无需密钥、无需服务器：同设备 UDID 永远对应唯一解锁码。
//
//  设计要点：
//  · 完全自包含，不依赖 Common（prefs bundle 不编 Common.m，避免符号缺失）。
//  · 解锁状态存 NSUserDefaults(suite=com.axs.snapper3zhext) 键 License_Unlocked，
//    与插件其它偏好同一域，tweak(SpringBoard) 与 prefs(设置) 可共享读写。
//  · 弹窗走「非 key window、hidden=NO、显式 frame、dismiss 即销毁」安全窗口，
//    避开 v6.09 在 SpringBoard 自建 key window 弹 alert 打进安全模式的坑。
//
#import <Foundation/Foundation.h>

@interface SN3License : NSObject

+ (NSString *)deviceUDID;                 // 真实设备 UDID（MGCopyAnswer + 降级）
+ (NSString *)expectedCode;               // SHA256(UDID) → 15 位解锁码
+ (BOOL)verifyCode:(NSString *)code;      // 去空白后比对
+ (BOOL)isUnlocked;
+ (void)setUnlocked:(BOOL)v;
+ (void)markUnlocked;
+ (void)revoke;

// 弹出验证框：复制 UDID / 输入解锁码验证 / 取消 /（已解锁时）锁定本机。
// win 可传 nil（内部自建安全 host 窗口）。completion 在解锁状态变化时回调。
+ (void)presentVerificationFromWindow:(UIWindow *)win
                           completion:(void (^)(BOOL nowUnlocked))completion;

@end
