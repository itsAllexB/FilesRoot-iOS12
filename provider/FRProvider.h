// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesRoot File Provider extension (iOS 11/12 NSFileProviderExtension API).
//
// Identifiers: an item's identifier is its *logical* absolute path as the user navigated to it
// ("/var/mobile/Documents", not the resolved "/private/var/mobile/Documents"), so symlinked folders
// (/var, /etc, /tmp, ...) behave like real folders and breadcrumbs stay correct. The start folder
// (Settings: "/" or "/var/mobile") is NSFileProviderRootContainerItemIdentifier.
//
// Storage: Files and other apps never read the real paths directly (they are sandboxed). When a file is
// opened, previewed, copied out or shared, fileproviderd asks us to "provide" it and we place a copy at
// <documentStorageURL>/tree/<logical path>: an APFS clone (instant, no extra space) when the file is on
// the data volume, a normal copy otherwise (system volume). Copies are deleted when Files no longer needs
// them and on the next start of the extension after a day. Writes go back to the real file only when
// "Allow Changes" is on and FRPolicy allows that path.

#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>
#import "../shared/FRPrefs.h"

#define FRLog(fmt, ...) NSLog(@"FilesRoot: " fmt, ##__VA_ARGS__)
// Development only (make FR_DEBUG_LOG=1): trace calls to /tmp/filesroot-debug.log. Not in release builds.
#ifdef FR_DEBUG_LOG
void FRDebugLog(NSString *line);
#define FRDLog(fmt, ...) FRDebugLog([NSString stringWithFormat:fmt, ##__VA_ARGS__])
#else
#define FRDLog(fmt, ...) do {} while (0)
#endif

// Path <-> identifier helpers (logical paths, never standardized: -stringByStandardizingPath would turn
// /private/var into /var).
NSString *FRPathForIdentifier(NSFileProviderItemIdentifier identifier, FRPrefs *prefs);   // nil when invalid
NSFileProviderItemIdentifier FRIdentifierForPath(NSString *path, FRPrefs *prefs);
NSError *FRErrorFromErrno(int err, NSString *path, BOOL writing);
NSError *FRWriteDeniedError(NSString *path, FRPrefs *prefs);
NSError *FRDisabledError(void);

@interface FRItem : NSObject <NSFileProviderItem>
@property (nonatomic, copy) NSFileProviderItemIdentifier itemIdentifier;
@property (nonatomic, copy) NSFileProviderItemIdentifier parentItemIdentifier;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy) NSString *typeIdentifier;
@property (nonatomic) NSFileProviderItemCapabilities capabilities;
@property (nonatomic, copy) NSNumber *documentSize;
@property (nonatomic, copy) NSDate *creationDate;
@property (nonatomic, copy) NSDate *contentModificationDate;
@property (nonatomic, readonly, getter=isDownloaded) BOOL downloaded;
@property (nonatomic, readonly, getter=isMostRecentVersionDownloaded) BOOL mostRecentVersionDownloaded;
@property (nonatomic, readonly, getter=isUploaded) BOOL uploaded;
@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) BOOL isRegularFile;
@property (nonatomic, copy, readonly) NSString *path;   // logical path

// Builds an item from lstat/stat of `path`. `name` overrides the displayed filename (root item).
+ (instancetype)itemWithPath:(NSString *)path identifier:(NSFileProviderItemIdentifier)identifier
                      parent:(NSFileProviderItemIdentifier)parent name:(NSString *)name prefs:(FRPrefs *)prefs error:(NSError **)error;
@end

@interface FREnumerator : NSObject <NSFileProviderEnumerator>
- (instancetype)initWithContainer:(NSFileProviderItemIdentifier)container path:(NSString *)path;   // path nil = working set
@end

@interface FRFileProviderExtension : NSFileProviderExtension
@end
