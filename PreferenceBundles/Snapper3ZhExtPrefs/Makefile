export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# 编译成 MH_DYLIB 类型（与工作正常的 AxsOCRPrefs 一致），
# 由 CI 注入 layout 的 Prefs bundle 作为 CFBundleExecutable。
LIBRARY_NAME = Snapper3ZhExtPrefs

Snapper3ZhExtPrefs_FILES = Snapper3ZhExtPrefs.m
Snapper3ZhExtPrefs_FRAMEWORKS = Foundation UIKit
Snapper3ZhExtPrefs_CFLAGS = -fobjc-arc
Snapper3ZhExtPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk