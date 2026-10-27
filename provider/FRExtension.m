// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import "FRProvider.h"
#import "../shared/FRPolicy.h"
#import <ImageIO/ImageIO.h>
#import <CoreServices/UTType.h>      // (Theos ships its own MobileCoreServices.h)
#import <CoreServices/UTCoreTypes.h>
#include <copyfile.h>
#include <dirent.h>
#include <notify.h>
#include <removefile.h>
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

// Limits for "providing" (copying out) a whole folder.
static const NSUInteger kFRMaxFolderEntries = 20000;
static const unsigned long long kFRMaxFolderBytes = 4ULL << 30;
static const int kFRMaxFolderDepth = 64;
static const unsigned long long kFRFreeSpaceMargin = 200ULL << 20;

// Thumbnails: the extension is jetsam-killed above 15 MB (3840 pages on a 1 GB iPad) and idles at ~2-3 MB.
// ImageIO on iOS 12 decodes JPEG scaled down (a 12 MP photo costs ~1.5 MB), but PNG, GIF, TIFF, HEIC...
// at full size whatever kCGImageSourceThumbnailMaxPixelSize says (~4.5 bytes per pixel, measured on the
// iPad mini 2). So the limit is by pixels, read from the header first, and stricter for full decodes.
static const double kFRThumbMaxPixels = 4.0e6;             // JPEG
static const double kFRThumbMaxPixelsFullDecode = 1.0e6;   // everything else

@implementation FRFileProviderExtension {
    NSURL *_treeURL;      // <documentStorageURL>[/<domain>]/tree
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURL *base = NSFileProviderManager.defaultManager.documentStorageURL;
        if (self.domain) base = [base URLByAppendingPathComponent:self.domain.pathRelativeToDocumentStorage isDirectory:YES];
        _treeURL = [base URLByAppendingPathComponent:@"tree" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:_treeURL withIntermediateDirectories:YES attributes:nil error:NULL];
        fr_set_own_storage(_treeURL.path.fileSystemRepresentation);    // never writable through the location
        FRLog(@"extension started, uid=%d, storage=%@", getuid(), _treeURL.path);
        FRDLog(@"init uid=%d domain=%@ storage=%@", getuid(), self.domain, _treeURL.path);

        // Settings changed: ask Files to refresh the root (sync anchors include the settings generation).
        int token;
        __weak typeof(self) weakSelf = self;
        notify_register_dispatch(kFRPrefsChanged, &token, dispatch_get_main_queue(), ^(int t) { [weakSelf signalRoot]; });

        // Drop copies nobody used for a day.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ [weakSelf purgeOldCopies]; });
    }
    return self;
}

- (NSFileProviderManager *)manager {
    return self.domain ? [NSFileProviderManager managerForDomain:self.domain] : NSFileProviderManager.defaultManager;
}

- (void)signalRoot {
    [self.manager signalEnumeratorForContainerItemIdentifier:NSFileProviderRootContainerItemIdentifier completionHandler:^(NSError *e) {}];
}

#pragma mark - Items and URLs

