#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && pwd -P)"
readonly SCRIPT_DIRECTORY
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/.." && pwd -P)"
readonly ROOT

fail() {
  printf 'distribution cleanup refused: %s\n' "$1" >&2
  exit 1
}

git_root="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" ||
  fail 'the script is not inside a Git worktree'
git_root="$(CDPATH= cd -P -- "$git_root" && pwd -P)"
[[ "$git_root" == "$ROOT" ]] ||
  fail 'the script directory does not match the Git worktree root'

# Keep this list narrow. These are repository-local generated roots, not
# general cache or source locations. Future release output classes must be
# explicitly reviewed before they are added here.
readonly ALLOWED_BUILD='build'
readonly ALLOWED_DIST='dist'
readonly ALLOWED_RELEASE_WORK='.release-work'
readonly ALLOWED_TOOL_BIN='Tools/bin'

requested_roots=()
if [[ "$#" -eq 0 ]]; then
  requested_roots=(
    "$ALLOWED_BUILD"
    "$ALLOWED_DIST"
    "$ALLOWED_RELEASE_WORK"
    "$ALLOWED_TOOL_BIN"
  )
else
  requested_roots=("$@")
fi

relative_roots=()

for requested_root in "${requested_roots[@]}"; do
  [[ -n "$requested_root" ]] || fail 'an empty cleanup path is not allowed'

  case "/$requested_root/" in
    *'/../'*) fail 'parent traversal (..) is not allowed' ;;
  esac

  # A trailing slash does not change which exact allowlisted root was named.
  while [[ "$requested_root" == */ && "$requested_root" != '/' ]]; do
    requested_root="${requested_root%/}"
  done

  case "$requested_root" in
    "$ROOT"/*)
      relative_root="${requested_root#"$ROOT"/}"
      ;;
    /*)
      fail 'cleanup paths outside the worktree are not allowed'
      ;;
    *)
      relative_root="$requested_root"
      ;;
  esac

  case "$relative_root" in
    "$ALLOWED_BUILD"|"$ALLOWED_DIST"|"$ALLOWED_RELEASE_WORK"|"$ALLOWED_TOOL_BIN") ;;
    *) fail "path is not an enumerated generated root: $relative_root" ;;
  esac

  absolute_root="$ROOT/$relative_root"
  current_path="$ROOT"
  remaining="$relative_root"
  while :; do
    component="${remaining%%/*}"
    current_path="$current_path/$component"

    [[ ! -L "$current_path" ]] ||
      fail "symlink cleanup roots are not allowed: $relative_root"

    if [[ "$remaining" == */* ]]; then
      if [[ -e "$current_path" && ! -d "$current_path" ]]; then
        fail "cleanup root has a non-directory parent: $relative_root"
      fi
      remaining="${remaining#*/}"
    else
      break
    fi
  done

  if [[ -e "$absolute_root" && ! -d "$absolute_root" ]]; then
    fail "cleanup root is not a directory: $relative_root"
  fi

  relative_roots+=("$relative_root")
done

# The shell checks above keep diagnostics simple, but path-string validation is
# not a security boundary: another process could replace a checked parent or
# leaf before rm opens it. Pin the absolute Git root and every existing path
# component with openat(2), O_DIRECTORY, and O_NOFOLLOW. The Python process gets
# a clean environment so production behavior cannot be changed by inherited
# Python or cleanup variables. The one explicit hook argument is inert unless
# the pinned worktree is a strictly marked fixture under /private/tmp.
readonly TEST_HOOK_REQUEST="${UTTERINK_CLEAN_TEST_HOOK_DIR-}"
/usr/bin/env -i PATH='/usr/bin:/bin' \
  /usr/bin/python3 -I - "$ROOT" "$TEST_HOOK_REQUEST" "${relative_roots[@]}" <<'PY'
import ctypes
import errno
import os
import re
import secrets
import stat
import sys
import time


class Refusal(Exception):
    pass


def refuse(message):
    raise Refusal(message)


def identity(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode))


owned_fds = []


def remember(fd):
    owned_fds.append(fd)
    return fd


def close_remembered(fd):
    try:
        os.close(fd)
    finally:
        try:
            owned_fds.remove(fd)
        except ValueError:
            pass


OPEN_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
if hasattr(os, "O_CLOEXEC"):
    OPEN_DIRECTORY_FLAGS |= os.O_CLOEXEC

