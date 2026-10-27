// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// Folder listing. Huge folders (/usr/lib, /System/Library/Frameworks, /private/var/db ...) are read with
// readdir() once (names only), sorted, and handed to Files in pages of kFRPageSize items; each page only
// stat()s its own items, so the first rows appear immediately and memory stays small.
//
// Change tracking: the sync anchor is the folder's mtime + the settings generation + (for folders of up to
// kFRWatchMaxEntries items) a signature of the children's sizes and dates. If only the signature changed we
// report the children as updated; otherwise we answer NSFileProviderErrorSyncAnchorExpired and Files simply
// re-lists the folder. While Files keeps an enumerator open it is polled every kFRWatchInterval seconds
// and the container is signalled when its anchor changes, so open folders show new sizes and items.

#import "FRProvider.h"
#include <dirent.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/stat.h>

static const NSUInteger kFRPageSize = 200;
static const NSUInteger kFRWatchMaxEntries = 500;
static const int64_t kFRWatchInterval = 3;

typedef struct { int64_t sec, nsec; uint32_t gen, pad; uint64_t children; } FRAnchor;

// Order-independent hash of the direct children's names, sizes and mtimes; 0 for big or unreadable folders.
static uint64_t FRChildrenSignature(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    uint64_t sum = 0;
    NSUInteger n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (++n > kFRWatchMaxEntries + 2) { sum = 0; break; }     // + "." and ".."
        struct stat st;
        if (fstatat(dirfd(d), e->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) continue;
        uint64_t h = 1469598103934665603ULL;                          // FNV-1a
        for (const unsigned char *c = (const unsigned char *)e->d_name; *c; c++) h = (h ^ *c) * 1099511628211ULL;
        int64_t v[3] = { st.st_size, st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec };
        for (size_t i = 0; i < sizeof v; i++) h = (h ^ ((const unsigned char *)v)[i]) * 1099511628211ULL;
        sum += h;
    }
    closedir(d);
    return sum;
}

@implementation FREnumerator {
    NSFileProviderItemIdentifier _container;
    NSString *_path;          // nil for the working set
    NSArray<NSString *> *_names;
    dispatch_source_t _watch;
    NSData *_watchAnchor;
}

- (instancetype)initWithContainer:(NSFileProviderItemIdentifier)container path:(NSString *)path {
    if ((self = [super init])) {
        _container = [container copy];
        _path = [path copy];
        if (_path) [self startWatching];
    }
    return self;
}

- (void)invalidate {
    _names = nil;
    if (_watch) { dispatch_source_cancel(_watch); _watch = nil; }
}

- (void)dealloc {
    if (_watch) dispatch_source_cancel(_watch);
}

- (NSData *)anchorWithGeneration:(uint32_t)gen {
    FRAnchor a = { 0, 0, gen, 0, 0 };
    struct stat st;
    if (_path && stat(_path.fileSystemRepresentation, &st) == 0) {
        a.sec = st.st_mtimespec.tv_sec; a.nsec = st.st_mtimespec.tv_nsec;
        if (S_ISDIR(st.st_mode)) a.children = FRChildrenSignature(_path.fileSystemRepresentation);
    }
    return [NSData dataWithBytes:&a length:sizeof a];
}

- (NSData *)anchor { return [self anchorWithGeneration:[FRPrefs current].generation]; }

// The poll uses the generation it started with: settings changes are signalled separately (-signalRoot).
- (void)startWatching {
    _watchAnchor = [self anchor];
    __weak typeof(self) weakSelf = self;
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_watch, dispatch_time(DISPATCH_TIME_NOW, kFRWatchInterval * NSEC_PER_SEC), kFRWatchInterval * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_watch, ^{
        FREnumerator *s = weakSelf;
        if (!s) return;
        FRAnchor old;
        [s->_watchAnchor getBytes:&old length:sizeof old];
        NSData *now = [s anchorWithGeneration:old.gen];
        if ([now isEqual:s->_watchAnchor]) return;
        s->_watchAnchor = now;
        FRDLog(@"changed: %@", s->_path);
        [NSFileProviderManager.defaultManager signalEnumeratorForContainerItemIdentifier:s->_container completionHandler:^(NSError *e) {}];
    });
    dispatch_resume(_watch);
}

// readdir() the folder: names only, hidden files filtered, sorted like Finder.
- (NSArray<NSString *> *)listNames:(FRPrefs *)prefs error:(NSError **)error {
    DIR *d = opendir(_path.fileSystemRepresentation);
    if (!d) { if (error) *error = FRErrorFromErrno(errno, _path, NO); return nil; }
    NSMutableArray *names = [NSMutableArray array];
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') {
            if (e->d_name[1] == '\0' || (e->d_name[1] == '.' && e->d_name[2] == '\0')) continue;
            if (!prefs.showHidden) continue;
        }
        NSString *n = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:e->d_name length:strlen(e->d_name)];
        if (n) [names addObject:n];
    }
    closedir(d);
    [names sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a compare:b options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
    return names;
}

