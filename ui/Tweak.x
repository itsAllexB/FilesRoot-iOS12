// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesRootUI: a small helper loaded only into Files and the system document picker / "Save to Files"
// service (see FilesRootUI.plist). Browsing, previews and copying are all done by the real File Provider
// extension; this only applies two settings that a File Provider extension can't control itself:
//
//  - Location name: Files names a location after -[FPProvider localizedName], which fileproviderd fills
//    from the extension's CFBundleDisplayName ("System"). We return the name from Settings instead.
//  - Enabled: when FilesRoot is turned off, the provider reports itself as disabled, so Files hides it
//    from the sidebar (it stays listed, switched off, under Browse > Edit).
//
// Only the FilesRoot provider is touched; every other provider gets the original values.
// Files is sandboxed: settings are read with CFPreferences and, if cfprefsd refuses, from the plist.

#import <Foundation/Foundation.h>
#include <notify.h>

static NSString *const kFRProviderID = @"com.itsallexb.filesroot.provider";

@interface FPProvider : NSObject
@property (readonly, nonatomic) NSString *providerIdentifier;
@end

static NSString *gName;
static BOOL gEnabled = YES;
static CFAbsoluteTime gLoadedAt;

static id FRValue(NSDictionary *file, CFStringRef key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CFSTR("com.itsallexb.filesroot"));
    if (v) return (__bridge_transfer id)v;
    return file[(__bridge NSString *)key];
}

static void FRLoad(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLoadedAt && now - gLoadedAt < 2) return;          // the getters are called a lot while drawing
    gLoadedAt = now;
    CFPreferencesAppSynchronize(CFSTR("com.itsallexb.filesroot"));
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.itsallexb.filesroot.plist"];
    id name = FRValue(file, CFSTR("locationName"));
    id enabled = FRValue(file, CFSTR("enabled"));
    NSString *n = [name isKindOfClass:[NSString class]] ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    gName = n.length ? n : nil;
    gEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
}

// Files calls these getters from several threads.
static NSString *FRName(void) { @synchronized (kFRProviderID) { FRLoad(); return gName; } }
static BOOL FREnabled(void) { @synchronized (kFRProviderID) { FRLoad(); return gEnabled; } }

static BOOL FRIsOurs(FPProvider *p) {
    return [p respondsToSelector:@selector(providerIdentifier)] && [p.providerIdentifier isEqualToString:kFRProviderID];
}

%hook FPProvider

- (NSString *)localizedName {
    NSString *orig = %orig;
    if (!FRIsOurs(self)) return orig;
    return FRName() ?: orig;
}

- (BOOL)isEnabled {
    BOOL orig = %orig;
    if (!orig || !FRIsOurs(self)) return orig;
    return FREnabled();
}

%end

%ctor {
    // Settings changed: re-read on the next call.
    int token;
    notify_register_dispatch("com.itsallexb.filesroot/prefschanged", &token, dispatch_get_main_queue(), ^(int t) { @synchronized (kFRProviderID) { gLoadedAt = 0; } });
}