OPEN_FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW
if hasattr(os, "O_CLOEXEC"):
    OPEN_FILE_FLAGS |= os.O_CLOEXEC


def lstat_at(parent_fd, name):
    return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)


def open_checked_directory(parent_fd, name, label):
    try:
        before = lstat_at(parent_fd, name)
    except FileNotFoundError:
        raise
    if stat.S_ISLNK(before.st_mode):
        refuse("symlink cleanup roots are not allowed: %s" % label)
    if not stat.S_ISDIR(before.st_mode):
        refuse("cleanup root has a non-directory parent: %s" % label)
    try:
        child_fd = remember(os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd))
    except OSError:
        refuse("cleanup path changed while it was being fixed: %s" % label)
    if identity(before) != identity(os.fstat(child_fd)):
        refuse("cleanup path changed while it was being fixed: %s" % label)
    return child_fd


def open_absolute_directory(path):
    if not path.startswith("/"):
        refuse("the Git worktree root is not absolute")

    current_fd = remember(os.open("/", OPEN_DIRECTORY_FLAGS))
    links = []
    for component in [part for part in path.split("/") if part]:
        try:
            before = lstat_at(current_fd, component)
        except OSError:
            refuse("the Git worktree root changed during cleanup")
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
            refuse("the Git worktree root contains an unsafe path component")
        try:
            child_fd = remember(
                os.open(component, OPEN_DIRECTORY_FLAGS, dir_fd=current_fd)
            )
        except OSError:
            refuse("the Git worktree root changed during cleanup")
        if identity(before) != identity(os.fstat(child_fd)):
            refuse("the Git worktree root changed during cleanup")
        links.append((current_fd, component, child_fd))
        current_fd = child_fd
    return current_fd, links


def verify_link(parent_fd, name, child_fd, label):
    try:
        current = lstat_at(parent_fd, name)
    except OSError:
        refuse("cleanup path changed after validation: %s" % label)
    if identity(current) != identity(os.fstat(child_fd)):
        refuse("cleanup path changed after validation: %s" % label)


def read_small_regular(parent_fd, name, expected, label):
    fd = None
    try:
        before = lstat_at(parent_fd, name)
        if not stat.S_ISREG(before.st_mode):
            return False
        fd = remember(os.open(name, OPEN_FILE_FLAGS, dir_fd=parent_fd))
        after = os.fstat(fd)
        if identity(before) != identity(after) or after.st_size != len(expected):
            return False
        payload = os.read(fd, len(expected) + 1)
        return payload == expected
    except OSError:
        return False
    finally:
        if fd is not None:
            close_remembered(fd)


def open_test_hook(root_path, root_fd, requested_hook):
    # An inherited variable has no effect in a normal checkout. A test hook is
    # recognized only for a two-level fixture created below /private/tmp with
    # private permissions and two exact marker files.
    if not requested_hook:
        return None
    if not re.fullmatch(
        r"/private/tmp/utterink-clean-output-tests\.[A-Za-z0-9]+/[^/]+",
        root_path,
    ):
        return None
    expected_hook = root_path + "/.clean-distribution-output-test-hook"
    if requested_hook != expected_hook:
        return None
    if not read_small_regular(
        root_fd,
        ".utterink-cleanup-test-fixture",
        b"fixture-v1\n",
        "test fixture marker",
    ):
        return None
    try:
        hook_fd = open_checked_directory(
            root_fd,
            ".clean-distribution-output-test-hook",
            "test fixture hook",
        )
    except (FileNotFoundError, Refusal):
        return None
    hook_stat = os.fstat(hook_fd)
    if hook_stat.st_uid != os.getuid() or stat.S_IMODE(hook_stat.st_mode) & 0o077:
        return None
    if not read_small_regular(
        hook_fd,
        ".utterink-cleanup-race-fixture",
        b"race-v1\n",
        "test hook marker",
    ):
        return None
    phase = "before-mutation"
    for candidate in ("after-rename", "after-first-absence", "before-mutation"):
        if read_small_regular(
            hook_fd,
            "phase",
            (candidate + "\n").encode("ascii"),
            "test hook phase",
        ):
            phase = candidate
            break
    return hook_fd, phase


