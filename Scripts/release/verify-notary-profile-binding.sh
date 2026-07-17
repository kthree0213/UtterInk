#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_NOTARY_PROFILE_VERIFY_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'notary profile verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_NOTARY_PROFILE_VERIFY_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C UTTERINK_NOTARY_PROFILE_VERIFY_ENV_CLEAN=1)
  for allowed_name in \
    UTTERINK_RELEASE_TEST_MODE UTTERINK_RELEASE_TEST_TOOL_ROOT \
    UTTERINK_RELEASE_TEST_NOW UTTERINK_FIXTURE_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'notary profile verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'notary profile verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_NOTARY_PROFILE_VERIFY_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_RELEASE_TEST_NOW|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *) printf 'notary profile verification error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_NOTARY_PROFILE_VERIFY_ENV_CLEAN

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
  printf 'notary profile verification error: %s\n' "$category" >&2
  exit "$status"
}

TEAM_ID=''
PROFILE=''
RECEIPT_ARGUMENT=''
EXPECTED_RECEIPT_SHA256=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --team-id)
      [[ -z "$TEAM_ID" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      TEAM_ID="$2"; shift 2 ;;
    --keychain-profile)
      [[ -z "$PROFILE" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      PROFILE="$2"; shift 2 ;;
    --receipt)
      [[ -z "$RECEIPT_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      RECEIPT_ARGUMENT="$2"; shift 2 ;;
    --expected-receipt-sha256)
      [[ -z "$EXPECTED_RECEIPT_SHA256" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      EXPECTED_RECEIPT_SHA256="$2"; shift 2 ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$TEAM_ID" && -n "$PROFILE" && -n "$RECEIPT_ARGUMENT" && -n "$EXPECTED_RECEIPT_SHA256" ]] || fail invalid-arguments 2
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail invalid-team-id 2
[[ "$EXPECTED_RECEIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail invalid-receipt-digest 2
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
    printf 'notary profile verification error: cleanup-failed\n' >&2
    status=40
  fi
  exec 9<&-
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! /usr/bin/python3 -I - \
  "$ROOT" "$RECEIPT_ARGUMENT" "$TEAM_ID" "$PROFILE" "$EXPECTED_RECEIPT_SHA256" "$NOW" \
  "$CONTROL/certificate-sha256" "$CONTROL/notarytool-version" <<'PY' >/dev/null 2>&1
from datetime import datetime, timezone
from pathlib import Path, PurePath
import hashlib
import json
import os
import re
import stat
import sys

root = Path(sys.argv[1])
raw, expected_team, profile, expected_file_sha256, now_text = sys.argv[2:7]
certificate_output, version_output = map(Path, sys.argv[7:9])

def abort() -> None:
    raise SystemExit(1)

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            abort()
        result[key] = value
    return result

def timestamp(value: object) -> datetime:
    if type(value) is not str or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is None:
        abort()
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        abort()
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        abort()
    return parsed

try:
    if (
        not raw
        or len(raw.encode("utf-8", errors="strict")) > 4096
        or any(ord(c) < 32 or ord(c) == 127 for c in raw)
        or ".." in PurePath(raw).parts
    ):
        abort()
    receipt_path = Path(os.path.abspath(Path(raw) if os.path.isabs(raw) else root / raw))
    expected_parent = root / ".notary-profile-bindings"
    if receipt_path.parent != expected_parent or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json", receipt_path.name) is None:
        abort()
    parent_item = os.lstat(expected_parent)
    if (
        not stat.S_ISDIR(parent_item.st_mode)
        or stat.S_ISLNK(parent_item.st_mode)
        or parent_item.st_uid != os.geteuid()
        or stat.S_IMODE(parent_item.st_mode) != 0o700
    ):
        abort()
    parent_fd = os.open(expected_parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.stat(receipt_path.name, dir_fd=parent_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_nlink != 1
            or before.st_size > 64 * 1024
        ):
            abort()
        descriptor = os.open(receipt_path.name, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        try:
            opened = os.fstat(descriptor)
            chunks = []
            total = 0
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > 64 * 1024:
                    abort()
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_fd)
    fingerprint = lambda item: (
        item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_nlink,
        item.st_size, item.st_mtime_ns, item.st_ctime_ns,
    )
    if fingerprint(before) != fingerprint(opened) or fingerprint(opened) != fingerprint(after):
        abort()
    data = b"".join(chunks)
    if hashlib.sha256(data).hexdigest() != expected_file_sha256:
        abort()
    receipt = json.loads(data.decode("utf-8"), object_pairs_hook=unique)
    expected_keys = {
        "schemaVersion", "bindingNonce", "appleTeamID", "signingCertificateSHA256",
        "profileNameSalt", "profileNameHashSHA256", "notarytoolVersion",
        "validatedAt", "expiresAt", "selfSHA256",
    }
    if type(receipt) is not dict or set(receipt) != expected_keys:
        abort()
    if type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1:
        abort()
    for key in ("bindingNonce", "profileNameSalt", "profileNameHashSHA256", "signingCertificateSHA256", "selfSHA256"):
        if type(receipt[key]) is not str or re.fullmatch(r"[0-9a-f]{64}", receipt[key]) is None:
            abort()
    if type(receipt["appleTeamID"]) is not str or receipt["appleTeamID"] != expected_team:
        abort()
    version = receipt["notarytoolVersion"]
    if type(version) is not str or not (1 <= len(version.encode("utf-8")) <= 256) or any(ord(c) < 32 or ord(c) == 127 for c in version):
        abort()
    salt = bytes.fromhex(receipt["profileNameSalt"])
    expected_profile_hash = hashlib.sha256(
        b"UtterInk-notary-profile-v1\0" + salt + profile.encode("utf-8", errors="strict")
    ).hexdigest()
    if receipt["profileNameHashSHA256"] != expected_profile_hash:
        abort()
    without_self = dict(receipt)
    actual_self = without_self.pop("selfSHA256")
    canonical_without_self = (
        json.dumps(without_self, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if actual_self != hashlib.sha256(canonical_without_self).hexdigest():
        abort()
    canonical = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if data != canonical:
        abort()
    validated = timestamp(receipt["validatedAt"])
    expires = timestamp(receipt["expiresAt"])
    now = timestamp(now_text)
    if int((expires - validated).total_seconds()) != 86400 or now < validated or now >= expires:
        abort()
    certificate_output.write_text(receipt["signingCertificateSHA256"], encoding="ascii")
    version_output.write_text(version, encoding="utf-8")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    abort()
PY
then
  fail invalid-binding-receipt 21
fi
CERTIFICATE_SHA256="$(/bin/cat "$CONTROL/certificate-sha256")"
RECEIPT_NOTARYTOOL_VERSION="$(/bin/cat "$CONTROL/notarytool-version")"
readonly CERTIFICATE_SHA256 RECEIPT_NOTARYTOOL_VERSION

if ! "$SECURITY" find-identity -v -p codesigning > "$CONTROL/identities.txt" 2> "$CONTROL/tool-error.txt"; then
  fail identity-discovery-failed 24
fi
if ! /usr/bin/python3 -I - \
  "$CONTROL/identities.txt" "$TEAM_ID" "$CERTIFICATE_SHA256" \
  "$SECURITY" "$OPENSSL" "$CONTROL" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os
import re
import stat
import subprocess
import sys

identities_path = Path(sys.argv[1])
team_id, expected_sha256, security, openssl = sys.argv[2:6]
control = Path(sys.argv[6])
tool_environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
fixture_log = os.environ.get("UTTERINK_FIXTURE_LOG")
if fixture_log is not None:
    tool_environment["UTTERINK_FIXTURE_LOG"] = fixture_log

def abort() -> None:
    raise SystemExit(1)

def run(arguments: list[str]) -> bytes:
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=tool_environment, check=False)
    if result.returncode != 0 or len(result.stdout) > 512 * 1024:
        abort()
    return result.stdout

def fingerprint(data: bytes, length: int) -> str:
    try:
        lines = data.decode("ascii", errors="strict").splitlines()
    except UnicodeError:
        abort()
    matches = []
    for line in lines:
        match = re.fullmatch(r"[A-Za-z0-9-]+ Fingerprint=([0-9A-Fa-f:]+)", line.strip())
        if match is not None:
            value = match.group(1).replace(":", "").lower()
            if len(value) == length and re.fullmatch(r"[0-9a-f]+", value):
                matches.append(value)
    if len(matches) != 1:
        abort()
    return matches[0]

def pem_blocks(data: bytes) -> list[bytes]:
    pattern = re.compile(br"-----BEGIN CERTIFICATE-----\r?\n.*?\r?\n-----END CERTIFICATE-----\r?\n?", re.DOTALL)
    blocks = pattern.findall(data)
    remainder = pattern.sub(b"", data)
    if not blocks or remainder.strip():
        abort()
    return blocks

try:
    identity_lines = identities_path.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    abort()
candidates: list[tuple[str, str]] = []
for line in identity_lines:
    match = re.fullmatch(r'\s*[0-9]+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*', line)
    if match is None:
        continue
    identity_sha1, identity = match.group(1).lower(), match.group(2)
    if (
        identity.startswith("Developer ID Application: ")
        and identity.endswith(f" ({team_id})")
        and len(identity) <= 512
        and not any(ord(c) < 32 or ord(c) == 127 for c in identity)
        and "/" not in identity
    ):
        candidates.append((identity_sha1, identity))
if not candidates:
    abort()

matches: list[tuple[str, str]] = []
certificate_index = 0
for identity_sha1, identity in candidates:
    certificates = run([security, "find-certificate", "-a", "-c", identity, "-p"])
    for certificate in pem_blocks(certificates):
        certificate_index += 1
        certificate_path = control / f"candidate-{certificate_index}.pem"
        descriptor = os.open(certificate_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, certificate)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        sha256 = fingerprint(run([openssl, "x509", "-in", str(certificate_path), "-noout", "-fingerprint", "-sha256"]), 64)
        if sha256 != expected_sha256:
            continue
        sha1 = fingerprint(run([openssl, "x509", "-in", str(certificate_path), "-noout", "-fingerprint", "-sha1"]), 40)
        if sha1 != identity_sha1:
            abort()
        try:
            subject_lines = run([
                openssl, "x509", "-in", str(certificate_path), "-noout", "-subject", "-nameopt", "sep_multiline,lname,space_eq",
            ]).decode("utf-8", errors="strict").splitlines()
        except UnicodeError:
            abort()
        common_names = []
        team_ids = []
        for line in subject_lines:
            stripped = line.strip()
            if stripped.startswith("commonName = "):
                common_names.append(stripped.removeprefix("commonName = "))
            elif stripped.startswith("organizationalUnitName = "):
                team_ids.append(stripped.removeprefix("organizationalUnitName = "))
        if common_names != [identity] or team_ids != [team_id]:
            abort()
        run([security, "verify-cert", "-c", str(certificate_path), "-p", "codeSign"])
        run([openssl, "x509", "-in", str(certificate_path), "-checkend", "0", "-noout"])
        matches.append((identity_sha1, identity))
if len(matches) != 1:
    abort()
PY
then
  fail identity-binding-failed 24
fi

if ! "$XCRUN" notarytool --version > "$CONTROL/current-notarytool-version.txt" 2> "$CONTROL/tool-error.txt"; then
  fail notarytool-unavailable 25
fi
if ! /usr/bin/python3 -I - "$CONTROL/current-notarytool-version.txt" "$RECEIPT_NOTARYTOOL_VERSION" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if len(lines) != 1 or lines[0] != sys.argv[2]:
        raise ValueError
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
then
  fail notarytool-version-mismatch 25
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

exit 0
