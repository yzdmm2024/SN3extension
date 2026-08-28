//
//  AppScrollReporter.h — 注入 QQ/微信，自动驱动 UIScrollView 滚动并上报精确偏移
//
//  作用：长截图「自动滚动」模式的 App 侧（方案 A）。收到 arm 后定位主滚动视图，
//  程序化地逐屏向下滚动 contentOffset，每滚一屏把当前精确偏移（contentOffset.y，点）
//  写入 notify 共享状态并通知 SpringBoard 抓帧，使拼接 100% 准确、不靠像素比对猜测。
//  滚到底时发 done 通知结束采集。跨进程通过 notify 共享状态传偏移。
//
#import <UIKit/UIKit.h>

@interface AppScrollReporter : NSObject

// 在 App 进程构造函数中调用一次：注册 arm/disarm 通知与偏移状态 token。
+ (void)setup;

@end