def run_test_hook(hook_fd):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    ready_fd = remember(os.open("ready", flags, 0o600, dir_fd=hook_fd))
    try:
        os.write(ready_fd, b"ready\n")
    finally:
        close_remembered(ready_fd)

    deadline = time.monotonic() + 15.0
    while time.monotonic() < deadline:
        if read_small_regular(hook_fd, "continue", b"continue\n", "test hook"):
            return
        time.sleep(0.01)
    refuse("test-only cleanup race hook timed out")


def verify_requested_path_absent(root_fd, root_links, relative):
    for parent_fd, name, child_fd in root_links:
        verify_link(parent_fd, name, child_fd, relative)
    root_device = os.fstat(root_fd).st_dev
    current_fd = root_fd
    opened = []
    try:
        components = relative.split("/")
        for index, component in enumerate(components):
            try:
                before = lstat_at(current_fd, component)
            except FileNotFoundError:
                return
            except OSError:
                refuse("generated root absence could not be verified: %s" % relative)
            if index == len(components) - 1:
                refuse("generated root was recreated during cleanup: %s" % relative)
            if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
                refuse("generated root path became unsafe during cleanup: %s" % relative)
            try:
                child_fd = remember(
                    os.open(component, OPEN_DIRECTORY_FLAGS, dir_fd=current_fd)
                )
            except OSError:
                refuse("generated root path changed during final verification: %s" % relative)
            opened.append(child_fd)
            after = os.fstat(child_fd)
            if identity(before) != identity(after) or after.st_dev != root_device:
                refuse("generated root path changed during final verification: %s" % relative)
            current_fd = child_fd
    finally:
        for descriptor in reversed(opened):
            close_remembered(descriptor)


class Target:
    def __init__(self, relative, parent_fd, parent_links, leaf, target_fd):
        self.relative = relative
        self.parent_fd = parent_fd
        self.parent_links = parent_links
        self.leaf = leaf
        self.target_fd = target_fd


def validate_target(root_fd, relative):
    components = relative.split("/")
    parent_fd = root_fd
    parent_links = []

    for component in components[:-1]:
        try:
            child_fd = open_checked_directory(parent_fd, component, relative)
        except FileNotFoundError:
            return Target(relative, parent_fd, parent_links, components[-1], None)
        parent_links.append((parent_fd, component, child_fd))
        parent_fd = child_fd

    leaf = components[-1]
    try:
        before = lstat_at(parent_fd, leaf)
    except FileNotFoundError:
        return Target(relative, parent_fd, parent_links, leaf, None)
    if stat.S_ISLNK(before.st_mode):
        refuse("symlink cleanup roots are not allowed: %s" % relative)
    if not stat.S_ISDIR(before.st_mode):
        refuse("cleanup root is not a directory: %s" % relative)
    try:
        target_fd = remember(os.open(leaf, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd))
    except OSError:
        refuse("cleanup root changed while it was being fixed: %s" % relative)
    if identity(before) != identity(os.fstat(target_fd)):
        refuse("cleanup root changed while it was being fixed: %s" % relative)
    return Target(relative, parent_fd, parent_links, leaf, target_fd)


libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = libc.renameatx_np
renameatx_np.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
]
renameatx_np.restype = ctypes.c_int
RENAME_EXCL = 0x00000004


