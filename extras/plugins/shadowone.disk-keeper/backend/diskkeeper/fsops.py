"""Filesystem primitives that never follow symlinks below $HOME.

Every permanent delete goes through delete_entry(): the parent directory is
opened one component at a time with O_NOFOLLOW starting from $HOME, the
target is renamed to a tombstone in the same directory (so tools like yay or
pnpm never see a half-deleted folder), and the tombstone is removed with
shutil.rmtree(dir_fd=...), which is symlink-attack safe.
"""

import contextlib
import os
import shutil
import stat
import subprocess

from . import paths

TOMBSTONE_MARK = ".diskkeeper-del-"
_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Unsafe(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def display_name(name):
    """A printable form of a filename that may not be valid UTF-8."""
    return name.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def round_trips(name):
    """False when QML would turn the name back into a different path."""
    try:
        name.encode("utf-8")
        return True
    except UnicodeEncodeError:
        return False


def home_rel(abs_path):
    """Path relative to $HOME, or raise Unsafe if it is not strictly below it."""
    h = os.path.normpath(paths.home())
    p = os.path.normpath(abs_path)
    if p == h or not p.startswith(h + "/"):
        raise Unsafe("outside-home", paths.contract(abs_path))
    return p[len(h) + 1:]


def valid_rel(rel, single=False):
    """A relative key coming from the UI: no absolute paths, '..', NUL or empty parts."""
    if not isinstance(rel, str) or not rel or "\x00" in rel or rel.startswith("/"):
        return False
    if os.path.normpath(rel) != rel:
        return False
    parts = rel.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return not (single and len(parts) != 1)


@contextlib.contextmanager
def open_parent(abs_path):
    """Yield (dir_fd, name) for abs_path's parent, walked from $HOME without symlinks."""
    rel = home_rel(abs_path)
    parts = rel.split("/")
    fd = os.open(paths.home(), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in parts[:-1]:
            try:
                nfd = os.open(part, _DIR_FLAGS, dir_fd=fd)
            except OSError as exc:
                raise Unsafe("symlink-or-missing", "%s (%s)" % (part, exc.strerror)) from None
            os.close(fd)
            fd = nfd
        yield fd, parts[-1]
    finally:
        os.close(fd)


def lstat(abs_path):
    try:
        with open_parent(abs_path) as (fd, name):
            return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except (OSError, Unsafe):
        return None


def identity(st):
    return [st.st_dev, st.st_ino] if st else None


def _make_writable(parent_fd, name):
    """Give the owner rwx on every directory in the tree so rmtree can empty it.

    AUR build trees often contain 0555 directories.
    """
    st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid():
        os.chmod(name, stat.S_IMODE(st.st_mode) | 0o700, dir_fd=parent_fd)
    for _root, dirs, _files, rootfd in os.fwalk(name, dir_fd=parent_fd, topdown=True):
        for d in dirs:
            with contextlib.suppress(OSError):
                dst = os.stat(d, dir_fd=rootfd, follow_symlinks=False)
                if stat.S_ISDIR(dst.st_mode) and dst.st_uid == os.getuid() and (dst.st_mode & 0o700) != 0o700:
                    os.chmod(d, stat.S_IMODE(dst.st_mode) | 0o700, dir_fd=rootfd)


def _remove_tombstone(parent_fd, tomb, is_dir):
    if not is_dir:
        os.unlink(tomb, dir_fd=parent_fd)
        return
    try:
        shutil.rmtree(tomb, dir_fd=parent_fd)
    except PermissionError:
        _make_writable(parent_fd, tomb)
        shutil.rmtree(tomb, dir_fd=parent_fd)


def delete_entry(abs_path, job, expect=None, dry_run=False):
    """Permanently remove one file, symlink or directory tree below $HOME.

    expect: [st_dev, st_ino] recorded at scan time; a mismatch means the
    entry was replaced since and is skipped.
    """
    with open_parent(abs_path) as (fd, name):
        try:
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            raise Unsafe("gone") from None
        if expect and identity(st) != list(expect):
            raise Unsafe("changed-since-scan")
        parent_dev = os.fstat(fd).st_dev
        is_dir = stat.S_ISDIR(st.st_mode)
        if is_dir and st.st_dev != parent_dev:
            raise Unsafe("other-filesystem")
        if dry_run:
            return
        tomb = ".%s%s%s" % (name[:80], TOMBSTONE_MARK, job)
        os.rename(name, tomb, src_dir_fd=fd, dst_dir_fd=fd)
        _remove_tombstone(fd, tomb, is_dir)


def sweep_tombstones(abs_dir):
    """Finish deletes that an earlier, interrupted job left behind in abs_dir."""
    removed = 0
    try:
        with open_parent(os.path.join(abs_dir, "x")) as (fd, _):
            for entry in os.scandir(fd):
                if TOMBSTONE_MARK in entry.name and entry.name.startswith("."):
                    with contextlib.suppress(OSError):
                        st = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                        _remove_tombstone(fd, entry.name, stat.S_ISDIR(st.st_mode))
                        removed += 1
    except (OSError, Unsafe):
        pass
    return removed


def list_children(abs_dir):
    """Entries of abs_dir as (name, lstat) without following symlinks; [] if unreadable."""
    out = []
    try:
        with open_parent(os.path.join(abs_dir, "x")) as (fd, _):
            for entry in os.scandir(fd):
                if TOMBSTONE_MARK in entry.name:
                    continue
                with contextlib.suppress(OSError):
                    out.append((entry.name, os.stat(entry.name, dir_fd=fd, follow_symlinks=False)))
    except (OSError, Unsafe):
        pass
    return out


def du(abs_paths, timeout=120):
    """Allocated bytes per path via `du -sxB1`, one process for all paths.

    du counts a hardlinked file once per invocation, which matches what
    deleting all of the given paths together would free.
    """
    paths_list = [p for p in abs_paths if p]
    if not paths_list:
        return {}
    try:
        proc = subprocess.run(
            ["du", "-s", "-x", "-B1", "--"] + paths_list,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    sizes = {}
    for line in proc.stdout.split(b"\n"):
        if b"\t" not in line:
            continue
        size, _, path = line.partition(b"\t")
        with contextlib.suppress(ValueError):
            sizes[os.fsdecode(path)] = int(size)
    return sizes


def du_children(abs_dir, timeout=180):
    """Sizes of the direct children of abs_dir (files and dirs), one du process."""
    try:
        proc = subprocess.run(
            ["du", "-a", "-x", "-B1", "-d1", "--", abs_dir],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    sizes = {}
    base = os.fsencode(abs_dir.rstrip("/")) + b"/"
    for line in proc.stdout.split(b"\n"):
        size, _, path = line.partition(b"\t")
        if path.startswith(base):
            with contextlib.suppress(ValueError):
                sizes[os.fsdecode(path[len(base):])] = int(size)
    return sizes


def btrfs_exclusive(abs_paths, timeout=300):
    """Exclusive bytes per path from `btrfs filesystem du` (reflink aware)."""
    if not abs_paths:
        return {}
    try:
        proc = subprocess.run(
            ["btrfs", "filesystem", "du", "-s", "--raw", "--"] + list(abs_paths),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    for line in proc.stdout.split(b"\n")[1:]:
        fields = line.split(None, 3)
        if len(fields) == 4:
            with contextlib.suppress(ValueError):
                out[os.fsdecode(fields[3])] = int(fields[1])
    return out


def newest_mtime(abs_path, limit=20000):
    """Newest max(mtime, ctime) in a tree, walking at most `limit` entries."""
    st = lstat(abs_path)
    if st is None:
        return 0
    newest = max(st.st_mtime, st.st_ctime)
    if not stat.S_ISDIR(st.st_mode):
        return newest
    seen = 0
    for root, dirs, files in os.walk(abs_path, followlinks=False):
        for name in dirs + files:
            seen += 1
            if seen > limit:
                return newest
            with contextlib.suppress(OSError):
                s = os.lstat(os.path.join(root, name))
                newest = max(newest, s.st_mtime, s.st_ctime)
    return newest
