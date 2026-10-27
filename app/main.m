// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesRoot host app. iOS only loads File Provider extensions that live inside an app, so this is a tiny
// container for FilesRootProvider.appex. It is hidden from the Home Screen (SBAppTags = hidden); if it is
// ever opened it just explains where the location is and links to Files and Settings.

#import <UIKit/UIKit.h>
#import "../shared/FRPrefs.h"

@interface FRAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface FRInfoViewController : UIViewController
@end

@implementation FRInfoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = [NSString stringWithFormat:@"FilesRoot adds “%@” to Files.\n\nOpen Files > Browse. If the location is missing, tap Edit and turn it on.\nOptions are in Settings > Files Root.", [FRPrefs current].name];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *files = [UIButton buttonWithType:UIButtonTypeSystem];
    [files setTitle:@"Open Files" forState:UIControlStateNormal];
    files.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    [files addTarget:self action:@selector(openFiles) forControlEvents:UIControlEventTouchUpInside];
    files.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];
    [self.view addSubview:files];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [label.widthAnchor constraintLessThanOrEqualToConstant:460],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [files.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [files.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:24],
    ]];
}

- (void)openFiles {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"shareddocuments://"] options:@{} completionHandler:nil];
}

@end

@implementation FRAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [FRInfoViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FRAppDelegate class]));
    }
}