def exclusive_rename(parent_fd, source, destination):
    result = renameatx_np(
        parent_fd,
        os.fsencode(source),
        parent_fd,
        os.fsencode(destination),
        RENAME_EXCL,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def move_to_tombstone(target):
    for _ in range(32):
        tombstone = ".utterink-cleanup-%d-%s" % (os.getpid(), secrets.token_hex(12))
        try:
            exclusive_rename(target.parent_fd, target.leaf, tombstone)
            return tombstone
        except OSError as error:
            if error.errno == errno.EEXIST:
                continue
            refuse("generated root changed before removal: %s" % target.relative)
    refuse("could not allocate a private cleanup tombstone: %s" % target.relative)


def remove_tree_fd(directory_fd, label, expected_device):
    # Every recursive descent is relative to an already pinned directory fd.
    # unlinkat never follows a symlink; rmdir refuses one if an entry is swapped.
    if os.fstat(directory_fd).st_dev != expected_device:
        refuse("generated contents cross a filesystem boundary: %s" % label)
    for name in os.listdir(directory_fd):
        if name in (".", ".."):
            refuse("invalid directory entry during cleanup: %s" % label)
        try:
            before = lstat_at(directory_fd, name)
        except OSError:
            refuse("generated contents changed during cleanup: %s" % label)
        if before.st_dev != expected_device:
            refuse("generated contents cross a filesystem boundary: %s" % label)
        if stat.S_ISDIR(before.st_mode):
            try:
                child_fd = remember(
                    os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=directory_fd)
                )
            except OSError:
                refuse("generated contents changed during cleanup: %s" % label)
            try:
                child_stat = os.fstat(child_fd)
                if child_stat.st_dev != expected_device:
                    refuse(
                        "generated contents cross a filesystem boundary: %s" % label
                    )
                if identity(before) != identity(child_stat):
                    refuse("generated contents changed during cleanup: %s" % label)
                remove_tree_fd(child_fd, label, expected_device)
                current = lstat_at(directory_fd, name)
                if identity(current) != identity(os.fstat(child_fd)):
                    refuse("generated contents changed during cleanup: %s" % label)
                os.rmdir(name, dir_fd=directory_fd)
            except Refusal:
                raise
            except OSError:
                refuse("generated contents changed during cleanup: %s" % label)
            finally:
                close_remembered(child_fd)
        else:
            try:
                os.unlink(name, dir_fd=directory_fd)
            except OSError:
                refuse("generated contents changed during cleanup: %s" % label)


def main():
    if len(sys.argv) < 4:
        refuse("internal cleanup invocation is incomplete")
    root_path = sys.argv[1]
    hook_request = sys.argv[2]

    allowed = {"build", "dist", ".release-work", "Tools/bin"}
    relative_roots = []
    for relative in sys.argv[3:]:
        if relative not in allowed:
            refuse("path is not an enumerated generated root: %s" % relative)
        if relative not in relative_roots:
            relative_roots.append(relative)

    root_fd, root_links = open_absolute_directory(root_path)
    targets = [validate_target(root_fd, relative) for relative in relative_roots]
    # Validation of every requested root is complete before the first mutation.

    hook = open_test_hook(root_path, root_fd, hook_request)
    hook_used = False
    if hook is not None and hook[1] == "before-mutation":
        run_test_hook(hook[0])
        hook_used = True

    for target in targets:
        if target.target_fd is None:
            continue
        for parent_fd, name, child_fd in root_links:
            verify_link(parent_fd, name, child_fd, target.relative)
        for parent_fd, name, child_fd in target.parent_links:
            verify_link(parent_fd, name, child_fd, target.relative)
        verify_link(target.parent_fd, target.leaf, target.target_fd, target.relative)

        tombstone = move_to_tombstone(target)
        try:
            moved = lstat_at(target.parent_fd, tombstone)
        except OSError:
            refuse("generated root changed during removal: %s" % target.relative)
        if identity(moved) != identity(os.fstat(target.target_fd)):
            refuse("generated root changed during removal: %s" % target.relative)

        if hook is not None and hook[1] == "after-rename" and not hook_used:
            run_test_hook(hook[0])
            hook_used = True

        target_device = os.fstat(target.target_fd).st_dev
        remove_tree_fd(target.target_fd, target.relative, target_device)
        try:
            moved = lstat_at(target.parent_fd, tombstone)
            if identity(moved) != identity(os.fstat(target.target_fd)):
                refuse("generated root changed during removal: %s" % target.relative)
            os.rmdir(tombstone, dir_fd=target.parent_fd)
        except Refusal:
            raise
        except OSError:
            refuse("generated root could not be removed: %s" % target.relative)

    for relative in relative_roots:
        verify_requested_path_absent(root_fd, root_links, relative)

    if hook is not None and hook[1] == "after-first-absence" and not hook_used:
        run_test_hook(hook[0])
        hook_used = True

    # Recheck after the synchronization boundary so a leaf created immediately
    # after the first ENOENT observation cannot turn cleanup into a false success.
    for relative in relative_roots:
        verify_requested_path_absent(root_fd, root_links, relative)


try:
    main()
except Refusal as error:
    print("distribution cleanup refused: %s" % error, file=sys.stderr)
    sys.exit(1)
except OSError:
    print("distribution cleanup refused: cleanup failed safely", file=sys.stderr)
    sys.exit(1)
finally:
    for fd in reversed(owned_fds):
        try:
            os.close(fd)
        except OSError:
            pass
PY
