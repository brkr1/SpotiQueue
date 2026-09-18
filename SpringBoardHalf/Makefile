ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
    TARGET := iphone:clang:latest:15.0
    TARGET_OS_DEPLOYMENT_VERSION = 15.0
    ifneq ($(wildcard $(THEOS)/sdks/iPhoneOS15.6.sdk),)
        SYSROOT=$(THEOS)/sdks/iPhoneOS15.6.sdk
        SDKVERSION = 15.6
        INCLUDE_SDKVERSION = 15.6
    endif
else
    TARGET := iphone:clang:latest:13.0
    TARGET_OS_DEPLOYMENT_VERSION = 13.0
endif

include $(THEOS)/makefiles/common.mk

# arm64e: clang signs the class_ro pointer of every Objective-C class, and the
# libobjc that reads it back does not always authenticate that slot. When it does
# not, the injected process dies the instant dyld maps this dylib - inside
# libobjc's readClass(), EXC_BAD_ACCESS / SIGBUS. Confirmed by NextUp3 on iPhone14,5
# @ iOS 17.0. Probed with a real Apple triple (bare $(TARGET_CC) is only a valid
# Apple compiler by default on macOS - on a Linux Theos host it silently probes the
# wrong target and the flag never gets applied to the real arm64e compile).
LX_PTRAUTH_FLAG := -fno-ptrauth-objc-class-ro
LX_PTRAUTH_SUPPORTED := $(shell $(TARGET_CC) -target arm64e-apple-ios15.0 -x objective-c \
	-fsyntax-only $(LX_PTRAUTH_FLAG) /dev/null >/dev/null 2>&1 && echo yes)

ifeq ($(LX_PTRAUTH_SUPPORTED),yes)
LX_PTRAUTH_CFLAGS := $(LX_PTRAUTH_FLAG)
else ifeq ($(filter arm64e,$(ARCHS)),)
LX_PTRAUTH_CFLAGS :=
else
$(error $(LX_PTRAUTH_FLAG) is not accepted by $(TARGET_CC), but arm64e is in ARCHS. \
Building anyway emits signed class_ro pointers and produces a dylib that crashes every \
process it is injected into. Build on macOS with Xcode's clang, which supports this flag.)
endif

TWEAK_NAME = SpotiQueueSpringBoard

SpotiQueueSpringBoard_FILES = Tweak.x
SpotiQueueSpringBoard_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I.. -I../vendor/LightMessaging \
	-DLIGHTMESSAGING_USE_ROCKETBOOTSTRAP=0 -DLIGHTMESSAGING_TIMEOUT=250 $(LX_PTRAUTH_CFLAGS)
SpotiQueueSpringBoard_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
