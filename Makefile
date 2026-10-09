TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SundiroSPUnlock
SundiroSPUnlock_FILES = Tweak.xm
SundiroSPUnlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SundiroSPUnlock_FRAMEWORKS = Foundation CoreBluetooth

include $(THEOS_MAKE_PATH)/tweak.mk
