export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.0
export THEOS_PACKAGE_SCHEME = rootless
export THEOS_DEVICE_IP_OVERRIDE = 127.0.0.1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Snapper3ZhExt

Snapper3ZhExt_FILES = Tweak.xm \
    src/PluginBase.m \
    src/ZhOCRPlugin.m \
    src/VisionOCR.m \
    src/OCRBoxWindow.m \
    src/TranslatePlugin.m \
    src/TranslateEngine.m \
    src/LongScreenshotPlugin.m \
    src/LongShotController.m \
    src/AskAIPlugin.m \
    src/AskAIEngine.m \
    src/AIChatWindow.m \
    src/ResultWindow.m \
    src/Common.m \
    src/FloatingMenu.m \
    src/ImageUtils.m
Snapper3ZhExt_FRAMEWORKS = UIKit Foundation Vision Photos
Snapper3ZhExt_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Isrc
Snapper3ZhExt_FILTER = com.apple.springboard

include $(THEOS_MAKE_PATH)/tweak.mk