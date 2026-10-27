# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Files fileproviderd
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# Host app (hidden from the Home Screen). It only exists because iOS loads File Provider extensions from apps.
APPLICATION_NAME = FilesRoot
FilesRoot_FILES = app/main.m shared/FRPrefs.m
FilesRoot_RESOURCE_DIRS = app/Resources
FilesRoot_FRAMEWORKS = UIKit
FilesRoot_CFLAGS = -fobjc-arc
FilesRoot_CODESIGN_FLAGS = -Sapp/ents.plist
FilesRoot_INSTALL_PATH = /Applications

# The File Provider extension that Files talks to.
APPEX_NAME = FilesRootProvider
FilesRootProvider_FILES = provider/FRExtension.m provider/FREnumerator.m provider/FRItem.m shared/FRPrefs.m shared/FRPolicy.c
FilesRootProvider_RESOURCE_DIRS = provider/Resources
FilesRootProvider_FRAMEWORKS = FileProvider MobileCoreServices ImageIO CoreGraphics
FilesRootProvider_CFLAGS = -fobjc-arc
ifeq ($(FR_DEBUG_LOG),1)
FilesRootProvider_CFLAGS += -DFR_DEBUG_LOG
endif
FilesRootProvider_CODESIGN_FLAGS = -Sprovider/ents.plist
FilesRootProvider_INSTALL_PATH = /Applications/FilesRoot.app/PlugIns

# Applies the location name / Enabled settings inside Files and the document picker.
TWEAK_NAME = FilesRootUI
FilesRootUI_FILES = ui/Tweak.x
FilesRootUI_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/appex.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
