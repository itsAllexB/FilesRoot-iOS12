// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#include "FRPolicy.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// Never writable, even with "Allow Changes" on. Canonical (symlink-free) paths: /var, /etc and /tmp are
// symlinks into /private on iOS. Root-level dot files (/.bootstrapped, /.installed_odyssey,
// /.procursus_strapped, ...) are handled separately in fr_is_protected().
static const char *const kProtected[] = {
    "/System",
    "/usr",                                   // includes /usr/lib, /usr/libexec, /usr/bin
    "/bin",
    "/sbin",
    "/Library",                               // tweaks, LaunchDaemons, PreferenceLoader, ...
    "/Applications",
    "/binpack",                               // checkra1n
    "/dev",
    "/cores",
    "/private/etc",                           // /etc, incl. /etc/apt, fstab, passwd
    "/private/preboot",
    "/private/xarts",
    "/private/var/lib",                       // dpkg / apt state
    "/private/var/cache/apt",
    "/private/var/containers/Bundle",         // installed app bundles
    "/private/var/containers/Shared/SystemGroup",
    "/private/var/containers/Data/System",
    "/private/var/db",
    "/private/var/root",
    "/private/var/run",
    "/private/var/keybags",
    "/private/var/Keychains",
    "/private/var/MobileSoftwareUpdate",
    "/private/var/MobileAsset",
    "/private/var/preferences",
    "/private/var/installd",
    "/private/var/hardware",
    "/private/var/wireless",
    "/private/var/mobile/Library/Keychains",
    "/private/var/mobile/Library/FrontBoard",
    "/private/var/mobile/Library/Caches/com.apple.LaunchServices",
    "/private/var/mobile/Library/Caches/com.apple.dyld",
    NULL
};

// Folders that are part of the layout: they and their direct children can't be deleted / renamed / moved.
// (New items may still be created inside them unless they are also protected.)
static const char *const kStructuralParents[] = {
    "/",
    "/private",
    "/private/var",
    "/private/var/mobile",
    "/private/var/mobile/Library",
    "/private/var/mobile/Library/Preferences",
    "/private/var/mobile/Media",
    "/private/var/mobile/Containers",
    "/private/var/mobile/Containers/Data",
    "/private/var/mobile/Containers/Shared",
    "/private/var/mobile/Containers/Data/Application",
    "/private/var/mobile/Containers/Data/PluginKitPlugin",
    "/private/var/mobile/Containers/Shared/AppGroup",
    "/private/var/containers",
    "/private/var/containers/Data",
    "/private/var/containers/Shared",
    NULL
};

// <AppGroup>/<any group id>/File Provider Storage: the storage of every File Provider (On My iPad's top
// level is group.com.apple.FileProvider.LocalStorage's). Matched by shape, the group UUIDs differ per device.
static const char kAppGroups[] = "/private/var/mobile/Containers/Shared/AppGroup/";
static const char kFPStorage[] = "File Provider Storage";

static char *gOwnStorage;     // canonical path of FilesRoot's own storage ("tree"), or NULL

static int under(const char *path, const char *prefix) {
    size_t n = strlen(prefix);
    if (strncmp(path, prefix, n) != 0) return 0;
    return path[n] == '\0' || path[n] == '/';
}

static char *dup_join(const char *dir, const char *name) {
    size_t a = strlen(dir), b = strlen(name);
    int slash = (a > 0 && dir[a - 1] == '/') ? 0 : 1;
    char *out = malloc(a + slash + b + 1);
    if (!out) return NULL;
    memcpy(out, dir, a);
    if (slash) out[a] = '/';
    memcpy(out + a + slash, name, b + 1);
    return out;
}

char *fr_canonical_nofollow(const char *path) {
    if (!path || path[0] != '/') return NULL;
    size_t len = strlen(path);
    char *tmp = strdup(path);
    if (!tmp) return NULL;
    while (len > 1 && tmp[len - 1] == '/') tmp[--len] = '\0';       // trailing slashes
    if (strcmp(tmp, "/") == 0) { free(tmp); return strdup("/"); }
    char *slash = strrchr(tmp, '/');
    const char *name = slash + 1;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || *name == '\0') {
        // "x/.." or "x/." : resolve the whole thing instead.
        char buf[PATH_MAX];
        char *r = realpath(tmp, buf) ? strdup(buf) : NULL;
        free(tmp);
        return r;
    }
    *slash = '\0';
    const char *parent = (slash == tmp) ? "/" : tmp;
    char buf[PATH_MAX];
    if (!realpath(parent, buf)) { free(tmp); return NULL; }
    char *out = dup_join(buf, name);
    free(tmp);
    return out;
}

char *fr_canonical_follow(const char *path) {
    if (!path || path[0] != '/') return NULL;
    char buf[PATH_MAX];
    if (realpath(path, buf)) return strdup(buf);
    return fr_canonical_nofollow(path);
}

void fr_set_own_storage(const char *path) {
    free(gOwnStorage);
    gOwnStorage = path ? fr_canonical_follow(path) : NULL;
}

// 1 when canon is exactly <AppGroup>/<id>/File Provider Storage.
static int is_fp_storage(const char *canon) {
    size_t n = sizeof kAppGroups - 1;
    if (strncmp(canon, kAppGroups, n) != 0) return 0;
    const char *id = canon + n, *slash = strchr(id, '/');
    if (!slash || slash == id) return 0;
    return strcmp(slash + 1, kFPStorage) == 0;
}

int fr_is_protected(const char *canon) {
    if (!canon || canon[0] != '/') return 1;
    if (canon[1] == '.') return 1;                                  // /.bootstrapped, /.installed_*, /.file ...
    if (gOwnStorage && under(canon, gOwnStorage)) return 1;
    for (int i = 0; kProtected[i]; i++)
        if (under(canon, kProtected[i])) return 1;
    return 0;
}

int fr_is_structural(const char *canon) {
    if (!canon || canon[0] != '/') return 1;
    if (strcmp(canon, "/") == 0) return 1;
    if (is_fp_storage(canon)) return 1;
    if (gOwnStorage && strcmp(canon, gOwnStorage) == 0) return 1;
    for (int i = 0; kStructuralParents[i]; i++) {
        const char *p = kStructuralParents[i];
        if (strcmp(canon, p) == 0) return 1;
        // direct child of p?
        size_t n = strlen(p);
        const char *rest;
        if (strcmp(p, "/") == 0) rest = canon + 1;
        else if (strncmp(canon, p, n) == 0 && canon[n] == '/') rest = canon + n + 1;
        else continue;
        if (*rest && !strchr(rest, '/')) return 1;
    }
    return 0;
}

int fr_is_no_new_items(const char *canon) {
    if (!canon || canon[0] != '/') return 1;
    if (strcmp(canon, "/") == 0 || strcmp(canon, "/private") == 0 || strcmp(canon, "/private/var") == 0) return 1;
    if (is_fp_storage(canon)) return 1;
    return gOwnStorage && under(canon, gOwnStorage);
}

int fr_can_create_in(const char *dir) {
    char buf[PATH_MAX];
    if (!dir || dir[0] != '/' || !realpath(dir, buf)) return 0;     // the folder must exist
    return !fr_is_protected(buf) && !fr_is_no_new_items(buf);
}

int fr_can_modify(const char *file) {
    char *a = fr_canonical_nofollow(file), *b = fr_canonical_follow(file);
    int ok = a && b && !fr_is_protected(a) && !fr_is_protected(b);
    // A hard-linked file shares its contents with another name, possibly in a protected folder
    // (the policy only sees this one): never write to it.
    struct stat st;
    if (ok && stat(b, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink > 1) ok = 0;
    free(a); free(b);
    return ok;
}

int fr_can_remove(const char *path) {
    // Only the item itself is removed / renamed (a symlink is unlinked, never its target).
    char *a = fr_canonical_nofollow(path);
    int ok = a && !fr_is_protected(a) && !fr_is_structural(a);
    free(a);
    return ok;
}
