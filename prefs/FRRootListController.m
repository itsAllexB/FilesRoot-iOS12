// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#include <notify.h>

@interface FRRootListController : PSListController
@end

@implementation FRRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// "Allow Changes" asks for confirmation before turning on; turning it off is immediate.
- (void)setAllowChanges:(id)value specifier:(PSSpecifier *)specifier {
    if (![value boolValue]) {
        [self setPreferenceValue:value specifier:specifier];
        notify_post("com.itsallexb.filesroot/prefschanged");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow Changes?"
        message:@"Files will be able to delete, rename, move and overwrite items outside the protected system folders. "
                @"A mistake can make the iPad unbootable, and a semi-tethered jailbreak can only be fixed by restoring. "
                @"Turn this off again when you are done."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [self reloadSpecifier:specifier animated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Allow Changes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self setPreferenceValue:value specifier:specifier];
        notify_post("com.itsallexb.filesroot/prefschanged");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFiles {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"shareddocuments://"] options:@{} completionHandler:nil];
}

@end
