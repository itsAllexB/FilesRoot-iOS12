// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import "FRProvider.h"
#import "../shared/FRPolicy.h"
#import <CoreServices/UTType.h>      // (Theos ships its own MobileCoreServices.h)
#import <CoreServices/UTCoreTypes.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#ifdef FR_DEBUG_LOG
void FRDebugLog(NSString *line) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("filesroot.log", DISPATCH_QUEUE_SERIAL); });
    NSString *l = [NSString stringWithFormat:@"%@ [%d] %@\n", [NSDate date], getpid(), line];
    dispatch_async(q, ^{
        FILE *f = fopen("/tmp/filesroot-debug.log", "a");
        if (f) { fputs(l.UTF8String, f); fclose(f); }
    });
}
#endif

// Identifiers are built by appending names, so a real one is always in normal form. Anything else is
// rejected: "link/" makes removefile() delete the link's target folder, "a//b" or "a/./b" are aliases.
static BOOL FRIsNormalPath(NSString *p) {
    if (![p hasPrefix:@"/"]) return NO;
    if (p.length == 1) return YES;
    if ([p hasSuffix:@"/"] || [p hasSuffix:@"/."] || [p hasSuffix:@"/.."]) return NO;
    return [p rangeOfString:@"//"].location == NSNotFound && [p rangeOfString:@"/./"].location == NSNotFound
        && [p rangeOfString:@"/../"].location == NSNotFound && [p rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location == NSNotFound;   // NUL
}

NSString *FRPathForIdentifier(NSFileProviderItemIdentifier identifier, FRPrefs *prefs) {
    if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) return prefs.startPath;
    if (!FRIsNormalPath(identifier)) return nil;
    // Must stay inside the start folder (stale identifiers after changing it in Settings are rejected).
    NSString *start = prefs.startPath;
    if (![start isEqualToString:@"/"] && ![identifier isEqualToString:start] && ![identifier hasPrefix:[start stringByAppendingString:@"/"]])
        return nil;
    return identifier;
}

NSFileProviderItemIdentifier FRIdentifierForPath(NSString *path, FRPrefs *prefs) {
    if ([path isEqualToString:prefs.startPath]) return NSFileProviderRootContainerItemIdentifier;
    return path;
}

NSError *FRErrorFromErrno(int err, NSString *path, BOOL writing) {
    NSString *name = path.lastPathComponent.length ? path.lastPathComponent : path;
    if (err == ENOENT || err == ENOTDIR)
        return [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:@{ NSFilePathErrorKey: path ?: @"" }];
    if (err == EACCES || err == EPERM) {
        NSString *msg = writing
            ? [NSString stringWithFormat:@"“%@” can’t be changed. FilesRoot works as the mobile user and can’t write here.", name]
            : [NSString stringWithFormat:@"“%@” can’t be opened. FilesRoot reads as the mobile user, and this item is only readable by root.", name];
        return [NSError errorWithDomain:NSCocoaErrorDomain code:(writing ? NSFileWriteNoPermissionError : NSFileReadNoPermissionError)
                               userInfo:@{ NSLocalizedDescriptionKey: msg, NSFilePathErrorKey: path ?: @"" }];
    }
    if (err == ENOSPC)
        return [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorInsufficientQuota userInfo:@{ NSFilePathErrorKey: path ?: @"" }];
    if (err == EEXIST)
        return [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorFilenameCollision userInfo:@{ NSFilePathErrorKey: path ?: @"" }];
    NSString *msg = [NSString stringWithFormat:@"“%@”: %s", name, strerror(err)];
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: msg, NSFilePathErrorKey: path ?: @"" }];
}

NSError *FRWriteDeniedError(NSString *path, FRPrefs *prefs) {
    NSString *msg = prefs.allowChanges
        ? [NSString stringWithFormat:@"“%@” is in a protected system location and can’t be changed with FilesRoot.", path.lastPathComponent]
        : @"This location is read-only. Changes can be allowed in Settings > FilesRoot (dangerous).";
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError
                           userInfo:@{ NSLocalizedDescriptionKey: msg, NSFilePathErrorKey: path ?: @"" }];
}

NSError *FRDisabledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError
                           userInfo:@{ NSLocalizedDescriptionKey: @"FilesRoot is turned off in Settings." }];
}

static NSString *FRTypeForExtension(NSString *ext) {
    if (!ext.length) return (NSString *)kUTTypeData;
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSString *key = ext.lowercaseString;
    @synchronized (cache) {
        NSString *t = cache[key];
        if (t) return t;
        CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)key, NULL);
        t = uti ? (__bridge_transfer NSString *)uti : (NSString *)kUTTypeData;
        if (cache.count < 2000) cache[key] = t;
        return t;
    }
}

