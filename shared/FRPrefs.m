// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import "FRPrefs.h"

@interface FRPrefs ()
@property (nonatomic, readwrite) BOOL enabled, showHidden, allowChanges, thumbnails;
@property (nonatomic, readwrite, copy) NSString *name, *startPath;
@end

static BOOL FRBool(CFStringRef key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, kFRPrefsDomain);
    if (!v) return def;
    BOOL r = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int i = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i); r = i != 0; }
    CFRelease(v);
    return r;
}

static NSString *FRString(CFStringRef key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, kFRPrefsDomain);
    if (!v) return nil;
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) s = [(__bridge NSString *)v copy];
    CFRelease(v);
    return s;
}

@implementation FRPrefs

+ (FRPrefs *)current {
    CFPreferencesAppSynchronize(kFRPrefsDomain);
    FRPrefs *p = [FRPrefs new];
    p.enabled = FRBool(CFSTR("enabled"), YES);
    p.showHidden = FRBool(CFSTR("showHidden"), NO);
    p.allowChanges = FRBool(CFSTR("allowChanges"), NO);
    p.thumbnails = FRBool(CFSTR("thumbnails"), YES);
    NSString *name = [FRString(CFSTR("locationName")) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    p.name = name.length ? name : kFRDefaultName;
    NSString *start = FRString(CFSTR("startPath"));
    // Only the two documented choices are accepted; anything else falls back to "/".
    p.startPath = [start isEqualToString:@"/var/mobile"] ? @"/var/mobile" : @"/";
    return p;
}

- (uint32_t)generation {
    return (self.enabled ? 1 : 0) | (self.showHidden ? 2 : 0) | (self.allowChanges ? 4 : 0) | (self.thumbnails ? 8 : 0)
        | ([self.startPath isEqualToString:@"/"] ? 16 : 0);
}

@end
