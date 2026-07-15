#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_NOTARY_PROFILE_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'notary profile registration error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_NOTARY_PROFILE_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C UTTERINK_NOTARY_PROFILE_ENV_CLEAN=1)
  for allowed_name in \
    UTTERINK_RELEASE_TEST_MODE UTTERINK_RELEASE_TEST_TOOL_ROOT \
    UTTERINK_RELEASE_TEST_NOW UTTERINK_FIXTURE_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'notary profile registration error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'notary profile registration error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_NOTARY_PROFILE_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_RELEASE_TEST_NOW|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *) printf 'notary profile registration error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_NOTARY_PROFILE_ENV_CLEAN

set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONDONTWRITEBYTECODE=1
export TZ=UTC
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
unset \
  BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
  DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH PERL5OPT PERL5LIB PERLLIB PERL5DB
umask 077

fail() {
  local category="$1"
  local status="${2:-1}"
  printf 'notary profile registration error: %s\n' "$category" >&2
  exit "$status"
}

IDENTITY=''
TEAM_ID=''
PROFILE=''
RECEIPT_ARGUMENT=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --identity)
      [[ -z "$IDENTITY" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      IDENTITY="$2"; shift 2 ;;
    --team-id)
      [[ -z "$TEAM_ID" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      TEAM_ID="$2"; shift 2 ;;
    --keychain-profile)
      [[ -z "$PROFILE" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      PROFILE="$2"; shift 2 ;;
    --receipt)
      [[ -z "$RECEIPT_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      RECEIPT_ARGUMENT="$2"; shift 2 ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$IDENTITY" && -n "$TEAM_ID" && -n "$PROFILE" && -n "$RECEIPT_ARGUMENT" ]] || fail invalid-arguments 2
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail invalid-team-id 2
[[ "$IDENTITY" == 'Developer ID Application: '* && "$IDENTITY" == *" ($TEAM_ID)" && "${#IDENTITY}" -le 512 ]] ||
  fail invalid-identity 2
case "$IDENTITY" in *$'\n'*|*$'\r'*|*$'\t'*|*/*) fail invalid-identity 2 ;; esac
if ! /usr/bin/python3 -I - "$PROFILE" <<'PY' >/dev/null 2>&1
import re
import sys

try:
    value = sys.argv[1]
    value.encode("utf-8", errors="strict")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value) is None:
        raise ValueError
except (UnicodeError, ValueError):
    raise SystemExit(1)
PY
then
  fail invalid-profile-name 2
fi

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path 20
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" || fail unsafe-script-path 20
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)" || fail unsafe-script-path 20
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository 20
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail not-a-repository 20
[[ "$GIT_ROOT" == "$ROOT" ]] || fail repository-mismatch 20
cd "$ROOT"

TEST_MODE=0
case "${UTTERINK_RELEASE_TEST_MODE:-}" in '') ;; 1) TEST_MODE=1 ;; *) fail invalid-test-mode 20 ;; esac
if [[ "$TEST_MODE" -eq 1 ]]; then
  if ! /usr/bin/python3 -I - "$ROOT" "${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}" "${UTTERINK_FIXTURE_LOG:-}" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os
import stat
import sys

root, tools, log = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
try:
    root_item = os.lstat(root)
    git_item = os.lstat(root / ".git")
    repository_marker = root / ".utterink-notary-profile-test-repository"
    marker_item = os.lstat(repository_marker)
    tool_item = os.lstat(tools)
    tool_marker = tools / ".utterink-notary-profile-test-tools"
    tool_marker_item = os.lstat(tool_marker)
    if (
        not root.as_posix().startswith("/private/tmp/utterink-notary-profile-tests.")
        or root != Path(os.path.abspath(root))
        or root.is_symlink()
        or root.resolve(strict=True) != root
        or tools != root / "FixtureTools"
        or tools.is_symlink()
        or tools.resolve(strict=True) != tools
        or not log.as_posix().startswith(root.parent.as_posix() + "/")
        or not stat.S_ISDIR(root_item.st_mode)
        or root_item.st_uid != os.geteuid()
        or root_item.st_mode & 0o022
        or not stat.S_ISDIR(git_item.st_mode)
        or stat.S_ISLNK(git_item.st_mode)
        or git_item.st_uid != os.geteuid()
        or git_item.st_mode & 0o022
        or not stat.S_ISREG(marker_item.st_mode)
        or stat.S_ISLNK(marker_item.st_mode)
        or marker_item.st_uid != os.geteuid()
        or marker_item.st_mode & 0o022
        or repository_marker.read_bytes() != b"utterink-notary-profile-test-repository-v1\n"
        or not stat.S_ISDIR(tool_item.st_mode)
        or tool_item.st_uid != os.geteuid()
        or tool_item.st_mode & 0o022
        or not stat.S_ISREG(tool_marker_item.st_mode)
        or stat.S_ISLNK(tool_marker_item.st_mode)
        or tool_marker_item.st_uid != os.geteuid()
        or tool_marker_item.st_mode & 0o022
        or tool_marker.read_bytes() != b"utterink-notary-profile-test-tools-v1\n"
    ):
        raise ValueError
    for name in ("security", "openssl", "xcrun"):
        item = os.lstat(tools / name)
        if (
            not stat.S_ISREG(item.st_mode)
            or stat.S_ISLNK(item.st_mode)
            or item.st_uid != os.geteuid()
            or item.st_mode & 0o022
            or not item.st_mode & stat.S_IXUSR
        ):
            raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
  then
    fail invalid-test-environment 20
  fi
  TOOL_ROOT="$UTTERINK_RELEASE_TEST_TOOL_ROOT"
  SECURITY="$TOOL_ROOT/security"
  OPENSSL="$TOOL_ROOT/openssl"
  XCRUN="$TOOL_ROOT/xcrun"
  NOW="${UTTERINK_RELEASE_TEST_NOW:-}"
else
  unset UTTERINK_RELEASE_TEST_MODE UTTERINK_RELEASE_TEST_TOOL_ROOT UTTERINK_RELEASE_TEST_NOW UTTERINK_FIXTURE_LOG
  SECURITY=/usr/bin/security
  OPENSSL=/usr/bin/openssl
  XCRUN=/usr/bin/xcrun
  [[ -t 0 && -t 1 ]] || fail interactive-registration-required 20
  printf 'Type REGISTER %s to authorize this Keychain/network registration: ' "$TEAM_ID" >&2
  confirmation=''
  IFS= read -r confirmation || fail external-approval-required 20
  [[ "$confirmation" == "REGISTER $TEAM_ID" ]] || fail external-approval-required 20
  unset confirmation
  NOW="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || fail clock-unavailable 20
fi
for tool in "$SECURITY" "$OPENSSL" "$XCRUN"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail apple-tool-unavailable 20
done
if ! /usr/bin/python3 -I - "$NOW" <<'PY' >/dev/null 2>&1
from datetime import datetime
import sys

try:
    value = sys.argv[1]
    parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ValueError
except ValueError:
    raise SystemExit(1)
PY
then
  fail clock-unavailable 20
fi
readonly TEST_MODE SECURITY OPENSSL XCRUN NOW

if ! RECEIPT="$(/usr/bin/python3 -I - "$ROOT" "$RECEIPT_ARGUMENT" <<'PY'
from pathlib import Path, PurePath
import os
import re
import stat
import sys

root = Path(sys.argv[1])
raw = sys.argv[2]
try:
    if (
        not raw
        or len(raw.encode("utf-8", errors="strict")) > 4096
        or any(ord(c) < 32 or ord(c) == 127 for c in raw)
        or ".." in PurePath(raw).parts
    ):
        raise ValueError
    receipt = Path(os.path.abspath(Path(raw) if os.path.isabs(raw) else root / raw))
    expected_parent = root / ".notary-profile-bindings"
    if receipt.parent != expected_parent or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json", receipt.name) is None:
        raise ValueError
    root_fd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        try:
            os.mkdir(".notary-profile-bindings", 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        parent_item = os.stat(".notary-profile-bindings", dir_fd=root_fd, follow_symlinks=False)
        if (
            not stat.S_ISDIR(parent_item.st_mode)
            or stat.S_ISLNK(parent_item.st_mode)
            or parent_item.st_uid != os.geteuid()
            or stat.S_IMODE(parent_item.st_mode) != 0o700
        ):
            raise ValueError
        parent_fd = os.open(
            ".notary-profile-bindings",
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=root_fd,
        )
        try:
            try:
                os.stat(receipt.name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError
        finally:
            os.close(parent_fd)
    finally:
        os.close(root_fd)
    print(receipt)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
)"; then
  fail unsafe-receipt-path 21
fi
readonly RECEIPT

[[ -d /private/tmp && ! -L /private/tmp ]] || fail temporary-directory-unavailable 20
CONTROL="$(/usr/bin/mktemp -d /private/tmp/utterink-notary-profile.XXXXXX)" || fail temporary-directory-unavailable 20
[[ "$CONTROL" == /private/tmp/utterink-notary-profile.* && -d "$CONTROL" && ! -L "$CONTROL" ]] || fail temporary-directory-unavailable 20
/bin/chmod 0700 "$CONTROL" || fail temporary-directory-unavailable 20
exec 9< "$CONTROL" || fail temporary-directory-unavailable 20
read -r CONTROL_DEV CONTROL_INO < <(/usr/bin/stat -f '%d %i' "$CONTROL") || fail temporary-directory-unavailable 20
readonly CONTROL CONTROL_DEV CONTROL_INO

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if ! /usr/bin/python3 -I - "$CONTROL_DEV" "$CONTROL_INO" 9 <<'PY' >/dev/null 2>&1
import os
import stat
import sys

expected = (int(sys.argv[1]), int(sys.argv[2]))
descriptor = int(sys.argv[3])

def clear(directory_fd: int) -> None:
    for name in os.listdir(directory_fd):
        if not name or name in {".", ".."} or "/" in name or "\0" in name:
            raise OSError
        item = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
            child = os.open(name, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (item.st_dev, item.st_ino):
                    raise OSError
                clear(child)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)

opened = os.fstat(descriptor)
if (opened.st_dev, opened.st_ino) != expected or not stat.S_ISDIR(opened.st_mode):
    raise SystemExit(1)
clear(descriptor)
parent = os.open("/private/tmp", os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    matches = []
    for name in os.listdir(parent):
        if not name.startswith("utterink-notary-profile."):
            continue
        try:
            item = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError:
            continue
        if (item.st_dev, item.st_ino) == expected and stat.S_ISDIR(item.st_mode):
            matches.append(name)
    if len(matches) != 1:
        raise OSError
    os.rmdir(matches[0], dir_fd=parent)
finally:
    os.close(parent)
PY
  then
    printf 'notary profile registration error: cleanup-failed\n' >&2
    status=40
  fi
  exec 9<&-
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! "$SECURITY" find-identity -v -p codesigning > "$CONTROL/identities.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
if ! /usr/bin/python3 -I - \
  "$CONTROL/identities.txt" "$IDENTITY" "$CONTROL/identity-sha1" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re
import sys

try:
    matches = []
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r'\s*[0-9]+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*', line)
        if match is not None and match.group(2) == sys.argv[2]:
            matches.append(match.group(1).lower())
    if len(matches) != 1:
        raise ValueError
    Path(sys.argv[3]).write_text(matches[0], encoding="ascii")
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
if ! "$SECURITY" find-certificate -a -c "$IDENTITY" -p > "$CONTROL/certificate.pem" 2> "$CONTROL/tool-error.txt"; then
  fail identity-preflight-failed 24
fi
/bin/chmod 0600 "$CONTROL/certificate.pem" || fail identity-preflight-failed 24
if ! /usr/bin/python3 -I - "$CONTROL/certificate.pem" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

try:
    data = Path(sys.argv[1]).read_bytes()
    if len(data) > 512 * 1024 or data.count(b"-----BEGIN CERTIFICATE-----") != 1 or data.count(b"-----END CERTIFICATE-----") != 1:
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
"$SECURITY" verify-cert -c "$CONTROL/certificate.pem" -p codeSign > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt" ||
  fail identity-preflight-failed 24
"$OPENSSL" x509 -in "$CONTROL/certificate.pem" -checkend 0 -noout > "$CONTROL/tool-output.txt" 2> "$CONTROL/tool-error.txt" ||
  fail identity-preflight-failed 24
"$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -subject -nameopt sep_multiline > "$CONTROL/subject.txt" 2> "$CONTROL/tool-error.txt" ||
  fail identity-preflight-failed 24
"$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -fingerprint -sha1 > "$CONTROL/certificate-sha1.txt" 2> "$CONTROL/tool-error.txt" ||
  fail identity-preflight-failed 24
"$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -fingerprint -sha256 > "$CONTROL/certificate-sha256.txt" 2> "$CONTROL/tool-error.txt" ||
  fail identity-preflight-failed 24
if ! /usr/bin/python3 -I - \
  "$CONTROL/subject.txt" "$CONTROL/certificate-sha1.txt" "$CONTROL/certificate-sha256.txt" \
  "$CONTROL/identity-sha1" "$IDENTITY" "$TEAM_ID" "$CONTROL/certificate-sha256" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re
import sys

def fingerprint(path: Path, length: int) -> str:
    lines = path.read_text(encoding="ascii").splitlines()
    matches = []
    for line in lines:
        match = re.fullmatch(r"[A-Za-z0-9-]+ Fingerprint=([0-9A-Fa-f:]+)", line.strip())
        if match is not None:
            value = match.group(1).replace(":", "").lower()
            if len(value) == length and re.fullmatch(r"[0-9a-f]+", value):
                matches.append(value)
    if len(matches) != 1:
        raise ValueError
    return matches[0]

try:
    common_names = []
    team_ids = []
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("commonName = "):
            common_names.append(stripped.removeprefix("commonName = "))
        elif stripped.startswith("organizationalUnitName = "):
            team_ids.append(stripped.removeprefix("organizationalUnitName = "))
    certificate_sha1 = fingerprint(Path(sys.argv[2]), 40)
    certificate_sha256 = fingerprint(Path(sys.argv[3]), 64)
    identity_sha1 = Path(sys.argv[4]).read_text(encoding="ascii")
    if common_names != [sys.argv[5]] or team_ids != [sys.argv[6]] or certificate_sha1 != identity_sha1:
        raise ValueError
    Path(sys.argv[7]).write_text(certificate_sha256, encoding="ascii")
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
then
  fail identity-preflight-failed 24
fi
CERTIFICATE_SHA256="$(/bin/cat "$CONTROL/certificate-sha256")"
readonly CERTIFICATE_SHA256

if ! "$XCRUN" notarytool --version > "$CONTROL/notarytool-version.txt" 2> "$CONTROL/tool-error.txt"; then
  fail notarytool-unavailable 25
fi
if ! /usr/bin/python3 -I - "$CONTROL/notarytool-version.txt" "$CONTROL/notarytool-version" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if len(lines) != 1 or not (1 <= len(lines[0].encode("utf-8")) <= 256) or any(ord(c) < 32 or ord(c) == 127 for c in lines[0]):
        raise ValueError
    Path(sys.argv[2]).write_text(lines[0], encoding="utf-8")
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
then
  fail notarytool-unavailable 25
fi
NOTARYTOOL_VERSION="$(/bin/cat "$CONTROL/notarytool-version")"
readonly NOTARYTOOL_VERSION

if [[ "$TEST_MODE" -eq 1 ]]; then
  "$XCRUN" notarytool store-credentials "$PROFILE" --team-id "$TEAM_ID" --validate \
    > "$CONTROL/store-output.txt" 2> "$CONTROL/tool-error.txt" || fail credential-registration-failed 26
else
  "$XCRUN" notarytool store-credentials "$PROFILE" --team-id "$TEAM_ID" --validate || fail credential-registration-failed 26
fi
if ! "$XCRUN" notarytool history --keychain-profile "$PROFILE" --output-format json \
  > "$CONTROL/history.json" 2> "$CONTROL/tool-error.txt"; then
  fail profile-history-failed 27
fi
if ! /usr/bin/python3 -I - "$CONTROL/history.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import json
import sys

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result

try:
    data = Path(sys.argv[1]).read_bytes()
    if not data or len(data) > 8 * 1024 * 1024:
        raise ValueError
    value = json.loads(data.decode("utf-8"), object_pairs_hook=unique)
    if type(value) is not dict or type(value.get("history")) is not list:
        raise ValueError
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
then
  fail profile-history-failed 27
fi

if ! /usr/bin/python3 -I - \
  "$RECEIPT" "$TEAM_ID" "$CERTIFICATE_SHA256" "$PROFILE" "$NOTARYTOOL_VERSION" "$NOW" <<'PY' >/dev/null 2>&1
from datetime import datetime, timedelta, timezone
from pathlib import Path
import hashlib
import json
import os
import secrets
import stat
import sys

receipt_path = Path(sys.argv[1])
team_id, certificate_sha256, profile, notarytool_version, now_text = sys.argv[2:]
descriptor = -1
parent_fd = -1
created_inode = None
try:
    validated = datetime.strptime(now_text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    expires = validated + timedelta(seconds=86400)
    salt = secrets.token_hex(32)
    nonce = secrets.token_hex(32)
    profile_hash = hashlib.sha256(
        b"UtterInk-notary-profile-v1\0" + bytes.fromhex(salt) + profile.encode("utf-8", errors="strict")
    ).hexdigest()
    receipt = {
        "schemaVersion": 1,
        "bindingNonce": nonce,
        "appleTeamID": team_id,
        "signingCertificateSHA256": certificate_sha256,
        "profileNameSalt": salt,
        "profileNameHashSHA256": profile_hash,
        "notarytoolVersion": notarytool_version,
        "validatedAt": validated.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    canonical_without_self = (
        json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    receipt["selfSHA256"] = hashlib.sha256(canonical_without_self).hexdigest()
    encoded = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    parent_fd = os.open(
        receipt_path.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    parent = os.fstat(parent_fd)
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or stat.S_IMODE(parent.st_mode) != 0o700:
        raise OSError
    descriptor = os.open(
        receipt_path.name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=parent_fd,
    )
    opened = os.fstat(descriptor)
    created_inode = (opened.st_dev, opened.st_ino)
    if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_nlink != 1:
        raise OSError
    offset = 0
    while offset < len(encoded):
        written = os.write(descriptor, encoded[offset:])
        if written <= 0:
            raise OSError
        offset += written
    os.fchmod(descriptor, 0o600)
    os.fsync(descriptor)
    named = os.stat(receipt_path.name, dir_fd=parent_fd, follow_symlinks=False)
    after = os.fstat(descriptor)
    if (
        (named.st_dev, named.st_ino) != created_inode
        or (after.st_dev, after.st_ino) != created_inode
        or stat.S_IMODE(after.st_mode) != 0o600
        or after.st_nlink != 1
    ):
        raise OSError
    os.fsync(parent_fd)
except (OSError, UnicodeError, ValueError):
    if parent_fd >= 0 and created_inode is not None:
        try:
            named = os.stat(receipt_path.name, dir_fd=parent_fd, follow_symlinks=False)
            if (named.st_dev, named.st_ino) == created_inode and not stat.S_ISDIR(named.st_mode):
                os.unlink(receipt_path.name, dir_fd=parent_fd)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if descriptor >= 0:
        os.close(descriptor)
    if parent_fd >= 0:
        os.close(parent_fd)
PY
then
  fail receipt-creation-failed 28
fi

exit 0
