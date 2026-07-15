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
absolute_roots=()

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
  absolute_roots+=("$absolute_root")
done
# Validation of every request is complete before the first mutation.
for index in "${!absolute_roots[@]}"; do
  absolute_root="${absolute_roots[$index]}"
  relative_root="${relative_roots[$index]}"
  if [[ -d "$absolute_root" ]]; then
    /bin/rm -rf -- "$absolute_root"
    [[ ! -e "$absolute_root" && ! -L "$absolute_root" ]] ||
      fail "generated root could not be removed: $relative_root"
  fi
done
