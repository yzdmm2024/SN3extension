export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.0
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

Snapper3ZhExtPrefs_FILES = src/Snapper3ZhExtPrefs.c
Snapper3ZhExtPrefs_INSTALL_PATH = /Library/PreferenceBundles

SN3CCModule_FILES = src/SN3CCModule.m
SN3CCModule_INSTALL_PATH = /Library/ControlCenter/Bundles
SN3CCModule_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
SN3CCModule_FRAMEWORKS = UIKit Foundation
SN3CCModule_PRIVATE_FRAMEWORKS = ControlCenterUIKit

include $(THEOS_MAKE_PATH)/bundle.mk