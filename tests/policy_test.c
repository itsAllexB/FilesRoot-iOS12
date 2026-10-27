// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// Unit test for FRPolicy.
//   Mac:  cc -I../shared ../shared/FRPolicy.c policy_test.c -o policy_test && ./policy_test
//   iPad: build it as a Theos tool (iphone:clang:14.5:12.0), copy it to /usr/local/bin (iOS refuses to run
//         binaries from /var) and run it as mobile; it then also checks the real layout and the fixtures in
//         /var/mobile/Documents/FilesRootTest. Remove it afterwards.
// Uses only canonical (already resolved) paths for the pure checks, and the real filesystem
// read-only for the symlink checks (/var, /etc and /tmp are symlinks on iOS and on macOS).
#include "FRPolicy.h"
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static int fails = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } else printf("ok:   %s\n", msg); } while (0)

int main(void) {
    // protected
    const char *prot[] = { "/System", "/System/Library/Frameworks/UIKit.framework", "/usr/lib/libSystem.B.dylib",
        "/usr/bin", "/bin/sh", "/sbin/launchd", "/Library/MobileSubstrate", "/Applications/Filza.app",
        "/private/etc/apt/sources.list.d", "/private/var/lib/dpkg/status", "/.bootstrapped", "/.installed_odyssey",
        "/.procursus_strapped", "/private/var/containers/Bundle/Application/X/Foo.app/Info.plist",
        "/private/var/root", "/private/var/db/stash", "/binpack/bin/sh", "/dev/disk0", NULL };
    for (int i = 0; prot[i]; i++) { char m[300]; snprintf(m, sizeof m, "protected %s", prot[i]); EXPECT(fr_is_protected(prot[i]), m); }
    const char *free_[] = { "/private/var/mobile/Documents/FilesRootTest", "/private/var/mobile/Documents/FilesRootTest/a.txt",
        "/private/var/tmp/x", "/private/tmp/x", "/private/var/mobile/Library/Preferences/com.foo.plist",
        "/usrlocal", "/Systemx", NULL };
    for (int i = 0; free_[i]; i++) { char m[300]; snprintf(m, sizeof m, "not protected %s", free_[i]); EXPECT(!fr_is_protected(free_[i]), m); }

    // structural
    const char *st[] = { "/", "/private", "/private/var", "/private/var/mobile", "/private/var/mobile/Documents",
        "/private/var/mobile/Library", "/private/var/mobile/Library/SMS", "/private/var/mobile/Library/Preferences/com.apple.springboard.plist",
        "/private/var/mobile/Containers/Data/Application/1234-ABCD", "/private/var/tmp", "/private/tmp", "/Users", NULL };
    for (int i = 0; st[i]; i++) { char m[300]; snprintf(m, sizeof m, "structural %s", st[i]); EXPECT(fr_is_structural(st[i]), m); }
    const char *nst[] = { "/private/var/mobile/Documents/FilesRootTest", "/private/var/mobile/Documents/FilesRootTest/sub",
        "/private/var/mobile/Containers/Data/Application/1234-ABCD/Documents", "/private/var/mobile/Library/SMS/sms.db", NULL };
    for (int i = 0; nst[i]; i++) { char m[300]; snprintf(m, sizeof m, "not structural %s", nst[i]); EXPECT(!fr_is_structural(nst[i]), m); }

    // File Provider storage folders (any app group): structural and "no new items"; their contents are not.
    const char *fps[] = { "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/File Provider Storage",
        "/private/var/mobile/Containers/Shared/AppGroup/00000000-1111-2222-3333-444444444444/File Provider Storage", NULL };
    for (int i = 0; fps[i]; i++) {
        char m[300];
        snprintf(m, sizeof m, "structural %s", fps[i]); EXPECT(fr_is_structural(fps[i]), m);
        snprintf(m, sizeof m, "no new items in %s", fps[i]); EXPECT(fr_is_no_new_items(fps[i]), m);
        EXPECT(!fr_is_protected(fps[i]), "File Provider Storage itself is not protected (its folders stay usable)");
    }
    const char *nfps[] = { "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/File Provider Storage/ExtTest",
        "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/File Provider Storage x",
        "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/Library/File Provider Storage",
        "/private/var/mobile/Containers/Shared/File Provider Storage", "/private/var/mobile/Documents", NULL };
    for (int i = 0; nfps[i]; i++) {
        char m[300];
        snprintf(m, sizeof m, "new items allowed in %s", nfps[i]); EXPECT(!fr_is_no_new_items(nfps[i]), m);
    }
    EXPECT(!fr_is_structural(nfps[0]), "a folder inside File Provider Storage is not structural");
    EXPECT(fr_is_no_new_items("/") && fr_is_no_new_items("/private") && fr_is_no_new_items("/private/var"), "no new items in /, /private, /private/var");

    // FilesRoot's own storage ("tree") and hard links, against a temporary folder.
    char tmp[] = "/tmp/frpolicy.XXXXXX";
    if (mkdtemp(tmp)) {
        char tree[300], f[300], f2[300], g[300], sub[300];
        snprintf(tree, sizeof tree, "%s/tree", tmp); mkdir(tree, 0755);
        snprintf(sub, sizeof sub, "%s/tree/var", tmp); mkdir(sub, 0755);
        snprintf(g, sizeof g, "%s/tree/var/copy.txt", tmp); fclose(fopen(g, "w"));
        snprintf(f, sizeof f, "%s/single.txt", tmp); fclose(fopen(f, "w"));
        EXPECT(fr_can_create_in(tree) && fr_can_remove(tree), "before fr_set_own_storage the tree is an ordinary folder");
        fr_set_own_storage(tree);
        EXPECT(!fr_can_create_in(tree), "can't create in the own storage tree");
        EXPECT(!fr_can_create_in(sub), "can't create inside the own storage tree");
        EXPECT(!fr_can_remove(tree), "can't remove / rename / move the own storage tree");
        EXPECT(!fr_can_remove(g) && !fr_can_modify(g), "can't change copies inside the own storage tree");
        EXPECT(fr_can_create_in(tmp), "the folder around the tree is unaffected");
        fr_set_own_storage(NULL);
        EXPECT(fr_can_create_in(tree), "fr_set_own_storage(NULL) clears it");

        EXPECT(fr_can_modify(f), "can modify a file with one link");
        snprintf(f2, sizeof f2, "%s/hardlink.txt", tmp);
        EXPECT(link(f, f2) == 0, "made a hard link");
        EXPECT(!fr_can_modify(f) && !fr_can_modify(f2), "can't modify a hard-linked file (either name)");
        EXPECT(fr_can_remove(f2), "can still remove one name of a hard-linked file");
        unlink(f2); unlink(f); unlink(g); rmdir(sub); rmdir(tree); rmdir(tmp);
    } else EXPECT(0, "mkdtemp");

    // canonicalisation through real symlinks (/etc -> private/etc on both macOS and iOS)
    char *c = fr_canonical_follow("/etc/hosts");
    EXPECT(c && strcmp(c, "/private/etc/hosts") == 0, "follow /etc/hosts -> /private/etc/hosts");
    free(c);
    c = fr_canonical_nofollow("/etc");
    EXPECT(c && strcmp(c, "/etc") == 0, "nofollow /etc stays /etc (the link itself)");
    free(c);
    c = fr_canonical_nofollow("/private/var/../../System/x");
    EXPECT(c && strcmp(c, "/System/x") == 0, "/private/var/../../System/x canonicalises into /System/x");
    free(c);
    EXPECT(!fr_can_modify("/etc/hosts"), "can't modify /etc/hosts via the /etc symlink");
    EXPECT(!fr_can_create_in("/etc"), "can't create in /etc (symlink to /private/etc)");
    EXPECT(!fr_can_create_in("/private/var/../../usr"), "can't create in /private/var/../../usr");
    EXPECT(!fr_can_create_in("/var/../usr"), "can't create in nonexistent /var/../usr (= /private/usr)");
    EXPECT(!fr_can_create_in("/"), "can't create in /");
    EXPECT(!fr_can_remove("/var"), "can't remove the /var symlink (structural)");
    EXPECT(!fr_can_remove("/tmp"), "can't remove /tmp");
    EXPECT(fr_can_create_in("/tmp"), "can create in /tmp");
    EXPECT(!fr_can_remove("/nonexistent-dir/x"), "unresolvable parent is denied");
    EXPECT(!fr_can_remove("relative/path"), "relative path is denied");

#if defined(__APPLE__) && defined(__arm64__) && !defined(__MAC_OS_X_VERSION_MIN_REQUIRED)
    // On the iPad, against the real layout and the fixtures in /var/mobile/Documents/FilesRootTest
    // (system-link -> /System, usrbin-link -> /usr/bin).
    const char *T = "/var/mobile/Documents/FilesRootTest";
    char b[512];
    EXPECT(fr_can_create_in(T), "can create in the test folder (via /var symlink)");
    snprintf(b, sizeof b, "%s/hello.txt", T);        EXPECT(fr_can_remove(b), "can remove a test file");
    EXPECT(fr_can_modify(b), "can modify a test file");
    snprintf(b, sizeof b, "%s/system-link", T);      EXPECT(!fr_can_create_in(b), "can't create through a link to /System");
    EXPECT(fr_can_remove(b), "can remove the link itself (target untouched)");
    snprintf(b, sizeof b, "%s/system-link/Library", T); EXPECT(!fr_can_remove(b), "can't remove /System/Library through a link");
    snprintf(b, sizeof b, "%s/usrbin-link", T);      EXPECT(!fr_can_create_in(b), "can't create through a link to /usr/bin");
    snprintf(b, sizeof b, "%s/usrbin-link/ls", T);   EXPECT(!fr_can_modify(b), "can't modify /usr/bin/ls through a link");
    EXPECT(!fr_can_remove("/var/mobile/Library"), "can't remove /var/mobile/Library");
    EXPECT(!fr_can_remove("/var/mobile/Documents"), "can't remove /var/mobile/Documents");
    EXPECT(!fr_can_remove("/var/mobile/Library/Preferences/com.apple.springboard.plist"), "can't remove SpringBoard prefs");
    EXPECT(!fr_can_create_in("/Applications"), "can't create in /Applications");
    EXPECT(!fr_can_create_in("/usr/lib"), "can't create in /usr/lib");
    EXPECT(!fr_can_create_in("/etc/apt"), "can't create in /etc/apt");
    EXPECT(!fr_can_create_in("/var/lib/dpkg"), "can't create in /var/lib/dpkg");
    EXPECT(!fr_can_remove("/.installed_odyssey"), "can't remove /.installed_odyssey");
    EXPECT(!fr_can_remove("/.procursus_strapped"), "can't remove /.procursus_strapped");
    EXPECT(!fr_can_modify("/var/containers/Bundle/Application"), "can't touch app bundles");
    EXPECT(!fr_can_create_in("/var"), "can't create in /var");
    EXPECT(!fr_can_remove("/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000"), "can't remove an app data container");

    // Every real File Provider Storage folder (On My iPad's top level, FilesRoot's, Photos'), via /var.
    glob_t gl;
    int n = 0;
    if (glob("/var/mobile/Containers/Shared/AppGroup/*/File Provider Storage", 0, NULL, &gl) == 0) {
        for (size_t i = 0; i < gl.gl_pathc; i++, n++) {
            char m[400];
            snprintf(m, sizeof m, "can't create in / remove %s", gl.gl_pathv[i]);
            EXPECT(!fr_can_create_in(gl.gl_pathv[i]) && !fr_can_remove(gl.gl_pathv[i]), m);
            char tree[400];
            snprintf(tree, sizeof tree, "%s/tree", gl.gl_pathv[i]);
            struct stat st;
            if (stat(tree, &st) == 0) {                 // FilesRoot's own storage
                fr_set_own_storage(tree);
                EXPECT(!fr_can_create_in(tree) && !fr_can_remove(tree), "can't create in / remove FilesRoot's real tree");
                fr_set_own_storage(NULL);
            }
        }
        globfree(&gl);
    }
    EXPECT(n >= 2, "found the real File Provider Storage folders");
#endif

    printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
    return fails ? 1 : 0;
}
