//
//  AppScrollReporter.h — 注入 QQ/微信，读取真实 UIScrollView contentOffset
//
//  作用：长截图「精确模式」的 App 侧。收到 arm 后定位主滚动视图，按用户真实
//  滚动量（contentOffset.y 增量，点）通知 SpringBoard 抓帧，使拼接 100% 准确、
//  不靠像素比对猜测重叠缝。跨进程通过 notify 共享状态传偏移。
//
#import <UIKit/UIKit.h>

@interface AppScrollReporter : NSObject

// 在 App 进程构造函数中调用一次：注册 arm/disarm 通知与偏移状态 token。
+ (void)setup;

@end
