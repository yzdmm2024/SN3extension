export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.0
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_DEVICE_IP_OVERRIDE = 127.0.0.1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Snapper3ZhExt

Snapper3ZhExt_FILES = Tweak.xm
Snapper3ZhExt_FRAMEWORKS = UIKit Foundation
Snapper3ZhExt_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk