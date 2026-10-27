# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FilesRootPrefs
FilesRootPrefs_FILES = FRRootListController.m
FilesRootPrefs_FRAMEWORKS = UIKit
FilesRootPrefs_PRIVATE_FRAMEWORKS = Preferences
FilesRootPrefs_INSTALL_PATH = /Library/PreferenceBundles
FilesRootPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
