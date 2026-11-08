TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SundiroSPUnlock
SundiroSPUnlock_FILES = Tweak.x
# ★ 2026-11-08：强制生成 __eh_frame（DWARF 异常展开表）。
#   1.3.9 有 168 字节 __eh_frame（3 个 FDE），而当前构建为 0，
#   但两者都引用 __Unwind_Resume / ___objc_personality_v0 —— 即仍有 @try 块
#   需要异常展开。缺 __eh_frame 时若真发生展开，unwinder 找不到 FDE。
SundiroSPUnlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -funwind-tables -fasynchronous-unwind-tables
SundiroSPUnlock_FRAMEWORKS = Foundation CoreBluetooth

include $(THEOS_MAKE_PATH)/tweak.mk
