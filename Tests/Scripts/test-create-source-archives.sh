#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT/Scripts/release/create-source-archives.sh"

fail() {
  printf 'source archive tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$SCRIPT" ]] || fail 'archive script is missing'
[[ -x "$SCRIPT" ]] || fail 'archive script is not executable'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-source-archives-test.XXXXXX")"
ACTIVE_ARCHIVER_PID=''
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$ACTIVE_ARCHIVER_PID" ]]; then
    kill -CONT "$ACTIVE_ARCHIVER_PID" 2>/dev/null || true
    kill -TERM "$ACTIVE_ARCHIVER_PID" 2>/dev/null || true
    wait "$ACTIVE_ARCHIVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT

MAIN_TAG_BEFORE="$(git -C "$ROOT" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)"

write_fixture() {
  local repository="$1"
  local configured_name="$2"
  local configured_email="$3"
  mkdir -p "$repository"
  /usr/bin/python3 -I - "$repository" "$SCRIPT" <<'PY'
from __future__ import annotations

from pathlib import Path
import shutil
import sys


root = Path(sys.argv[1])
source_script = Path(sys.argv[2])


def write(relative: str, content: str, mode: int = 0o644) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


(root / "Scripts/release").mkdir(parents=True, exist_ok=True)
shutil.copyfile(source_script, root / "Scripts/release/create-source-archives.sh")
(root / "Scripts/release/create-source-archives.sh").chmod(0o755)

write(
    "Scripts/release/verify-candidate.sh",
    r'''#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u FIXTURE_VERIFY_ENV_CLEAN /bin/bash -p
set +x +v
if [[ "$-" != *p* ]]; then
  /usr/bin/printf 'fixture verifier error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${FIXTURE_VERIFY_ENV_CLEAN:-}" != 1 ]]; then
  exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C FIXTURE_VERIFY_ENV_CLEAN=1 /bin/bash -p "$0" "$@"
  exit 2
fi
unset FIXTURE_VERIFY_ENV_CLEAN
set -euo pipefail
commit=''
output=''
output_dir_fd=''
expected_origin=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --commit) commit="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --output-dir-fd) output_dir_fd="$2"; shift 2 ;;
    --expected-origin) expected_origin="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ "$commit" =~ ^[0-9a-f]{40}$ && -n "$output" && "$output_dir_fd" =~ ^[0-9]+$ ]] || exit 2
root="$(/usr/bin/git rev-parse --show-toplevel)"
tree="$(/usr/bin/git rev-parse "$commit^{tree}")"
/bin/mkdir -p "$root/.release-work"
if [[ -n "$expected_origin" ]]; then
  /usr/bin/printf '%s\n' "$expected_origin" > "$root/.release-work/forwarded-origin"
fi
if [[ -e "$root/.git/archive-test-pause" ]]; then
  /usr/bin/touch "$root/.git/archive-test-ready"
  while [[ -e "$root/.git/archive-test-pause" ]]; do
    /bin/sleep 0.01
  done
fi
/usr/bin/python3 -I - "$output_dir_fd" "$commit" "$tree" <<'PY_INNER'
import os
import json
import sys

directory_fd = int(sys.argv[1])
commit, tree = sys.argv[2:]
value = {
    "checks": {
        "entitlements": True,
        "generatedProjectClean": True,
        "history": True,
        "infoPolicy": True,
        "metadata": True,
        "packageResolution": True,
    },
    "evidenceType": "release-candidate",
    "packageResolution": {"path": "Packages/UtterInkKit/Package.resolved", "sha256": "1" * 64},
    "policies": {
        "ciToolchainSHA256": "2" * 64,
        "releaseEntitlementsSHA256": "3" * 64,
        "releaseInfoPolicySHA256": "4" * 64,
        "releaseMetadataSHA256": "5" * 64,
    },
    "product": "UtterInk",
    "release": {
        "architecture": "arm64",
        "buildNumber": "1",
        "bundleIdentifier": "dev.utterink.UtterInk",
        "configuration": "Release",
        "deploymentTarget": "14.0",
        "dmgFilename": "UtterInk-0.1.0-arm64.dmg",
        "marketingVersion": "0.1.0",
    },
    "schemaVersion": 1,
    "source": {"clean": True, "commit": commit, "releaseTag": "v0.1.0", "tree": tree},
    "toolchain": {
        "lockSHA256": "6" * 64,
        "sdkBuild": "25E246",
        "sdkVersion": "26.4",
        "swiftVersion": "Apple Swift version 6.3 (swiftlang-fixture clang-fixture)",
        "xcodeBuild": "17E202",
        "xcodeVersion": "26.4.1",
        "xcodegenBinarySHA256": "7" * 64,
        "xcodegenVersion": "2.45.4",
    },
}
content = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
descriptor = os.open(
    "candidate.json",
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
    0o644,
    dir_fd=directory_fd,
)
try:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise SystemExit(1)
        view = view[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY_INNER
''',
    0o755,
)
write(
    "Config/release-metadata.json",
    '''{
  "schemaVersion": 1,
  "product": "UtterInk",
  "configuration": "Release",
  "dmgFilenameTemplate": "UtterInk-{marketingVersion}-{architecture}.dmg",
  "supportedArchitectures": [
    "arm64"
  ],
  "releaseTag": "v0.1.0"
}
''',
)
write(
    ".gitignore",
    '''.release-work/
.release-approvals/
.release-evidence/
.release-requests/
.notary-profile-bindings/
.notarization-logs/
.env
.env.*
dist/
build/
DerivedData/
*.dmg
*.zip
*.tar.gz
*.p12
private-import-review*
''',
)
write("README.md", "# UtterInk\n\nDeterministic fixture.\n")
write("Sources/main.swift", "print(\"UtterInk\")\n")
write("Scripts/tool.sh", "#!/bin/sh\nprintf 'fixture\\n'\n", 0o755)
write(".github/workflows/ci.yml", "name: CI\n")
PY

  git -C "$repository" init -q
  git -C "$repository" config user.name "$configured_name"
  git -C "$repository" config user.email "$configured_email"
  git -C "$repository" add .
  GIT_AUTHOR_NAME='Archive Fixture' \
    GIT_AUTHOR_EMAIL='archive-fixture@example.invalid' \
    GIT_COMMITTER_NAME='Archive Fixture' \
    GIT_COMMITTER_EMAIL='archive-fixture@example.invalid' \
    GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
  GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
    git -C "$repository" commit -q -m 'fixture source commit'

  printf '%s\n' \
    '#!/bin/sh' \
    '/usr/bin/touch .git/reference-transaction-hook-ran' \
    'exit 0' \
    > "$repository/.git/hooks/reference-transaction"
  chmod 0755 "$repository/.git/hooks/reference-transaction"

  mkdir -p \
    "$repository/.release-approvals" \
    "$repository/.release-evidence" \
    "$repository/.release-requests" \
    "$repository/.notary-profile-bindings" \
    "$repository/.notarization-logs" \
    "$repository/dist" \
    "$repository/build" \
    "$repository/DerivedData"
  printf 'ignored secret\n' > "$repository/.env"
  printf 'ignored approval\n' > "$repository/.release-approvals/local.json"
  printf 'ignored evidence\n' > "$repository/.release-evidence/local.json"
  printf 'ignored request\n' > "$repository/.release-requests/local.json"
  printf 'ignored profile\n' > "$repository/.notary-profile-bindings/local.json"
  printf 'ignored log\n' > "$repository/.notarization-logs/local.log"
  printf 'ignored dist\n' > "$repository/dist/private.txt"
  printf 'ignored build\n' > "$repository/build/private.txt"
  printf 'ignored derived data\n' > "$repository/DerivedData/private.txt"
  printf 'ignored dmg\n' > "$repository/local.dmg"
  printf 'ignored certificate\n' > "$repository/local.p12"
  printf 'ignored review\n' > "$repository/private-import-review-notes.md"
}

run_archiver() {
  local repository="$1"
  local output="$2"
  local locale="$3"
  local timezone="$4"
  local user_name="$5"
  local mask="$6"
  local commit
  commit="$(git -C "$repository" rev-parse HEAD)"
  (
    cd "$repository"
    umask "$mask"
    env \
      LC_ALL="$locale" \
      LANG="$locale" \
      TZ="$timezone" \
      USER="$user_name" \
      LOGNAME="$user_name" \
      ./Scripts/release/create-source-archives.sh \
        --commit "$commit" \
        --output "$output" \
        --expected-origin 'https://example.invalid/utterink.git'
  )
}

start_archiver() {
  local repository="$1"
  local output="$2"
  local log_prefix="$3"
  local commit
  commit="$(git -C "$repository" rev-parse HEAD)"
  (
    cd "$repository"
    exec /usr/bin/env \
      LC_ALL=C \
      LANG=C \
      TZ=UTC \
      USER=race-user \
      LOGNAME=race-user \
      ./Scripts/release/create-source-archives.sh \
        --commit "$commit" \
        --output "$output" \
        --expected-origin 'https://example.invalid/utterink.git'
  ) > "$log_prefix.out" 2> "$log_prefix.err" &
  ACTIVE_ARCHIVER_PID=$!
}

wait_for_path() {
  local path="$1"
  local description="$2"
  local attempt
  for ((attempt = 0; attempt < 4000; attempt++)); do
    if [[ -e "$path" || -L "$path" ]]; then
      return 0
    fi
    if [[ -n "$ACTIVE_ARCHIVER_PID" ]] && ! kill -0 "$ACTIVE_ARCHIVER_PID" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.005
  done
  fail "$description did not appear before the archiver exited"
}

wait_for_archiver_failure() {
  local description="$1"
  local status
  if wait "$ACTIVE_ARCHIVER_PID"; then
    ACTIVE_ARCHIVER_PID=''
    fail "$description unexpectedly succeeded"
  else
    status=$?
  fi
  ACTIVE_ARCHIVER_PID=''
  [[ "$status" -ne 0 ]] || fail "$description returned a zero status"
}

commit_fixture_change() {
  local repository="$1"
  local message="$2"
  local date="$3"
  printf '\n%s\n' "$message" >> "$repository/README.md"
  git -C "$repository" add README.md
  GIT_AUTHOR_NAME='Archive Fixture' \
    GIT_AUTHOR_EMAIL='archive-fixture@example.invalid' \
    GIT_COMMITTER_NAME='Archive Fixture' \
    GIT_COMMITTER_EMAIL='archive-fixture@example.invalid' \
    GIT_AUTHOR_DATE="$date" \
    GIT_COMMITTER_DATE="$date" \
    git -C "$repository" -c core.hooksPath=/dev/null commit -q -m "$message"
}

REPO_A="$TMP/absolute-root-a/UtterInk"
REPO_B="$TMP/a-much-longer-absolute-root-b/checkout/UtterInk"
write_fixture "$REPO_A" 'Local Alice' 'alice@example.invalid'
write_fixture "$REPO_B" 'Local Bob' 'bob@example.invalid'

COMMIT_A="$(git -C "$REPO_A" rev-parse HEAD)"
COMMIT_B="$(git -C "$REPO_B" rev-parse HEAD)"
[[ "$COMMIT_A" == "$COMMIT_B" ]] || fail 'fixture commits differ'

OUT_A="$REPO_A/.release-work/source-a"
OUT_B="$REPO_B/.release-work/nested/source-b"
run_archiver "$REPO_A" "$OUT_A" C 'Pacific/Honolulu' alice 022
run_archiver "$REPO_B" "$OUT_B" POSIX 'Asia/Tokyo' bob 077

for repository in "$REPO_A" "$REPO_B"; do
  [[ "$(git -C "$repository" rev-parse 'v0.1.0^{commit}')" == "$COMMIT_A" ]] || fail 'local release tag is not bound to the commit'
  [[ "$(git -C "$repository" cat-file -t refs/tags/v0.1.0)" == commit ]] || fail 'release tag is not lightweight'
  [[ "$(<"$repository/.release-work/forwarded-origin")" == 'https://example.invalid/utterink.git' ]] || fail 'expected origin was not forwarded'
  [[ ! -e "$repository/.git/reference-transaction-hook-ran" ]] || fail 'tag creation executed a local Git hook'
done

TAR_NAME='UtterInk-0.1.0-source.tar.gz'
ZIP_NAME='UtterInk-0.1.0-source.zip'
for output in "$OUT_A" "$OUT_B"; do
  [[ -d "$output" && ! -L "$output" ]] || fail 'output directory missing or unsafe'
  [[ "$(find "$output" -mindepth 1 -maxdepth 1 -type f -print | wc -l | tr -d ' ')" -eq 2 ]] || fail 'output does not contain exactly two files'
  [[ -f "$output/$TAR_NAME" && ! -L "$output/$TAR_NAME" ]] || fail 'tar archive missing or unsafe'
  [[ -f "$output/$ZIP_NAME" && ! -L "$output/$ZIP_NAME" ]] || fail 'zip archive missing or unsafe'
  [[ "$(stat -f '%Lp:%l' "$output/$TAR_NAME")" == '644:1' ]] || fail 'tar archive mode/link count is unsafe'
  [[ "$(stat -f '%Lp:%l' "$output/$ZIP_NAME")" == '644:1' ]] || fail 'zip archive mode/link count is unsafe'
done

cmp -s "$OUT_A/$TAR_NAME" "$OUT_B/$TAR_NAME" || fail 'tar archives vary by absolute path/user/locale/time zone/umask'
cmp -s "$OUT_A/$ZIP_NAME" "$OUT_B/$ZIP_NAME" || fail 'zip archives vary by absolute path/user/locale/time zone/umask'

/usr/bin/python3 -I - "$OUT_A/$TAR_NAME" "$OUT_A/$ZIP_NAME" <<'PY'
from __future__ import annotations

import hashlib
import io
from pathlib import PurePosixPath
import stat
import sys
import tarfile
import zipfile


expected = {
    ".github/workflows/ci.yml": (0o644, b"name: CI\n"),
    ".gitignore": (0o644, None),
    "Config/release-metadata.json": (0o644, None),
    "README.md": (0o644, b"# UtterInk\n\nDeterministic fixture.\n"),
    "Scripts/release/create-source-archives.sh": (0o755, None),
    "Scripts/release/verify-candidate.sh": (0o755, None),
    "Scripts/tool.sh": (0o755, b"#!/bin/sh\nprintf 'fixture\\n'\n"),
    "Sources/main.swift": (0o644, b'print("UtterInk")\n'),
}
prefix = "UtterInk-0.1.0/"


def safe_name(name: str) -> str:
    if not name.startswith(prefix):
        raise SystemExit("bad-prefix")
    relative = name[len(prefix):].rstrip("/")
    pure = PurePosixPath(relative)
    if not relative or pure.is_absolute() or ".." in pure.parts or "\\" in relative:
        raise SystemExit("unsafe-path")
    return relative


def tar_inventory(path: str) -> dict[str, tuple[int, bytes]]:
    result: dict[str, tuple[int, bytes]] = {}
    with tarfile.open(path, "r:gz") as archive:
        top = [item for item in archive.getmembers() if item.name.rstrip("/") == prefix.rstrip("/")]
        if len(top) != 1 or not top[0].isdir():
            raise SystemExit("bad-top-level")
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile():
                raise SystemExit("non-regular-tar-member")
            relative = safe_name(member.name)
            handle = archive.extractfile(member)
            if handle is None:
                raise SystemExit("unreadable-tar-member")
            result[relative] = (stat.S_IMODE(member.mode), handle.read())
    return result


def zip_inventory(path: str) -> dict[str, tuple[int, bytes]]:
    result: dict[str, tuple[int, bytes]] = {}
    with zipfile.ZipFile(path, "r") as archive:
        names = archive.namelist()
        if names.count(prefix) != 1:
            raise SystemExit("bad-zip-top-level")
        for item in archive.infolist():
            if item.is_dir():
                continue
            relative = safe_name(item.filename)
            mode = stat.S_IMODE(item.external_attr >> 16)
            result[relative] = (mode, archive.read(item))
            if item.date_time != (1980, 1, 1, 0, 0, 0):
                raise SystemExit("non-deterministic-zip-time")
    return result


tar_files = tar_inventory(sys.argv[1])
zip_files = zip_inventory(sys.argv[2])
if tar_files != zip_files or set(tar_files) != set(expected):
    raise SystemExit("archive-inventory-mismatch")
for relative, (expected_mode, expected_content) in expected.items():
    mode, content = tar_files[relative]
    if mode != expected_mode:
        raise SystemExit("archive-mode-mismatch")
    if expected_content is not None and content != expected_content:
        raise SystemExit("archive-content-mismatch")

joined_names = "\n".join(tar_files).lower()
for forbidden in (
    ".git/", ".env", ".release-approvals", ".release-evidence",
    ".release-requests", ".notary-profile-bindings", ".notarization-logs",
    "dist/", "build/", "deriveddata", ".dmg", ".p12", "private-import-review",
):
    if forbidden in joined_names:
        raise SystemExit("forbidden-archive-path")

raw_gzip = open(sys.argv[1], "rb").read(10)
if raw_gzip[:3] != b"\x1f\x8b\x08" or raw_gzip[4:8] != b"\0\0\0\0":
    raise SystemExit("non-deterministic-gzip-header")
PY

SECOND_OUT="$REPO_A/.release-work/source-second"
run_archiver "$REPO_A" "$SECOND_OUT" POSIX UTC second-user 027
cmp -s "$OUT_A/$TAR_NAME" "$SECOND_OUT/$TAR_NAME" || fail 'matching existing tag changed tar output'
cmp -s "$OUT_A/$ZIP_NAME" "$SECOND_OUT/$ZIP_NAME" || fail 'matching existing tag changed zip output'

TAR_HASH_BEFORE="$(shasum -a 256 "$OUT_A/$TAR_NAME" | awk '{print $1}')"
ZIP_HASH_BEFORE="$(shasum -a 256 "$OUT_A/$ZIP_NAME" | awk '{print $1}')"
if run_archiver "$REPO_A" "$OUT_A" C UTC overwrite 022 > "$TMP/overwrite.out" 2> "$TMP/overwrite.err"; then
  fail 'existing output directory was overwritten'
fi
grep -Fq 'source archive error: unsafe-output' "$TMP/overwrite.err" || fail 'existing output did not report unsafe-output'
[[ "$(shasum -a 256 "$OUT_A/$TAR_NAME" | awk '{print $1}')" == "$TAR_HASH_BEFORE" ]] || fail 'failed overwrite changed tar archive'
[[ "$(shasum -a 256 "$OUT_A/$ZIP_NAME" | awk '{print $1}')" == "$ZIP_HASH_BEFORE" ]] || fail 'failed overwrite changed zip archive'

ln -s "$TMP/outside" "$REPO_A/.release-work/output-link"
if run_archiver "$REPO_A" "$REPO_A/.release-work/output-link" C UTC symlink 022 > "$TMP/symlink.out" 2> "$TMP/symlink.err"; then
  fail 'symlink output was accepted'
fi
grep -Fq 'source archive error: unsafe-output' "$TMP/symlink.err" || fail 'symlink output did not report unsafe-output'
rm "$REPO_A/.release-work/output-link"

if run_archiver "$REPO_A" "$TMP/outside-output" C UTC outside 022 > "$TMP/outside.out" 2> "$TMP/outside.err"; then
  fail 'out-of-root output was accepted'
fi
grep -Fq 'source archive error: unsafe-output' "$TMP/outside.err" || fail 'out-of-root output did not report unsafe-output'

printf 'dirty\n' > "$REPO_A/untracked.txt"
if run_archiver "$REPO_A" "$REPO_A/.release-work/dirty" C UTC dirty 022 > "$TMP/dirty.out" 2> "$TMP/dirty.err"; then
  fail 'dirty checkout was accepted'
fi
grep -Fq 'source archive error: dirty-checkout' "$TMP/dirty.err" || fail 'dirty checkout did not report dirty-checkout'
rm "$REPO_A/untracked.txt"

printf 'must never ship\n' > "$REPO_A/.env"
git -C "$REPO_A" add -f .env
GIT_AUTHOR_NAME='Archive Fixture' \
  GIT_AUTHOR_EMAIL='archive-fixture@example.invalid' \
  GIT_COMMITTER_NAME='Archive Fixture' \
  GIT_COMMITTER_EMAIL='archive-fixture@example.invalid' \
  GIT_AUTHOR_DATE='2026-01-02T03:05:05Z' \
  GIT_COMMITTER_DATE='2026-01-02T03:05:05Z' \
  git -C "$REPO_A" commit -q -m 'forbidden tracked file'
FORBIDDEN_COMMIT="$(git -C "$REPO_A" rev-parse HEAD)"
if (
  cd "$REPO_A"
  ./Scripts/release/create-source-archives.sh \
    --commit "$FORBIDDEN_COMMIT" \
    --output .release-work/forbidden
) > "$TMP/forbidden.out" 2> "$TMP/forbidden.err"; then
  fail 'tracked forbidden file was accepted'
fi
grep -Fq 'source archive error: forbidden-source-path' "$TMP/forbidden.err" || fail 'tracked forbidden file did not report forbidden-source-path'
[[ ! -e "$REPO_A/.release-work/forbidden" ]] || fail 'forbidden-path failure left output behind'

git -C "$REPO_A" rm -q -f .env
git -C "$REPO_A" commit -q -m 'remove forbidden fixture'
for forbidden_path in \
  '.github/credentials.json' \
  '.release-approvals/tracked.json' \
  '.release-evidence/tracked.json' \
  '.notary-profile-bindings/tracked.json' \
  '.notarization-logs/tracked.log' \
  'dist/tracked.txt' \
  'build/tracked.txt' \
  'DerivedData/tracked.txt' \
  'Users/local-user/private.txt' \
  'release.dmg' \
  'release.zip' \
  'certificate.p12' \
  'private-import-review-notes.md'; do
  mkdir -p "$REPO_A/$(dirname "$forbidden_path")"
  printf 'must never ship\n' > "$REPO_A/$forbidden_path"
  git -C "$REPO_A" add -f -- "$forbidden_path"
  git -C "$REPO_A" commit -q -m "reject $forbidden_path"
  forbidden_commit="$(git -C "$REPO_A" rev-parse HEAD)"
  safe_case_name="$(printf '%s' "$forbidden_path" | tr '/.' '__')"
  if (
    cd "$REPO_A"
    ./Scripts/release/create-source-archives.sh \
      --commit "$forbidden_commit" \
      --output ".release-work/forbidden-$safe_case_name"
  ) > "$TMP/forbidden-$safe_case_name.out" 2> "$TMP/forbidden-$safe_case_name.err"; then
    fail "tracked forbidden path was accepted: $forbidden_path"
  fi
  grep -Fq 'source archive error: forbidden-source-path' "$TMP/forbidden-$safe_case_name.err" || \
    fail "tracked forbidden path reported the wrong category: $forbidden_path"
  [[ ! -e "$REPO_A/.release-work/forbidden-$safe_case_name" ]] || \
    fail "tracked forbidden path left output: $forbidden_path"
  git -C "$REPO_A" rm -q -f -- "$forbidden_path"
  git -C "$REPO_A" commit -q -m "remove $forbidden_path"
done

REPO_TAG="$TMP/tag-mismatch/UtterInk"
write_fixture "$REPO_TAG" 'Tag User' 'tag@example.invalid'
OLD_COMMIT="$(git -C "$REPO_TAG" rev-parse HEAD)"
git -C "$REPO_TAG" tag v0.1.0 "$OLD_COMMIT"
printf '\nchanged\n' >> "$REPO_TAG/README.md"
git -C "$REPO_TAG" add README.md
GIT_AUTHOR_NAME='Archive Fixture' \
  GIT_AUTHOR_EMAIL='archive-fixture@example.invalid' \
  GIT_COMMITTER_NAME='Archive Fixture' \
  GIT_COMMITTER_EMAIL='archive-fixture@example.invalid' \
  GIT_AUTHOR_DATE='2026-01-02T03:06:05Z' \
  GIT_COMMITTER_DATE='2026-01-02T03:06:05Z' \
  git -C "$REPO_TAG" commit -q -m 'new release candidate'
NEW_COMMIT="$(git -C "$REPO_TAG" rev-parse HEAD)"
if (
  cd "$REPO_TAG"
  ./Scripts/release/create-source-archives.sh \
    --commit "$NEW_COMMIT" \
    --output .release-work/tag-mismatch
) > "$TMP/tag.out" 2> "$TMP/tag.err"; then
  fail 'mismatched existing tag was accepted'
fi
grep -Fq 'source archive error: tag-commit-mismatch' "$TMP/tag.err" || fail 'mismatched tag did not report tag-commit-mismatch'
[[ "$(git -C "$REPO_TAG" rev-parse 'v0.1.0^{commit}')" == "$OLD_COMMIT" ]] || fail 'mismatched tag was moved'
[[ ! -e "$REPO_TAG/.release-work/tag-mismatch" ]] || fail 'tag mismatch left output behind'

REPO_STAGE_SWAP="$TMP/stage-swap/UtterInk"
write_fixture "$REPO_STAGE_SWAP" 'Stage Swap' 'stage-swap@example.invalid'
/usr/bin/touch "$REPO_STAGE_SWAP/.git/archive-test-pause"
STAGE_SWAP_OUTPUT="$REPO_STAGE_SWAP/.release-work/stage-swap-output"
start_archiver "$REPO_STAGE_SWAP" "$STAGE_SWAP_OUTPUT" "$TMP/stage-swap"
wait_for_path "$REPO_STAGE_SWAP/.git/archive-test-ready" 'stage-swap barrier'
STAGE_SWAP_PATH="$(find "$REPO_STAGE_SWAP/.release-work" -mindepth 1 -maxdepth 1 -type d -name '.source-archives.*' -print)"
[[ -n "$STAGE_SWAP_PATH" && "$(printf '%s\n' "$STAGE_SWAP_PATH" | wc -l | tr -d ' ')" -eq 1 ]] || fail 'stage-swap did not expose exactly one stage directory'
STAGE_SWAP_NAME="$(basename "$STAGE_SWAP_PATH")"
STAGE_SWAP_ORIGINAL="$REPO_STAGE_SWAP/.release-work/original-stage"
STAGE_SWAP_REPLACEMENT="$TMP/stage-swap-replacement"
mkdir -m 0700 "$STAGE_SWAP_REPLACEMENT"
printf 'outside sentinel\n' > "$STAGE_SWAP_REPLACEMENT/sentinel"
mv "$STAGE_SWAP_PATH" "$STAGE_SWAP_ORIGINAL"
mv "$STAGE_SWAP_REPLACEMENT" "$REPO_STAGE_SWAP/.release-work/$STAGE_SWAP_NAME"
rm "$REPO_STAGE_SWAP/.git/archive-test-pause"
wait_for_archiver_failure 'stage directory real-replacement race'
grep -Fq 'source archive error: staging-rebound' "$TMP/stage-swap.err" || fail 'stage real-replacement race reported the wrong category'
[[ "$(cat "$REPO_STAGE_SWAP/.release-work/$STAGE_SWAP_NAME/sentinel")" == 'outside sentinel' ]] || fail 'stage cleanup changed replacement sentinel'
[[ "$(find "$REPO_STAGE_SWAP/.release-work/$STAGE_SWAP_NAME" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 1 ]] || fail 'stage replacement received an unexpected write'
[[ ! -e "$STAGE_SWAP_OUTPUT" && ! -L "$STAGE_SWAP_OUTPUT" ]] || fail 'stage replacement race published output'
[[ -z "$(git -C "$REPO_STAGE_SWAP" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'stage replacement race created release tag'
rm -rf "$REPO_STAGE_SWAP/.release-work/$STAGE_SWAP_NAME" "$STAGE_SWAP_ORIGINAL"

REPO_STAGE_SYMLINK="$TMP/stage-symlink/UtterInk"
write_fixture "$REPO_STAGE_SYMLINK" 'Stage Symlink' 'stage-symlink@example.invalid'
/usr/bin/touch "$REPO_STAGE_SYMLINK/.git/archive-test-pause"
STAGE_SYMLINK_OUTPUT="$REPO_STAGE_SYMLINK/.release-work/stage-symlink-output"
start_archiver "$REPO_STAGE_SYMLINK" "$STAGE_SYMLINK_OUTPUT" "$TMP/stage-symlink"
wait_for_path "$REPO_STAGE_SYMLINK/.git/archive-test-ready" 'stage-symlink barrier'
STAGE_SYMLINK_PATH="$(find "$REPO_STAGE_SYMLINK/.release-work" -mindepth 1 -maxdepth 1 -type d -name '.source-archives.*' -print)"
[[ -n "$STAGE_SYMLINK_PATH" ]] || fail 'stage-symlink did not expose a stage directory'
STAGE_SYMLINK_NAME="$(basename "$STAGE_SYMLINK_PATH")"
STAGE_SYMLINK_ORIGINAL="$REPO_STAGE_SYMLINK/.release-work/original-stage"
STAGE_SYMLINK_OUTSIDE="$TMP/stage-symlink-outside"
mkdir -m 0700 "$STAGE_SYMLINK_OUTSIDE"
printf 'outside sentinel\n' > "$STAGE_SYMLINK_OUTSIDE/sentinel"
mv "$STAGE_SYMLINK_PATH" "$STAGE_SYMLINK_ORIGINAL"
ln -s "$STAGE_SYMLINK_OUTSIDE" "$REPO_STAGE_SYMLINK/.release-work/$STAGE_SYMLINK_NAME"
rm "$REPO_STAGE_SYMLINK/.git/archive-test-pause"
wait_for_archiver_failure 'stage directory symlink-replacement race'
[[ -L "$REPO_STAGE_SYMLINK/.release-work/$STAGE_SYMLINK_NAME" ]] || fail 'stage symlink replacement was unsafely removed'
[[ "$(cat "$STAGE_SYMLINK_OUTSIDE/sentinel")" == 'outside sentinel' ]] || fail 'stage symlink race changed outside sentinel'
[[ "$(find "$STAGE_SYMLINK_OUTSIDE" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 1 ]] || fail 'stage symlink target received an unexpected write'
[[ ! -e "$STAGE_SYMLINK_OUTPUT" && ! -L "$STAGE_SYMLINK_OUTPUT" ]] || fail 'stage symlink race published output'
rm "$REPO_STAGE_SYMLINK/.release-work/$STAGE_SYMLINK_NAME"
rm -rf "$STAGE_SYMLINK_ORIGINAL"

REPO_WORK_SWAP="$TMP/release-work-swap/UtterInk"
write_fixture "$REPO_WORK_SWAP" 'Work Swap' 'work-swap@example.invalid'
/usr/bin/touch "$REPO_WORK_SWAP/.git/archive-test-pause"
WORK_SWAP_OUTPUT="$REPO_WORK_SWAP/.release-work/work-swap-output"
start_archiver "$REPO_WORK_SWAP" "$WORK_SWAP_OUTPUT" "$TMP/release-work-swap"
wait_for_path "$REPO_WORK_SWAP/.git/archive-test-ready" 'release-work-swap barrier'
WORK_SWAP_ORIGINAL="$REPO_WORK_SWAP/.release-work-original"
WORK_SWAP_OUTSIDE="$TMP/release-work-swap-outside"
mkdir -m 0700 "$WORK_SWAP_OUTSIDE"
printf 'outside sentinel\n' > "$WORK_SWAP_OUTSIDE/sentinel"
mv "$REPO_WORK_SWAP/.release-work" "$WORK_SWAP_ORIGINAL"
ln -s "$WORK_SWAP_OUTSIDE" "$REPO_WORK_SWAP/.release-work"
rm "$REPO_WORK_SWAP/.git/archive-test-pause"
wait_for_archiver_failure 'release work symlink-replacement race'
[[ -L "$REPO_WORK_SWAP/.release-work" ]] || fail 'release work symlink replacement was unsafely removed'
[[ "$(cat "$WORK_SWAP_OUTSIDE/sentinel")" == 'outside sentinel' ]] || fail 'release work cleanup changed outside sentinel'
[[ "$(find "$WORK_SWAP_OUTSIDE" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 1 ]] || fail 'release work replacement received an unexpected write'
[[ -z "$(git -C "$REPO_WORK_SWAP" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'release work swap created release tag'
rm "$REPO_WORK_SWAP/.release-work"
mv "$WORK_SWAP_ORIGINAL" "$REPO_WORK_SWAP/.release-work"

REPO_TAG_RACE="$TMP/tag-race/UtterInk"
write_fixture "$REPO_TAG_RACE" 'Tag Race' 'tag-race@example.invalid'
TAG_RACE_COMMIT="$(git -C "$REPO_TAG_RACE" rev-parse HEAD)"
git -C "$REPO_TAG_RACE" -c core.hooksPath=/dev/null tag v0.1.0 "$TAG_RACE_COMMIT"
GIT_COMMITTER_NAME='Archive Fixture' \
  GIT_COMMITTER_EMAIL='archive-fixture@example.invalid' \
  GIT_COMMITTER_DATE='2026-01-02T03:07:05Z' \
  git -C "$REPO_TAG_RACE" -c core.hooksPath=/dev/null tag -a tag-race-replacement -m 'tag race replacement' "$TAG_RACE_COMMIT"
TAG_RACE_OTHER="$(git -C "$REPO_TAG_RACE" rev-parse refs/tags/tag-race-replacement)"
git -C "$REPO_TAG_RACE" -c core.hooksPath=/dev/null tag -d tag-race-replacement >/dev/null
/usr/bin/touch "$REPO_TAG_RACE/.git/archive-test-pause"
TAG_RACE_OUTPUT="$REPO_TAG_RACE/.release-work/tag-race-output"
start_archiver "$REPO_TAG_RACE" "$TAG_RACE_OUTPUT" "$TMP/tag-race"
wait_for_path "$REPO_TAG_RACE/.git/archive-test-ready" 'tag-race barrier'
git -C "$REPO_TAG_RACE" -c core.hooksPath=/dev/null update-ref refs/tags/v0.1.0 "$TAG_RACE_OTHER" "$TAG_RACE_COMMIT"
rm "$REPO_TAG_RACE/.git/archive-test-pause"
wait_for_archiver_failure 'pre-existing tag move race'
grep -Fq 'source archive error: tag-state-changed' "$TMP/tag-race.err" || fail 'tag move race reported the wrong category'
[[ "$(git -C "$REPO_TAG_RACE" rev-parse refs/tags/v0.1.0)" == "$TAG_RACE_OTHER" ]] || fail 'tag move race rolled back a pre-existing tag'
[[ ! -e "$TAG_RACE_OUTPUT" ]] || fail 'tag move race published output'

REPO_HEAD_RACE="$TMP/head-race/UtterInk"
write_fixture "$REPO_HEAD_RACE" 'Head Race' 'head-race@example.invalid'
/usr/bin/touch "$REPO_HEAD_RACE/.git/archive-test-pause"
HEAD_RACE_OUTPUT="$REPO_HEAD_RACE/.release-work/head-race-output"
start_archiver "$REPO_HEAD_RACE" "$HEAD_RACE_OUTPUT" "$TMP/head-race"
wait_for_path "$REPO_HEAD_RACE/.git/archive-test-ready" 'head-race barrier'
commit_fixture_change "$REPO_HEAD_RACE" 'advance HEAD during source archive' '2026-01-02T03:08:05Z'
rm "$REPO_HEAD_RACE/.git/archive-test-pause"
wait_for_archiver_failure 'HEAD advance race'
grep -Fq 'source archive error: commit-mismatch' "$TMP/head-race.err" || fail 'HEAD advance race reported the wrong category'
[[ ! -e "$HEAD_RACE_OUTPUT" ]] || fail 'HEAD advance race published output'
[[ -z "$(git -C "$REPO_HEAD_RACE" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'HEAD advance race created release tag'

REPO_VERIFIER_SWAP="$TMP/verifier-swap/UtterInk"
write_fixture "$REPO_VERIFIER_SWAP" 'Verifier Swap' 'verifier-swap@example.invalid'
/usr/bin/touch "$REPO_VERIFIER_SWAP/.git/archive-test-pause"
VERIFIER_SWAP_OUTPUT="$REPO_VERIFIER_SWAP/.release-work/verifier-swap-output"
start_archiver "$REPO_VERIFIER_SWAP" "$VERIFIER_SWAP_OUTPUT" "$TMP/verifier-swap"
wait_for_path "$REPO_VERIFIER_SWAP/.git/archive-test-ready" 'verifier-swap barrier'
mv "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.sh" "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.original"
printf '#!/bin/bash\nexit 97\n' > "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.sh"
chmod 0755 "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.sh"
rm "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.sh"
mv "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.original" "$REPO_VERIFIER_SWAP/Scripts/release/verify-candidate.sh"
rm "$REPO_VERIFIER_SWAP/.git/archive-test-pause"
if ! wait "$ACTIVE_ARCHIVER_PID"; then
  ACTIVE_ARCHIVER_PID=''
  fail "commit-bound verifier failed after transient path replacement: $(cat "$TMP/verifier-swap.err")"
fi
ACTIVE_ARCHIVER_PID=''
[[ -f "$VERIFIER_SWAP_OUTPUT/$TAR_NAME" && -f "$VERIFIER_SWAP_OUTPUT/$ZIP_NAME" ]] || fail 'commit-bound verifier swap did not publish both archives'

REPO_POST_PUBLISH="$TMP/post-publish-race/UtterInk"
write_fixture "$REPO_POST_PUBLISH" 'Post Publish' 'post-publish@example.invalid'
POST_PUBLISH_OUTPUT="$REPO_POST_PUBLISH/.release-work/post-publish-output"
start_archiver "$REPO_POST_PUBLISH" "$POST_PUBLISH_OUTPUT" "$TMP/post-publish"
if ! /usr/bin/python3 -I - "$ACTIVE_ARCHIVER_PID" "$POST_PUBLISH_OUTPUT" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

pid = int(sys.argv[1])
output = Path(sys.argv[2])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if output.exists() or output.is_symlink():
        os.kill(pid, signal.SIGSTOP)
        raise SystemExit(0)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.0002)
raise SystemExit(1)
PY
then
  fail 'post-publish race could not stop the archiver after atomic rename'
fi
commit_fixture_change "$REPO_POST_PUBLISH" 'advance HEAD after source publication' '2026-01-02T03:09:05Z'
kill -CONT "$ACTIVE_ARCHIVER_PID"
wait_for_archiver_failure 'post-publish HEAD advance race'
grep -Fq 'source archive error: commit-mismatch' "$TMP/post-publish.err" || fail 'post-publish race reported the wrong category'
[[ ! -e "$POST_PUBLISH_OUTPUT" && ! -L "$POST_PUBLISH_OUTPUT" ]] || fail 'post-publish race did not revoke exact output'
[[ -z "$(git -C "$REPO_POST_PUBLISH" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'post-publish race did not CAS-rollback its tag'

REPO_PUBLISHED_NAME_SWAP="$TMP/published-name-swap/UtterInk"
write_fixture "$REPO_PUBLISHED_NAME_SWAP" 'Published Name Swap' 'published-name-swap@example.invalid'
PUBLISHED_NAME_SWAP_OUTPUT="$REPO_PUBLISHED_NAME_SWAP/.release-work/published-name-output"
PUBLISHED_NAME_SWAP_MOVED="$REPO_PUBLISHED_NAME_SWAP/.release-work/published-name-output-moved"
start_archiver "$REPO_PUBLISHED_NAME_SWAP" "$PUBLISHED_NAME_SWAP_OUTPUT" "$TMP/published-name-swap"
if ! /usr/bin/python3 -I - "$ACTIVE_ARCHIVER_PID" "$PUBLISHED_NAME_SWAP_OUTPUT" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

pid = int(sys.argv[1])
output = Path(sys.argv[2])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if output.is_dir():
        os.kill(pid, signal.SIGSTOP)
        raise SystemExit(0)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.0002)
raise SystemExit(1)
PY
then
  fail 'published name-swap race could not stop the archiver after publication'
fi
# The publishing child may still be returning its verified inode record while
# the parent shell is stopped. Give it time to finish before rebinding the name.
/bin/sleep 0.1
mv "$PUBLISHED_NAME_SWAP_OUTPUT" "$PUBLISHED_NAME_SWAP_MOVED"
mkdir -m 0700 "$PUBLISHED_NAME_SWAP_OUTPUT"
printf 'replacement sentinel\n' > "$PUBLISHED_NAME_SWAP_OUTPUT/sentinel"
kill -CONT "$ACTIVE_ARCHIVER_PID"
wait_for_archiver_failure 'published output name-swap race'
grep -Fq 'source archive error: published-output-changed' "$TMP/published-name-swap.err" || fail 'published name-swap race reported the wrong category'
[[ -d "$PUBLISHED_NAME_SWAP_OUTPUT" && ! -L "$PUBLISHED_NAME_SWAP_OUTPUT" ]] || fail 'published name-swap rollback removed the replacement directory'
[[ "$(cat "$PUBLISHED_NAME_SWAP_OUTPUT/sentinel")" == 'replacement sentinel' ]] || fail 'published name-swap rollback changed the replacement sentinel'
[[ "$(find "$PUBLISHED_NAME_SWAP_OUTPUT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 1 ]] || fail 'published name-swap rollback changed the replacement inventory'
[[ ! -e "$PUBLISHED_NAME_SWAP_MOVED" && ! -L "$PUBLISHED_NAME_SWAP_MOVED" ]] || fail 'published name-swap rollback left the original directory under its new name'
if find "$REPO_PUBLISHED_NAME_SWAP/.release-work" -type f \( -name "$TAR_NAME" -o -name "$ZIP_NAME" \) -print -quit | grep -q .; then
  fail 'published name-swap rollback left a source archive behind'
fi
[[ -z "$(git -C "$REPO_PUBLISHED_NAME_SWAP" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'published name-swap rollback did not CAS-rollback its tag'

REPO_NESTED_REBIND="$TMP/nested-parent-rebind/UtterInk"
write_fixture "$REPO_NESTED_REBIND" 'Nested Rebind' 'nested-rebind@example.invalid'
NESTED_PARENT="$REPO_NESTED_REBIND/.release-work/nested-parent"
NESTED_REBIND_OUTPUT="$NESTED_PARENT/output"
start_archiver "$REPO_NESTED_REBIND" "$NESTED_REBIND_OUTPUT" "$TMP/nested-parent-rebind"
if ! /usr/bin/python3 -I - "$ACTIVE_ARCHIVER_PID" "$NESTED_REBIND_OUTPUT" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

pid = int(sys.argv[1])
output = Path(sys.argv[2])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if output.exists() or output.is_symlink():
        os.kill(pid, signal.SIGSTOP)
        raise SystemExit(0)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.0002)
raise SystemExit(1)
PY
then
  fail 'nested parent rebind could not stop the archiver after publication'
fi
NESTED_PARENT_ORIGINAL="$REPO_NESTED_REBIND/.release-work/nested-parent-original"
mv "$NESTED_PARENT" "$NESTED_PARENT_ORIGINAL"
mkdir -m 0700 "$NESTED_PARENT"
printf 'replacement sentinel\n' > "$NESTED_PARENT/sentinel"
commit_fixture_change "$REPO_NESTED_REBIND" 'advance HEAD after nested parent rebind' '2026-01-02T03:10:05Z'
kill -CONT "$ACTIVE_ARCHIVER_PID"
wait_for_archiver_failure 'nested output parent rebind race'
[[ ! -e "$NESTED_PARENT_ORIGINAL/output" && ! -L "$NESTED_PARENT_ORIGINAL/output" ]] || fail 'held nested parent rollback left the original output behind'
[[ "$(cat "$NESTED_PARENT/sentinel")" == 'replacement sentinel' ]] || fail 'nested parent rollback changed the replacement directory'
[[ -z "$(git -C "$REPO_NESTED_REBIND" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'nested parent rebind did not CAS-rollback its tag'

REPO_EQUAL_TAMPER="$TMP/equal-size-tamper/UtterInk"
write_fixture "$REPO_EQUAL_TAMPER" 'Equal Tamper' 'equal-tamper@example.invalid'
EQUAL_TAMPER_OUTPUT="$REPO_EQUAL_TAMPER/.release-work/equal-size-output"
start_archiver "$REPO_EQUAL_TAMPER" "$EQUAL_TAMPER_OUTPUT" "$TMP/equal-size-tamper"
if ! /usr/bin/python3 -I - "$ACTIVE_ARCHIVER_PID" "$EQUAL_TAMPER_OUTPUT/$TAR_NAME" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

pid = int(sys.argv[1])
archive = Path(sys.argv[2])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if archive.is_file():
        os.kill(pid, signal.SIGSTOP)
        descriptor = os.open(archive, os.O_RDWR | os.O_NOFOLLOW)
        try:
            original = os.pread(descriptor, 1, 0)
            if len(original) != 1:
                raise SystemExit(1)
            os.pwrite(descriptor, bytes([original[0] ^ 0x01]), 0)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        raise SystemExit(0)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.0002)
raise SystemExit(1)
PY
then
  fail 'equal-size archive tamper could not stop the archiver after publication'
fi
kill -CONT "$ACTIVE_ARCHIVER_PID"
wait_for_archiver_failure 'equal-size archive tamper race'
grep -Fq 'source archive error: published-output-changed' "$TMP/equal-size-tamper.err" || fail 'equal-size archive tamper reported the wrong category'
[[ ! -e "$EQUAL_TAMPER_OUTPUT" && ! -L "$EQUAL_TAMPER_OUTPUT" ]] || fail 'equal-size archive tamper did not revoke exact output'
[[ -z "$(git -C "$REPO_EQUAL_TAMPER" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)" ]] || fail 'equal-size archive tamper did not CAS-rollback its tag'

if find "$TMP" -type d -name '.source-archives.*' -print -quit | grep -q .; then
  fail 'temporary archive directory was not cleaned'
fi

if grep -Eiq '(^|[^[:alnum:]_])(curl|wget|gh)[[:space:]]|git[[:space:]]+(push|fetch)|api[.]github[.]com' "$SCRIPT"; then
  fail 'archive script contains publication or network capability'
fi

MAIN_TAG_AFTER="$(git -C "$ROOT" show-ref --verify --hash refs/tags/v0.1.0 2>/dev/null || true)"
[[ "$MAIN_TAG_AFTER" == "$MAIN_TAG_BEFORE" ]] || fail 'test changed the main repository release tag'

bash -n "$SCRIPT"
printf 'source archive tests passed\n'
