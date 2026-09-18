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

PACKAGE_VERSION = $(THEOS_PACKAGE_BASE_VERSION)

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += SpotifyHalf
SUBPROJECTS += SpringBoardHalf
SUBPROJECTS += MediaRemoteUIHalf

include $(THEOS_MAKE_PATH)/aggregate.mk