// Reads at most 512 bytes. Never called for directories, devices or files over 4 MB.
static NSString *FRSniffTextType(const char *path, off_t size, NSString *fallback) {
    if (size <= 0 || size > (4 << 20)) return fallback;
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return fallback;
    unsigned char buf[512];
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    if (n <= 0) return fallback;
    if (n >= 8 && memcmp(buf, "bplist", 6) == 0) return fallback;          // binary plist: not previewable
    for (ssize_t i = 0; i < n; i++) if (buf[i] == 0) return fallback;      // binary data (Mach-O, images ...)
    // Trim a UTF-8 sequence cut off at the end of the buffer before validating.
    ssize_t len = n;
    if (n == (ssize_t)sizeof buf) { ssize_t k = n - 1; while (k > 0 && n - k < 4 && (buf[k] & 0xC0) == 0x80) k--; if (buf[k] >= 0xC0) len = k; }
    NSString *text = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    if (!text) return fallback;
    NSString *head = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([head hasPrefix:@"<?xml"] || [head hasPrefix:@"<!DOCTYPE plist"] || [head hasPrefix:@"<plist"]) return (NSString *)kUTTypeXML;
    return (NSString *)kUTTypePlainText;
}

@implementation FRItem

+ (instancetype)itemWithPath:(NSString *)path identifier:(NSFileProviderItemIdentifier)identifier
                      parent:(NSFileProviderItemIdentifier)parent name:(NSString *)name prefs:(FRPrefs *)prefs error:(NSError **)error {
    const char *p = path.fileSystemRepresentation;
    struct stat lst, st;
    if (lstat(p, &lst) != 0) { if (error) *error = FRErrorFromErrno(errno, path, NO); return nil; }
    BOOL isLink = S_ISLNK(lst.st_mode);
    BOOL resolved = isLink ? (stat(p, &st) == 0) : YES;   // broken links and loops (ELOOP) stay unresolved
    if (!isLink) st = lst;
    if (!resolved) st = lst;

    FRItem *item = [FRItem new];
    item->_path = [path copy];
    item.itemIdentifier = identifier;
    item.parentItemIdentifier = parent;
    item.filename = name ?: path.lastPathComponent;
    item->_isDirectory = resolved && S_ISDIR(st.st_mode);
    item->_isRegularFile = resolved && S_ISREG(st.st_mode);

    if (item->_isDirectory) item.typeIdentifier = (NSString *)kUTTypeFolder;
    else if (item->_isRegularFile) {
        NSString *t = FRTypeForExtension(path.pathExtension);
        // Directories are always "public.folder"; a *file* that claims a package/folder type would confuse Files.
        if (UTTypeConformsTo((__bridge CFStringRef)t, kUTTypeDirectory) || UTTypeConformsTo((__bridge CFStringRef)t, kUTTypePackage)) t = (NSString *)kUTTypeData;
        // Quick Look on iOS 12 only previews what it knows by type. Give text it can show a text type:
        // XML property lists, and small extensionless/unknown files that are plain UTF-8 (/etc/hosts, scripts, logs).
        if ([t isEqualToString:@"com.apple.property-list"] || [t hasPrefix:@"dyn."] || [t isEqualToString:(NSString *)kUTTypeData])
            t = FRSniffTextType(p, st.st_size, t);
        item.typeIdentifier = t;
    } else if (isLink) item.typeIdentifier = (NSString *)kUTTypeSymLink;   // broken link or loop
    else item.typeIdentifier = (NSString *)kUTTypeItem;                     // device, socket, fifo

    if (item->_isRegularFile) item.documentSize = @(st.st_size);
    item.contentModificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9];
    item.creationDate = [NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec + st.st_birthtimespec.tv_nsec / 1e9];

    NSFileProviderItemCapabilities caps = 0;
    if (item->_isDirectory) caps |= NSFileProviderItemCapabilitiesAllowsContentEnumerating | NSFileProviderItemCapabilitiesAllowsReading;
    else if (item->_isRegularFile) caps |= NSFileProviderItemCapabilitiesAllowsReading;
    // Only readable by root: don't offer Open / Copy / Share (they would fail after a wait).
    if ((caps & NSFileProviderItemCapabilitiesAllowsReading) && access(p, R_OK) != 0) caps &= ~NSFileProviderItemCapabilitiesAllowsReading;
    if (prefs.allowChanges) {
        if (item->_isDirectory && fr_can_create_in(p)) caps |= NSFileProviderItemCapabilitiesAllowsAddingSubItems;
        if (![identifier isEqualToString:NSFileProviderRootContainerItemIdentifier] && fr_can_remove(p))
            caps |= NSFileProviderItemCapabilitiesAllowsDeleting | NSFileProviderItemCapabilitiesAllowsRenaming | NSFileProviderItemCapabilitiesAllowsReparenting;
        if (item->_isRegularFile && fr_can_modify(p)) caps |= NSFileProviderItemCapabilitiesAllowsWriting;
    }
    item.capabilities = caps;
    return item;
}

// The real files are always "available": fileproviderd still calls -startProvidingItemAtURL: before anyone
// reads them, but Files shows no cloud/download badges.
- (BOOL)isDownloaded { return YES; }
- (BOOL)isMostRecentVersionDownloaded { return YES; }
- (BOOL)isUploaded { return YES; }

- (NSString *)description { return [NSString stringWithFormat:@"<FRItem %@ type=%@ caps=0x%lx>", self.itemIdentifier, self.typeIdentifier, (unsigned long)self.capabilities]; }

@end