// Storage URLs may arrive as /private/var/... or /var/...; compare them in one form. (Not
// -stringByStandardizingPath: it only strips /private when the file exists, which copies often don't yet.)
static NSString *FRStoragePath(NSURL *url) {
    NSString *p = url.path;
    if ([p hasPrefix:@"/private/var/"]) p = [p substringFromIndex:8];
    while (p.length > 1 && [p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    return p;
}

- (NSFileProviderItem)itemForIdentifier:(NSFileProviderItemIdentifier)identifier error:(NSError **)error {
    FRDLog(@"itemForIdentifier %@", identifier);
    FRPrefs *prefs = [FRPrefs current];
    NSString *path = FRPathForIdentifier(identifier, prefs);
    if (!path) {
        if (error) *error = [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil];
        return nil;
    }
    BOOL isRoot = [identifier isEqualToString:NSFileProviderRootContainerItemIdentifier];
    NSFileProviderItemIdentifier parent = isRoot ? NSFileProviderRootContainerItemIdentifier
                                                 : FRIdentifierForPath(path.stringByDeletingLastPathComponent, prefs);
    return [FRItem itemWithPath:path identifier:identifier parent:parent name:(isRoot ? prefs.name : nil) prefs:prefs error:error];
}

// <tree>/<logical path>; the start folder is <tree>/<start path> so URLs mirror the hierarchy.
- (NSURL *)URLForItemWithPersistentIdentifier:(NSFileProviderItemIdentifier)identifier {
    NSString *path = FRPathForIdentifier(identifier, [FRPrefs current]);
    if (!path) return nil;
    if ([path isEqualToString:@"/"]) return _treeURL;
    return [_treeURL URLByAppendingPathComponent:[path substringFromIndex:1]];
}

- (NSFileProviderItemIdentifier)persistentIdentifierForItemAtURL:(NSURL *)url {
    NSString *tree = FRStoragePath(_treeURL);
    NSString *p = FRStoragePath(url);
    if ([p rangeOfString:@"/../"].location != NSNotFound || [p hasSuffix:@"/.."]) return nil;
    NSString *logical;
    if ([p isEqualToString:tree]) logical = @"/";
    else if ([p hasPrefix:[tree stringByAppendingString:@"/"]]) logical = [p substringFromIndex:tree.length];
    else return nil;
    FRPrefs *prefs = [FRPrefs current];
    if (!FRPathForIdentifier(logical, prefs) && ![logical isEqualToString:prefs.startPath]) return nil;
    return FRIdentifierForPath(logical, prefs);
}

- (NSString *)realPathForURL:(NSURL *)url {
    NSFileProviderItemIdentifier identifier = [self persistentIdentifierForItemAtURL:url];
    return identifier ? FRPathForIdentifier(identifier, [FRPrefs current]) : nil;
}

- (void)providePlaceholderAtURL:(NSURL *)url completionHandler:(void (^)(NSError *))completionHandler {
    FRDLog(@"placeholder %@", url.path);
    NSFileProviderItemIdentifier identifier = [self persistentIdentifierForItemAtURL:url];
    NSError *error = nil;
    NSFileProviderItem item = identifier ? [self itemForIdentifier:identifier error:&error] : nil;
    if (!item) { completionHandler(error ?: [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil]); return; }
    NSURL *placeholder = [NSFileProviderManager placeholderURLForURL:url];
    [[NSFileManager defaultManager] createDirectoryAtURL:placeholder.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [NSFileProviderManager writePlaceholderAtURL:placeholder withMetadata:item error:&error];
    completionHandler(error);
}

#pragma mark - Providing (copying out of the real filesystem)

static BOOL FRSameVolume(const char *a, const char *b) {
    struct stat sa, sb;
    return stat(a, &sa) == 0 && stat(b, &sb) == 0 && sa.st_dev == sb.st_dev;
}

static unsigned long long FRFreeBytes(const char *path) {
    struct statfs fs;
    return statfs(path, &fs) == 0 ? (unsigned long long)fs.f_bavail * fs.f_bsize : ULLONG_MAX;
}

// Copies one regular file (following a symlink to it). Clone when on the same volume, else copy.
static int FRCopyFile(const char *src, const char *dst, BOOL sameVolume) {
    unlink(dst);
    if (sameVolume && clonefile(src, dst, 0) == 0) return 0;
    if (copyfile(src, dst, NULL, COPYFILE_DATA) != 0) { int e = errno; unlink(dst); return e ?: EIO; }
    return 0;
}

// Recursive folder copy for "Copy" / drag of a whole folder out of the location. Symlinks are recreated as
// symlinks (never followed, so loops are harmless); devices, sockets and FIFOs are skipped.
static int FRCopyTree(const char *src, const char *dst, BOOL same, int depth, NSUInteger *entries, unsigned long long *bytes) {
    if (depth > kFRMaxFolderDepth) return ELOOP;
    if (mkdir(dst, 0755) != 0 && errno != EEXIST) return errno;
    DIR *d = opendir(src);
    if (!d) return errno;
    struct dirent *e;
    int rc = 0;
    while (rc == 0 && (e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (++*entries > kFRMaxFolderEntries) { rc = EFBIG; break; }
        char s[PATH_MAX], t[PATH_MAX];
        if (snprintf(s, sizeof s, "%s/%s", src, e->d_name) >= (int)sizeof s || snprintf(t, sizeof t, "%s/%s", dst, e->d_name) >= (int)sizeof t) { rc = ENAMETOOLONG; break; }
        struct stat st;
        if (lstat(s, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            int r = FRCopyTree(s, t, same, depth + 1, entries, bytes);
            if (r == EACCES || r == EPERM) continue;     // unreadable sub folder: leave it empty
            rc = r;
        } else if (S_ISREG(st.st_mode)) {
            *bytes += st.st_size;
            if (*bytes > kFRMaxFolderBytes) { rc = EFBIG; break; }
            int r = FRCopyFile(s, t, same);
            if (r == EACCES || r == EPERM) continue;     // unreadable file: skip it
            rc = r;
        } else if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t n = readlink(s, target, sizeof target - 1);
            if (n >= 0) { target[n] = 0; unlink(t); symlink(target, t); }
        }
    }
    closedir(d);
    return rc;
}

// Metadata-only walk to size up a folder before copying anything (stops as soon as a limit is passed).
static int FRScanTree(const char *src, int depth, NSUInteger *entries, unsigned long long *bytes) {
    if (depth > kFRMaxFolderDepth) return ELOOP;
    DIR *d = opendir(src);
    if (!d) return (errno == EACCES || errno == EPERM) ? 0 : errno;
    struct dirent *e;
    int rc = 0;
    while (rc == 0 && (e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (++*entries > kFRMaxFolderEntries) { rc = EFBIG; break; }
        char s[PATH_MAX];
        if (snprintf(s, sizeof s, "%s/%s", src, e->d_name) >= (int)sizeof s) { rc = ENAMETOOLONG; break; }
        struct stat st;
        if (lstat(s, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) rc = FRScanTree(s, depth + 1, entries, bytes);
        else if (S_ISREG(st.st_mode)) { *bytes += st.st_size; if (*bytes > kFRMaxFolderBytes) rc = EFBIG; }
    }
    closedir(d);
    return rc;
}

- (void)startProvidingItemAtURL:(NSURL *)url completionHandler:(void (^)(NSError *))completionHandler {
    FRDLog(@"startProviding %@", url.path);
    FRPrefs *prefs = [FRPrefs current];
    if (!prefs.enabled) { completionHandler(FRDisabledError()); return; }
    NSString *real = [self realPathForURL:url];
    if (!real) { completionHandler([NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil]); return; }

    const char *src = real.fileSystemRepresentation;
    const char *dst = url.path.fileSystemRepresentation;
    struct stat st;
    if (stat(src, &st) != 0) { completionHandler(FRErrorFromErrno(errno, real, NO)); return; }
    [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    BOOL same = FRSameVolume(src, _treeURL.path.fileSystemRepresentation);

    if (S_ISREG(st.st_mode)) {
        // Already provided and unchanged (same size and mtime, which we copy over)? Keep it.
        struct stat cur;
        if (stat(dst, &cur) == 0 && S_ISREG(cur.st_mode) && cur.st_size == st.st_size
            && cur.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec && cur.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec) {
            completionHandler(nil);
            return;
        }
        if (access(src, R_OK) != 0) { completionHandler(FRErrorFromErrno(errno, real, NO)); return; }
        if (!same && (unsigned long long)st.st_size + kFRFreeSpaceMargin > FRFreeBytes(_treeURL.path.fileSystemRepresentation)) {
            completionHandler(FRErrorFromErrno(ENOSPC, real, NO)); return;
        }
        if (stat(dst, &cur) == 0 && S_ISDIR(cur.st_mode)) removefile(dst, NULL, REMOVEFILE_RECURSIVE);
        NSString *tmp = [url.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:[NSString stringWithFormat:@".fr-%@", NSUUID.UUID.UUIDString]];
        int rc = FRCopyFile(src, tmp.fileSystemRepresentation, same);
        if (rc == 0) {
            chmod(tmp.fileSystemRepresentation, 0644);
            struct timeval tv[2] = { { st.st_atimespec.tv_sec, (int)(st.st_atimespec.tv_nsec / 1000) }, { st.st_mtimespec.tv_sec, (int)(st.st_mtimespec.tv_nsec / 1000) } };
            utimes(tmp.fileSystemRepresentation, tv);
            // utimes() has microsecond precision: compare-and-skip above uses what we actually stored.
            struct stat now; if (stat(tmp.fileSystemRepresentation, &now) == 0) st.st_mtimespec = now.st_mtimespec;
            if (rename(tmp.fileSystemRepresentation, dst) != 0) { rc = errno; unlink(tmp.fileSystemRepresentation); }
        }
        FRDLog(@"provided %@ rc=%d", real, rc);
        FRLog(@"provide %@ (%lld bytes, %s) -> %d", real, (long long)st.st_size, same ? "clone" : "copy", rc);
        completionHandler(rc ? FRErrorFromErrno(rc, real, NO) : nil);
        return;
    }

    if (S_ISDIR(st.st_mode)) {
        NSUInteger entries = 0; unsigned long long bytes = 0;
        int scan = FRScanTree(src, 0, &entries, &bytes);
        if (scan == 0 && !same && bytes + kFRFreeSpaceMargin > FRFreeBytes(_treeURL.path.fileSystemRepresentation)) scan = ENOSPC;
        if (scan == EFBIG) {
            FRLog(@"folder %@ too big to provide (%lu+ entries, %llu+ bytes)", real, (unsigned long)entries, bytes);
            completionHandler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadTooLargeError userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"“%@” is too big to copy out at once (more than %lu items or %llu GB).",
                    real.lastPathComponent, (unsigned long)kFRMaxFolderEntries, kFRMaxFolderBytes >> 30] }]);
            return;
        }
        if (scan) { completionHandler(FRErrorFromErrno(scan, real, NO)); return; }
        entries = 0; bytes = 0;
        NSString *tmp = [url.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:[NSString stringWithFormat:@".fr-%@", NSUUID.UUID.UUIDString]];
        int rc = FRCopyTree(src, tmp.fileSystemRepresentation, same, 0, &entries, &bytes);
        if (rc == 0) {
            removefile(dst, NULL, REMOVEFILE_RECURSIVE);
            if (rename(tmp.fileSystemRepresentation, dst) != 0) rc = errno;
        }
        if (rc) removefile(tmp.fileSystemRepresentation, NULL, REMOVEFILE_RECURSIVE);
        FRLog(@"provide folder %@ (%lu entries, %llu bytes) -> %d", real, (unsigned long)entries, bytes, rc);
        if (rc == EFBIG) {
            completionHandler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadTooLargeError userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"“%@” is too big to copy out at once (more than %lu items or %llu GB).",
                    real.lastPathComponent, (unsigned long)kFRMaxFolderEntries, kFRMaxFolderBytes >> 30] }]);
            return;
        }
        completionHandler(rc ? FRErrorFromErrno(rc, real, NO) : nil);
        return;
    }

    completionHandler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"“%@” is not a regular file (device, socket or broken link).", real.lastPathComponent] }]);
}