- (void)enumerateItemsForObserver:(id<NSFileProviderEnumerationObserver>)observer startingAtPage:(NSFileProviderPage)page {
    FRPrefs *prefs = [FRPrefs current];
    if (!_path) { [observer finishEnumeratingUpToPage:nil]; return; }      // working set: deliberately empty (no indexing of /)
    if (!prefs.enabled) { [observer finishEnumeratingWithError:FRDisabledError()]; return; }

    // Files also asks for an enumerator on single files (to watch them): answer with the file itself.
    struct stat st;
    if (stat(_path.fileSystemRepresentation, &st) == 0 && !S_ISDIR(st.st_mode)) {
        NSError *err = nil;
        FRItem *item = [FRItem itemWithPath:_path identifier:_container parent:FRIdentifierForPath(_path.stringByDeletingLastPathComponent, prefs) name:nil prefs:prefs error:&err];
        if (item) [observer didEnumerateItems:@[ item ]];
        [observer finishEnumeratingUpToPage:nil];
        return;
    }

    NSUInteger offset = 0;
    if (page.length == sizeof(uint64_t) && ![page isEqual:NSFileProviderInitialPageSortedByName] && ![page isEqual:NSFileProviderInitialPageSortedByDate]) {
        uint64_t o = 0; [page getBytes:&o length:sizeof o]; offset = (NSUInteger)o;
    }
    if (offset == 0 || !_names) {
        NSError *err = nil;
        NSArray *names = [self listNames:prefs error:&err];
        if (!names) {
            FRLog(@"list %@ failed: %@", _path, err);
            FRDLog(@"list %@ failed: %@", _path, err);
            [observer finishEnumeratingWithError:err];
            return;
        }
        _names = names;
    }

    NSMutableArray *items = [NSMutableArray arrayWithCapacity:kFRPageSize];
    NSUInteger end = MIN(offset + kFRPageSize, _names.count);
    @autoreleasepool {
        for (NSUInteger i = offset; i < end; i++) {
            NSString *child = [_path stringByAppendingPathComponent:_names[i]];
            FRItem *item = [FRItem itemWithPath:child identifier:FRIdentifierForPath(child, prefs) parent:_container name:nil prefs:prefs error:NULL];
            if (item) [items addObject:item];     // vanished between readdir and stat: skip
        }
    }
    FRDLog(@"enumerate %@ offset=%lu -> %lu items of %lu", _path, (unsigned long)offset, (unsigned long)items.count, (unsigned long)_names.count);
    if (items.count) [observer didEnumerateItems:items];
    if (end < _names.count) {
        uint64_t next = end;
        [observer finishEnumeratingUpToPage:[NSData dataWithBytes:&next length:sizeof next]];
    } else {
        [observer finishEnumeratingUpToPage:nil];
    }
}

- (void)enumerateChangesForObserver:(id<NSFileProviderChangeObserver>)observer fromSyncAnchor:(NSFileProviderSyncAnchor)syncAnchor {
    NSData *now = [self anchor];
    FRDLog(@"changes %@ same=%d", _path, [syncAnchor isEqual:now]);
    if (!_path || [syncAnchor isEqual:now]) {
        [observer finishEnumeratingChangesUpToSyncAnchor:now moreComing:NO];
        return;
    }
    // Same folder mtime and settings, only the children's sizes / dates differ: send them as updates
    // instead of a full re-listing (the folder is small, see FRChildrenSignature).
    FRPrefs *prefs = [FRPrefs current];
    if (syncAnchor.length == now.length && memcmp(syncAnchor.bytes, now.bytes, offsetof(FRAnchor, children)) == 0) {
        NSArray *names = [self listNames:prefs error:NULL];
        if (names && names.count <= kFRWatchMaxEntries) {
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:names.count];
            for (NSString *name in names) {
                NSString *child = [_path stringByAppendingPathComponent:name];
                FRItem *item = [FRItem itemWithPath:child identifier:FRIdentifierForPath(child, prefs) parent:_container name:nil prefs:prefs error:NULL];
                if (item) [items addObject:item];
            }
            if (items.count) [observer didUpdateItems:items];
            [observer finishEnumeratingChangesUpToSyncAnchor:now moreComing:NO];
            return;
        }
    }
    [observer finishEnumeratingWithError:[NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorSyncAnchorExpired userInfo:nil]];
}

- (void)currentSyncAnchorWithCompletionHandler:(void (^)(NSFileProviderSyncAnchor))completionHandler {
    completionHandler([self anchor]);
}

@end
