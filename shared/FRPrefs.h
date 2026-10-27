// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// Settings shared by the File Provider extension and the host app.
// Stored by the Settings pane in /var/mobile/Library/Preferences/com.itsallexb.filesroot.plist.

#import <Foundation/Foundation.h>

#define kFRPrefsDomain      CFSTR("com.itsallexb.filesroot")
#define kFRPrefsChanged     "com.itsallexb.filesroot/prefschanged"
#define kFRDomainIdentifier @"root"
#define kFRDefaultName      @"System"

@interface FRPrefs : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL showHidden;
@property (nonatomic, readonly) BOOL allowChanges;   // "Allow Changes (dangerous)", off by default
@property (nonatomic, readonly) BOOL thumbnails;
@property (nonatomic, readonly, copy) NSString *name;        // location name in Files
@property (nonatomic, readonly, copy) NSString *startPath;   // "/" or "/var/mobile"
// Changes whenever a setting that affects listings changes (part of the enumeration sync anchor).
@property (nonatomic, readonly) uint32_t generation;
+ (FRPrefs *)current;    // re-read from cfprefsd on every call (cheap)
@end