- (void)stopProvidingItemAtURL:(NSURL *)url {
    FRDLog(@"stopProviding %@", url.path);
    // Only ever delete inside our own storage.
    NSString *p = FRStoragePath(url);
    if (![p hasPrefix:[FRStoragePath(_treeURL) stringByAppendingString:@"/"]] || [p rangeOfString:@"/../"].location != NSNotFound) return;
    removefile(url.path.fileSystemRepresentation, NULL, REMOVEFILE_RECURSIVE);
    [[NSFileManager defaultManager] removeItemAtURL:[NSFileProviderManager placeholderURLForURL:url] error:NULL];
}

// Another app edited a provided copy in place. Written back only when changes are allowed for that path.
- (void)itemChangedAtURL:(NSURL *)url {
    FRDLog(@"itemChanged %@", url.path);
    FRPrefs *prefs = [FRPrefs current];
    NSString *real = [self realPathForURL:url];
    if (!real) return;
    if (!prefs.enabled || !prefs.allowChanges || !fr_can_modify(real.fileSystemRepresentation)) {
        FRLog(@"ignored change to the copy of %@ (read-only)", real);
        return;
    }
    struct stat st;
    if (stat(real.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return;
    int rc = copyfile(url.path.fileSystemRepresentation, real.fileSystemRepresentation, NULL, COPYFILE_DATA) == 0 ? 0 : errno;
    FRLog(@"wrote back %@ -> %d", real, rc);
}

- (void)purgeOldCopies {
    time_t cutoff = time(NULL) - 24 * 3600;
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtURL:_treeURL includingPropertiesForKeys:nil options:0 errorHandler:nil];
    NSUInteger n = 0;
    for (NSURL *u in en) {
        struct stat st;
        if (lstat(u.path.fileSystemRepresentation, &st) == 0 && !S_ISDIR(st.st_mode) && st.st_ctimespec.tv_sec < cutoff) {
            unlink(u.path.fileSystemRepresentation);
            n++;
        }
    }
    if (n) FRLog(@"purged %lu old copies", (unsigned long)n);
}

#pragma mark - Enumeration

- (id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier error:(NSError **)error {
    FRDLog(@"enumerator %@", containerItemIdentifier);
    if ([containerItemIdentifier isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier])
        return [[FREnumerator alloc] initWithContainer:containerItemIdentifier path:nil];
    FRPrefs *prefs = [FRPrefs current];
    NSString *path = FRPathForIdentifier(containerItemIdentifier, prefs);
    if (!path) {
        if (error) *error = [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil];
        return nil;
    }
    return [[FREnumerator alloc] initWithContainer:containerItemIdentifier path:path];
}

#pragma mark - Changes (only with "Allow Changes", and never in protected paths)

- (NSString *)writablePathForIdentifier:(NSFileProviderItemIdentifier)identifier prefs:(FRPrefs *)prefs error:(NSError **)error {
    NSString *path = FRPathForIdentifier(identifier, prefs);
    if (!path) { *error = [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil]; return nil; }
    if (!prefs.enabled) { *error = FRDisabledError(); return nil; }
    if (!prefs.allowChanges) { *error = FRWriteDeniedError(path, prefs); return nil; }
    return path;
}

static NSString *FRUniqueName(NSString *dir, NSString *name) {
    NSString *candidate = name;
    NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    for (int i = 2; i < 1000; i++) {
        struct stat st;
        if (lstat([dir stringByAppendingPathComponent:candidate].fileSystemRepresentation, &st) != 0) return candidate;
        candidate = ext.length ? [NSString stringWithFormat:@"%@ %d.%@", base, i, ext] : [NSString stringWithFormat:@"%@ %d", base, i];
    }
    return nil;
}

static BOOL FRValidName(NSString *name) {
    return name.length > 0 && ![name isEqualToString:@"."] && ![name isEqualToString:@".."] && [name rangeOfString:@"/"].location == NSNotFound;
}

- (void)importDocumentAtURL:(NSURL *)fileURL toParentItemIdentifier:(NSFileProviderItemIdentifier)parentItemIdentifier
          completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    FRPrefs *prefs = [FRPrefs current];
    NSError *error = nil;
    NSString *dir = [self writablePathForIdentifier:parentItemIdentifier prefs:prefs error:&error];
    if (!dir) { completionHandler(nil, error); return; }
    if (!fr_can_create_in(dir.fileSystemRepresentation)) { completionHandler(nil, FRWriteDeniedError(dir, prefs)); return; }
    NSString *name = FRUniqueName(dir, fileURL.lastPathComponent);
    if (!name) { completionHandler(nil, FRErrorFromErrno(EEXIST, dir, YES)); return; }
    NSString *dst = [dir stringByAppendingPathComponent:name];
    BOOL scoped = [fileURL startAccessingSecurityScopedResource];
    // NOFOLLOW: symlinks in the imported item are copied as links, never followed (they could lead anywhere).
    int rc = copyfile(fileURL.path.fileSystemRepresentation, dst.fileSystemRepresentation, NULL,
                      COPYFILE_DATA | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW) == 0 ? 0 : errno;
    if (scoped) [fileURL stopAccessingSecurityScopedResource];
    FRLog(@"import %@ -> %@ : %d", fileURL.path, dst, rc);
    if (rc) { completionHandler(nil, FRErrorFromErrno(rc, dst, YES)); return; }
    completionHandler([self itemForIdentifier:FRIdentifierForPath(dst, prefs) error:NULL], nil);
}

- (void)createDirectoryWithName:(NSString *)directoryName inParentItemIdentifier:(NSFileProviderItemIdentifier)parentItemIdentifier
              completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    FRPrefs *prefs = [FRPrefs current];
    NSError *error = nil;
    NSString *dir = [self writablePathForIdentifier:parentItemIdentifier prefs:prefs error:&error];
    if (!dir) { completionHandler(nil, error); return; }
    if (!FRValidName(directoryName)) { completionHandler(nil, FRErrorFromErrno(EINVAL, directoryName, YES)); return; }
    if (!fr_can_create_in(dir.fileSystemRepresentation)) { completionHandler(nil, FRWriteDeniedError(dir, prefs)); return; }
    NSString *dst = [dir stringByAppendingPathComponent:directoryName];
    int rc = mkdir(dst.fileSystemRepresentation, 0755) == 0 ? 0 : errno;
    FRLog(@"mkdir %@ : %d", dst, rc);
    if (rc) { completionHandler(nil, FRErrorFromErrno(rc, dst, YES)); return; }
    completionHandler([self itemForIdentifier:FRIdentifierForPath(dst, prefs) error:NULL], nil);
}

- (void)moveItem:(NSFileProviderItemIdentifier)identifier toDir:(NSString *)newDir name:(NSString *)newName
     completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    FRPrefs *prefs = [FRPrefs current];
    NSError *error = nil;
    NSString *src = [self writablePathForIdentifier:identifier prefs:prefs error:&error];
    if (!src) { completionHandler(nil, error); return; }
    if (!FRValidName(newName)) { completionHandler(nil, FRErrorFromErrno(EINVAL, newName ?: @"", YES)); return; }
    if (!fr_can_remove(src.fileSystemRepresentation)) { completionHandler(nil, FRWriteDeniedError(src, prefs)); return; }
    if (!fr_can_create_in(newDir.fileSystemRepresentation)) { completionHandler(nil, FRWriteDeniedError(newDir, prefs)); return; }
    NSString *dst = [newDir stringByAppendingPathComponent:newName];
    struct stat st;
    if (lstat(dst.fileSystemRepresentation, &st) == 0) { completionHandler(nil, FRErrorFromErrno(EEXIST, dst, YES)); return; }
    int rc = renamex_np(src.fileSystemRepresentation, dst.fileSystemRepresentation, RENAME_EXCL) == 0 ? 0 : errno;
    FRLog(@"move %@ -> %@ : %d", src, dst, rc);
    if (rc == EXDEV) {
        completionHandler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{
            NSLocalizedDescriptionKey: @"Items can only be moved within the same volume. Copy it instead." }]);
        return;
    }
    if (rc) { completionHandler(nil, FRErrorFromErrno(rc, src, YES)); return; }
    completionHandler([self itemForIdentifier:FRIdentifierForPath(dst, prefs) error:NULL], nil);
}

- (void)renameItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier toName:(NSString *)itemName
               completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    NSString *path = FRPathForIdentifier(itemIdentifier, [FRPrefs current]);
    [self moveItem:itemIdentifier toDir:path.stringByDeletingLastPathComponent name:itemName completionHandler:completionHandler];
}

- (void)reparentItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier toParentItemWithIdentifier:(NSFileProviderItemIdentifier)parentItemIdentifier
                           newName:(NSString *)newName completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    FRPrefs *prefs = [FRPrefs current];
    NSString *path = FRPathForIdentifier(itemIdentifier, prefs);
    NSString *dir = FRPathForIdentifier(parentItemIdentifier, prefs);
    if (!dir) { completionHandler(nil, [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorNoSuchItem userInfo:nil]); return; }
    [self moveItem:itemIdentifier toDir:dir name:(newName ?: path.lastPathComponent) completionHandler:completionHandler];
}

- (void)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSError *))completionHandler {
    FRPrefs *prefs = [FRPrefs current];
    NSError *error = nil;
    NSString *path = [self writablePathForIdentifier:itemIdentifier prefs:prefs error:&error];
    if (!path) { completionHandler(error); return; }
    if (!fr_can_remove(path.fileSystemRepresentation)) { completionHandler(FRWriteDeniedError(path, prefs)); return; }
    // A symlink is unlinked, its target is untouched. (Not left to removefile(): given "link/" it deleted
    // the target folder. FRPathForIdentifier rejects such paths now, this is the second line.)
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    int rc;
    if (lstat(p, &st) == 0 && S_ISLNK(st.st_mode)) rc = unlink(p) == 0 ? 0 : errno;
    else rc = removefile(p, NULL, REMOVEFILE_RECURSIVE) == 0 ? 0 : errno;
    FRLog(@"delete %@ : %d", path, rc);
    completionHandler(rc ? FRErrorFromErrno(rc, path, YES) : nil);
}

- (void)trashItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    completionHandler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}

// Bookkeeping Files does when opening items; nothing is stored, but they must not fail.
- (void)setLastUsedDate:(NSDate *)lastUsedDate forItemIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    completionHandler([self itemForIdentifier:itemIdentifier error:NULL], nil);
}
- (void)setTagData:(NSData *)tagData forItemIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    completionHandler([self itemForIdentifier:itemIdentifier error:NULL], nil);
}
- (void)setFavoriteRank:(NSNumber *)favoriteRank forItemIdentifier:(NSFileProviderItemIdentifier)itemIdentifier completionHandler:(void (^)(NSFileProviderItem, NSError *))completionHandler {
    completionHandler([self itemForIdentifier:itemIdentifier error:NULL], nil);
}

#pragma mark - Thumbnails (images only, limited by pixel count)

// One at a time for the whole extension: Files asks for a folder's thumbnails in several batches at once.
static dispatch_queue_t FRThumbnailQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("filesroot.thumbnails", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    return q;
}

static NSData *FRThumbnailData(NSString *path, CGFloat maxSide) {
    NSDictionary *noCache = @{ (id)kCGImageSourceShouldCache: @NO };
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFDictionaryRef)noCache);
    if (!src) return nil;
    NSData *data = nil;
    // Header only: no pixels are decoded here.
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, (__bridge CFDictionaryRef)noCache));
    double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue], h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
    CFStringRef type = CGImageSourceGetType(src);
    double limit = (type && UTTypeEqual(type, kUTTypeJPEG)) ? kFRThumbMaxPixels : kFRThumbMaxPixelsFullDecode;
    if (w > 0 && h > 0 && w * h <= limit) {
        NSDictionary *opts = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,     // never an embedded preview of unknown size
                                (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                (id)kCGImageSourceShouldCache: @NO,
                                (id)kCGImageSourceShouldCacheImmediately: @NO,
                                (id)kCGImageSourceThumbnailMaxPixelSize: @(maxSide) };
        CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
        if (thumb) {
            NSMutableData *out = [NSMutableData data];
            CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, kUTTypePNG, 1, NULL);
            if (dst) { CGImageDestinationAddImage(dst, thumb, NULL); if (CGImageDestinationFinalize(dst)) data = out; CFRelease(dst); }
            CGImageRelease(thumb);
        }
    } else {
        FRDLog(@"no thumbnail for %@ (%.0fx%.0f %@)", path, w, h, type);
    }
    CFRelease(src);
    return data;
}

- (NSProgress *)fetchThumbnailsForItemIdentifiers:(NSArray<NSFileProviderItemIdentifier> *)itemIdentifiers requestedSize:(CGSize)size
                    perThumbnailCompletionHandler:(void (^)(NSFileProviderItemIdentifier, NSData *, NSError *))perThumbnailCompletionHandler
                                completionHandler:(void (^)(NSError *))completionHandler {
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:itemIdentifiers.count];
    FRPrefs *prefs = [FRPrefs current];
    CGFloat maxSide = MAX(64, MIN(512, MAX(size.width, size.height)));
    dispatch_async(FRThumbnailQueue(), ^{
        for (NSFileProviderItemIdentifier identifier in itemIdentifiers) {
            if (progress.isCancelled) break;
            NSData *data = nil;
            @autoreleasepool {
                NSString *path = prefs.thumbnails && prefs.enabled ? FRPathForIdentifier(identifier, prefs) : nil;
                struct stat st;
                CFStringRef uti = path ? UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)path.pathExtension.lowercaseString, NULL) : NULL;
                BOOL image = uti && UTTypeConformsTo(uti, kUTTypeImage);
                if (uti) CFRelease(uti);
                if (image && stat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) && access(path.fileSystemRepresentation, R_OK) == 0)
                    data = FRThumbnailData(path, maxSide);
            }
            perThumbnailCompletionHandler(identifier, data, nil);
            progress.completedUnitCount++;
        }
        completionHandler(nil);
    });
    return progress;
}

@end
