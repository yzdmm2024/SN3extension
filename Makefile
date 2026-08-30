export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_DEVICE_IP_OVERRIDE = 127.0.0.1

# v4.1：theos 默认开 -Werror，本地无法预编译验证时很容易被一条无害 warning 卡住 CI。
# GO_EASY_ON_ME=1 是 theos 官方用来关掉 -Werror 的开关（未知变量时无害）。
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Snapper3ZhExt

Snapper3ZhExt_FILES = Tweak.xm \
    src/Common.m \
    src/ImageUtils.m \
    src/XZPassThroughWindow.m \
    src/MaskCropWindow.m \
    src/LongShotCapture.m \
    src/EditToolbarWindow.m \
    src/SuperTools.m \
    src/AppScrollReporter.m \
    src/AIChatWindow.m \
    src/AskAIEngine.m \
    src/HistoryWindow.m \
    src/ResultWindow.m \
    src/OCRBoxWindow.m
Snapper3ZhExt_FRAMEWORKS = UIKit Foundation Vision PDFKit CoreImage
Snapper3ZhExt_WEAK_FRAMEWORKS = Photos
Snapper3ZhExt_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-error -Isrc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = Snapper3ZhExtPrefs SN3CCModule

# v5.25.2：必须把 AskAIEngine.m 一起编进来。
# Snapper3ZhExtPrefs.m 的「测试连接」按钮会用到 AskAIEngine，而 AskAIEngine.m 原先只编进 tweak
# dylib。prefs bundle 靠 -undefined,dynamic_lookup 把解析推到运行时，但 tweak 的 Filter 里没有
# com.apple.Preferences，设置进程里根本不存在这个类 → dlopen 直接失败：
#   symbol not found in flat namespace '_OBJC_CLASS_$_AskAIEngine'
# 表现就是「设置 → 超级截图」不显示 / 空白。prefs bundle 必须自包含。
Snapper3ZhExtPrefs_FILES = src/Snapper3ZhExtPrefs.m src/AskAIEngine.m src/ToolbarOrderController.m \
    src/SN3ModelStore.m src/SN3ModelLibController.m src/SN3ModelPickerController.m
Snapper3ZhExtPrefs_INSTALL_PATH = /Library/PreferenceBundles
Snapper3ZhExtPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
Snapper3ZhExtPrefs_FRAMEWORKS = UIKit Foundation
Snapper3ZhExtPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

SN3CCModule_FILES = src/SN3CCModule.m
SN3CCModule_INSTALL_PATH = /Library/ControlCenter/Bundles
SN3CCModule_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
SN3CCModule_FRAMEWORKS = UIKit Foundation
# 不显式链接 ControlCenterUIKit：该私有框架不一定在 CI 的 theos SDK 里，
# 且本模块靠 -undefined,dynamic_lookup 运行时解析父类（CCSupport 载入时
# ControlCenterUIKit 已在控制中心进程内，符号必然可用）。
SN3CCModule_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

# v6.18：已移除套壳 companion App（按用户要求，撤销 v6.17 的套壳方案）。