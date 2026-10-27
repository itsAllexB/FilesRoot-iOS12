// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesRoot write policy. Pure C so it can be unit-tested on the Mac (tests/policy_test.c).
//
// Every write operation is checked twice: the item's capabilities never offer a blocked action in Files,
// and the extension re-checks here before touching the disk. On top of that the extension runs as the
// unprivileged `mobile` user, so the kernel refuses writes to root-owned paths anyway.
//
// Paths are canonicalised before checking (symlinks resolved), so /var/../System, /etc -> /private/etc
// or a symlink pointing into /usr can't be used to get around the list.

#ifndef FRPOLICY_H
#define FRPOLICY_H

#ifdef __cplusplus
extern "C" {
#endif

// realpath() of the parent folder + the last component (the item itself is NOT followed).
// Returns a malloc'd string or NULL when the parent folder can't be resolved.
char *fr_canonical_nofollow(const char *path);
// realpath() of the whole path when it exists, otherwise fr_canonical_nofollow().
char *fr_canonical_follow(const char *path);

// The extension's own storage folder (<documentStorageURL>/tree). It is protected like a system folder:
// Files keeps its copies there. Any path form is accepted; it is canonicalised. NULL clears it.
void fr_set_own_storage(const char *path);

// 1 when the canonical path is, or is inside, a protected system location (never writable).
int fr_is_protected(const char *canon);
// 1 when the canonical path is a fixed part of the filesystem layout (e.g. /private/var/mobile/Library, a
// direct child of /private/var/mobile/Containers/Data/Application, or an app group's "File Provider Storage")
// that may never be deleted, renamed or moved.
int fr_is_structural(const char *canon);
// 1 when nothing may be created directly inside the canonical folder. Covers every app group's
// "File Provider Storage": items made there (the top level of On My iPad) can't be deleted from Files again.
int fr_is_no_new_items(const char *canon);

// High-level checks, on logical paths as Files sees them. Return 1 = allowed.
int fr_can_create_in(const char *dir);     // new files / folders / imports inside dir
int fr_can_modify(const char *file);       // overwrite an existing file's contents (never hard-linked files)
int fr_can_remove(const char *path);       // delete, rename or move the item itself

#ifdef __cplusplus
}
#endif
#endif
