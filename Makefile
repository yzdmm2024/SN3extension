export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_DEVICE_IP_OVERRIDE = 127.0.0.1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Snapper3ZhExt

Snapper3ZhExt_FILES = Tweak.xm \
    src/Common.m \
    src/FloatingMenu.m \
    src/ImageUtils.m
Snapper3ZhExt_FRAMEWORKS = UIKit Foundation
Snapper3ZhExt_WEAK_FRAMEWORKS = Photos
Snapper3ZhExt_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Isrc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = Snapper3ZhExtPrefs SN3CCModule

Snapper3ZhExtPrefs_FILES = src/Snapper3ZhExtPrefs.m
Snapper3ZhExtPrefs_INSTALL_PATH = /Library/PreferenceBundles
Snapper3ZhExtPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
Snapper3ZhExtPrefs_FRAMEWORKS = UIKit Foundation
Snapper3ZhExtPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

SN3CCModule_FILES = src/SN3CCModule.m
SN3CCModule_INSTALL_PATH = /Library/ControlCenter/Bundles
SN3CCModule_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
SN3CCModule_FRAMEWORKS = UIKit Foundation
# 必须显式链接 ControlCenterUIKit（私有框架），否则 ObjC 运行时注册
# SN3CCModule 时找不到父类 CCUIToggleModule —— Snapper3 官方模块同样如此。
# 若所用 SDK 缺该私有框架导致链接失败，可删掉此行（退回运行时解析，
# 前提是加载顺序上 ControlCenterUIKit 已先被 CCSupport 载入）。
SN3CCModule_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SN3CCModule_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk