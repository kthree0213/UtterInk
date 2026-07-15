#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_SIGNATURE_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'signature verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_SIGNATURE_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C UTTERINK_SIGNATURE_ENV_CLEAN=1)
  for allowed_name in \
    UTTERINK_SIGNING_TEST_MODE UTTERINK_SIGNING_TEST_TOOL_ROOT \
    UTTERINK_SIGNING_TEST_SCENARIO UTTERINK_FIXTURE_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'signature verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'signature verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_SIGNATURE_ENV_CLEAN|UTTERINK_SIGNING_TEST_MODE|UTTERINK_SIGNING_TEST_TOOL_ROOT|UTTERINK_SIGNING_TEST_SCENARIO|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *) printf 'signature verification error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_SIGNATURE_ENV_CLEAN

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
  printf 'signature verification error: %s\n' "$category" >&2
  exit "$status"
}

CANDIDATE_ARGUMENT=''
IDENTITY=''
TEAM_ID=''
OUTPUT_ARGUMENT=''
EXPECTED_CERTIFICATE_SHA256=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --candidate)
      [[ -z "$CANDIDATE_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      CANDIDATE_ARGUMENT="$2"; shift 2 ;;
    --identity)
      [[ -z "$IDENTITY" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      IDENTITY="$2"; shift 2 ;;
    --team-id)
      [[ -z "$TEAM_ID" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      TEAM_ID="$2"; shift 2 ;;
    --output)
      [[ -z "$OUTPUT_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      OUTPUT_ARGUMENT="$2"; shift 2 ;;
    --expected-certificate-sha256)
      [[ -z "$EXPECTED_CERTIFICATE_SHA256" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      EXPECTED_CERTIFICATE_SHA256="$2"; shift 2 ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$CANDIDATE_ARGUMENT" && -n "$IDENTITY" && -n "$TEAM_ID" && -n "$OUTPUT_ARGUMENT" && \
  "$EXPECTED_CERTIFICATE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail invalid-arguments 2
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail invalid-team-id 2
[[ "$IDENTITY" == 'Developer ID Application: '* && "$IDENTITY" == *" ($TEAM_ID)" ]] || fail invalid-identity 2
[[ "${#IDENTITY}" -le 512 ]] || fail invalid-identity 2
case "$IDENTITY" in *$'\n'*|*$'\r'*|*$'\t'*|*'/'*) fail invalid-identity 2 ;; esac

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path 20
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" || fail unsafe-script-path 20
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)" || fail unsafe-script-path 20
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail not-a-repository 20
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail not-a-repository 20
[[ "$GIT_ROOT" == "$ROOT" ]] || fail repository-mismatch 20
cd "$ROOT"

TEST_MODE=0
case "${UTTERINK_SIGNING_TEST_MODE:-}" in '') ;; 1) TEST_MODE=1 ;; *) fail invalid-test-mode 20 ;; esac
if [[ "$TEST_MODE" -eq 1 ]]; then
  if ! /usr/bin/python3 -I - "$ROOT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os, stat, sys
root = Path(sys.argv[1])
try:
    metadata = os.lstat(root); git_metadata = os.lstat(root / ".git")
    marker = root / ".utterink-signature-test-repository"; marker_metadata = os.lstat(marker)
    if (root != Path(os.path.abspath(root)) or not root.as_posix().startswith("/private/tmp/")
        or root.is_symlink() or root.resolve(strict=True) != root
        or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022
        or not stat.S_ISDIR(git_metadata.st_mode) or stat.S_ISLNK(git_metadata.st_mode)
        or git_metadata.st_uid != os.geteuid() or git_metadata.st_mode & 0o022
        or not stat.S_ISREG(marker_metadata.st_mode) or stat.S_ISLNK(marker_metadata.st_mode)
        or marker_metadata.st_uid != os.geteuid() or marker_metadata.st_mode & 0o022
        or marker.read_bytes() != b"utterink-signature-test-repository-v1\n"):
        raise ValueError
except (OSError, ValueError): raise SystemExit(1)
PY
  then fail invalid-test-repository 20; fi
  TOOL_ROOT="${UTTERINK_SIGNING_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" ]] || fail invalid-test-tool-root 20
  if ! /usr/bin/python3 -I - "$TOOL_ROOT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os, stat, sys
root = Path(sys.argv[1])
try:
    metadata = os.lstat(root); marker = root / ".utterink-signature-test-tools"; mm = os.lstat(marker)
    if (root != Path(os.path.abspath(root)) or root.is_symlink() or root.resolve(strict=True) != root
        or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022
        or not stat.S_ISREG(mm.st_mode) or stat.S_ISLNK(mm.st_mode) or mm.st_uid != os.geteuid()
        or mm.st_mode & 0o022 or marker.read_bytes() != b"utterink-signature-test-tools-v1\n"):
        raise ValueError
    for name in ("file", "lipo", "codesign", "security", "openssl"):
        item = os.lstat(root / name)
        if (not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid != os.geteuid()
            or item.st_mode & 0o022 or not item.st_mode & stat.S_IXUSR): raise ValueError
except (OSError, ValueError): raise SystemExit(1)
PY
  then fail invalid-test-tool-root 20; fi
  [[ "${UTTERINK_FIXTURE_LOG:-}" == /private/tmp/* ]] || fail invalid-test-tool-root 20
  FILE_TOOL="$TOOL_ROOT/file"; LIPO="$TOOL_ROOT/lipo"; CODESIGN="$TOOL_ROOT/codesign"
  SECURITY="$TOOL_ROOT/security"; OPENSSL="$TOOL_ROOT/openssl"
else
  unset UTTERINK_SIGNING_TEST_MODE UTTERINK_SIGNING_TEST_TOOL_ROOT UTTERINK_SIGNING_TEST_SCENARIO UTTERINK_FIXTURE_LOG
  FILE_TOOL=/usr/bin/file; LIPO=/usr/bin/lipo; CODESIGN=/usr/bin/codesign
  SECURITY=/usr/bin/security; OPENSSL=/usr/bin/openssl
fi
for tool in "$FILE_TOOL" "$LIPO" "$CODESIGN" "$SECURITY" "$OPENSSL"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail signing-tool-unavailable 20
done
readonly TEST_MODE FILE_TOOL LIPO CODESIGN SECURITY OPENSSL

[[ -d /private/tmp && ! -L /private/tmp ]] || fail temporary-directory-unavailable 20
CONTROL="$(/usr/bin/mktemp -d /private/tmp/utterink-verify-signatures.XXXXXX)" || fail temporary-directory-unavailable 20
[[ "$CONTROL" == /private/tmp/utterink-verify-signatures.* && -d "$CONTROL" && ! -L "$CONTROL" ]] || fail temporary-directory-unavailable 20
/bin/chmod 0700 "$CONTROL" || fail temporary-directory-unavailable 20
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$CONTROL" == /private/tmp/utterink-verify-signatures.* && -d "$CONTROL" && ! -L "$CONTROL" ]]; then
    /bin/rm -rf -- "$CONTROL"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "${UTTERINK_SIGNING_TEST_SCENARIO:-}" in
  verify-signal-hup|verify-signal-int|verify-signal-term)
    : > "${UTTERINK_FIXTURE_LOG}.${UTTERINK_SIGNING_TEST_SCENARIO}.ready"
    while :; do /bin/sleep 0.01; done ;;
esac

if ! /usr/bin/python3 -I - "$ROOT" "$CANDIDATE_ARGUMENT" "$OUTPUT_ARGUMENT" "$CONTROL/paths" <<'PY' >/dev/null 2>&1
from pathlib import Path, PurePath
import json, os, stat, sys
root, candidate_raw, output_raw, destination = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
def checked_text(value):
    if (not value or len(value.encode("utf-8", errors="strict")) > 4096
        or any(ord(c) < 32 or ord(c) == 127 for c in value) or ".." in PurePath(value).parts): raise ValueError
def checked_directory(path, device):
    item = os.lstat(path)
    if (not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_dev != device
        or item.st_uid != os.geteuid() or item.st_mode & 0o022): raise ValueError
try:
    checked_text(candidate_raw); checked_text(output_raw)
    candidate = Path(os.path.abspath(Path(candidate_raw) if os.path.isabs(candidate_raw) else root / candidate_raw))
    output = Path(os.path.abspath(Path(output_raw) if os.path.isabs(output_raw) else root / output_raw))
    relative = candidate.relative_to(root)
    if len(relative.parts) < 2 or relative.parts[0] != ".release-work": raise ValueError
    root_item = os.lstat(root); current = root
    for part in relative.parts: current /= part; checked_directory(current, root_item.st_dev)
    for name, kind in (("UtterInk.app", "dir"), ("candidate.json", "file"), ("unsigned-build-evidence.json", "file")):
        item = os.lstat(candidate / name)
        valid_kind = stat.S_ISDIR(item.st_mode) if kind == "dir" else stat.S_ISREG(item.st_mode)
        if (not valid_kind or stat.S_ISLNK(item.st_mode) or item.st_dev != root_item.st_dev
            or item.st_uid != os.geteuid() or item.st_mode & 0o022
            or (kind == "file" and item.st_nlink != 1)): raise ValueError
    if os.path.lexists(output) or output.parent != candidate: raise ValueError
    destination.write_text(json.dumps({"candidate": str(candidate), "output": str(output)}, separators=(",", ":")), encoding="utf-8")
except (OSError, UnicodeError, ValueError): raise SystemExit(1)
PY
then fail unsafe-candidate 21; fi
CANDIDATE="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["candidate"])' "$CONTROL/paths")"
OUTPUT="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["output"])' "$CONTROL/paths")"
APP="$CANDIDATE/UtterInk.app"
readonly CANDIDATE OUTPUT APP

# Parse the complete candidate contract, bind it to HEAD, bind the release policy
# and this verifier to commit blobs/current bytes, and validate canonical unsigned evidence.
if ! /usr/bin/python3 -I - \
  "$ROOT" "$CANDIDATE/candidate.json" "$CANDIDATE/unsigned-build-evidence.json" \
  "$TEST_MODE" "$CONTROL/candidate-meta.json" "$CONTROL/repository-binding.json" <<'PY' >/dev/null 2>&1
from __future__ import annotations
from pathlib import Path
import hashlib, json, os, re, stat, subprocess, sys
root, candidate_path, unsigned_path = map(Path, sys.argv[1:4]); test_mode = sys.argv[4] == "1"
meta_path, binding_path = map(Path, sys.argv[5:7]); MAX = 512 * 1024
def abort(): raise SystemExit(1)
def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value: abort()
        value[key] = item
    return value
def exact(value, keys):
    if type(value) is not dict or set(value) != keys: abort()
    return value
def pattern(value, regex):
    if type(value) is not str or re.fullmatch(regex, value) is None: abort()
    return value
def fp(item):
    return [item.st_dev,item.st_ino,item.st_mode,item.st_uid,item.st_nlink,item.st_size,item.st_mtime_ns,item.st_ctime_ns]
def read_regular(path, maximum=MAX):
    before = os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_nlink != 1
        or before.st_uid != os.geteuid() or before.st_mode & 0o022 or before.st_size > maximum): abort()
    fd = os.open(path, os.O_RDONLY | getattr(os,"O_CLOEXEC",0) | getattr(os,"O_NOFOLLOW",0))
    try:
        opened = os.fstat(fd); chunks=[]; total=0
        while True:
            chunk=os.read(fd,65536)
            if not chunk: break
            total += len(chunk)
            if total > maximum: abort()
            chunks.append(chunk)
        after=os.fstat(fd)
    finally: os.close(fd)
    if fp(before) != fp(opened) or fp(opened) != fp(after): abort()
    return b"".join(chunks), before
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def git(*args):
    result=subprocess.run(["/usr/bin/git","-C",str(root),*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,check=False)
    if result.returncode: abort()
    return result.stdout
def blob(relative, commit):
    listing=git("ls-tree","-z",commit,"--",relative)
    if not listing.endswith(b"\0") or listing.count(b"\0") != 1: abort()
    try:
        header, name=listing[:-1].split(b"\t",1); mode,kind,oid=header.split(b" ",2)
        if name.decode("utf-8",errors="strict") != relative: abort()
    except (ValueError,UnicodeError): abort()
    if mode not in {b"100644",b"100755"} or kind != b"blob": abort()
    data=git("cat-file","blob",oid.decode("ascii"))
    if len(data)>MAX: abort()
    return data
try:
    candidate_raw,_=read_regular(candidate_path,256*1024)
    top=json.loads(candidate_raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    top=exact(top,{"schemaVersion","evidenceType","product","source","release","toolchain","packageResolution","policies","checks"})
    if type(top["schemaVersion"]) is not int or top["schemaVersion"] != 1: abort()
    if top["evidenceType"] != ("release-candidate-test" if test_mode else "release-candidate") or type(top["evidenceType"]) is not str: abort()
    if top["product"] != "UtterInk" or type(top["product"]) is not str: abort()
    source=exact(top["source"],{"commit","tree","releaseTag","clean"}); commit=pattern(source["commit"],r"[0-9a-f]{40}")
    tree=pattern(source["tree"],r"[0-9a-f]{40}")
    if source["releaseTag"] != "v0.1.0" or type(source["releaseTag"]) is not str or source["clean"] is not True: abort()
    if git("rev-parse","--verify","HEAD^{commit}").strip().decode() != commit: abort()
    if git("rev-parse",f"{commit}^{{tree}}").strip().decode() != tree: abort()
    release=exact(top["release"],{"configuration","marketingVersion","buildNumber","bundleIdentifier","deploymentTarget","architecture","dmgFilename"})
    expected={"configuration":"Release","marketingVersion":"0.1.0","buildNumber":"1","bundleIdentifier":"dev.utterink.UtterInk","deploymentTarget":"14.0","architecture":"arm64","dmgFilename":"UtterInk-0.1.0-arm64.dmg"}
    if release != expected or any(type(item) is not str for item in release.values()): abort()
    toolchain=exact(top["toolchain"],{"lockSHA256","xcodeVersion","xcodeBuild","sdkVersion","sdkBuild","swiftVersion","xcodegenVersion","xcodegenBinarySHA256"})
    pattern(toolchain["lockSHA256"],r"[0-9a-f]{64}"); pattern(toolchain["xcodegenBinarySHA256"],r"[0-9a-f]{64}")
    if (toolchain["xcodeVersion"] != "26.4.1" or toolchain["xcodeBuild"] != "17E202" or toolchain["sdkVersion"] != "26.4"
        or toolchain["xcodegenVersion"] != "2.45.4" or any(type(toolchain[k]) is not str for k in ("xcodeVersion","xcodeBuild","sdkVersion","xcodegenVersion"))): abort()
    pattern(toolchain["sdkBuild"],r"[0-9]{2}[A-Z][0-9]{1,4}[a-z]?")
    pattern(toolchain["swiftVersion"],r"(?:swift-driver version: [0-9]+(?:\.[0-9]+)* )?Apple Swift version 6\.3(?:\.[0-9]+)* \(swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+\)")
    package=exact(top["packageResolution"],{"path","sha256"})
    if package["path"] != "Packages/UtterInkKit/Package.resolved" or type(package["path"]) is not str: abort()
    pattern(package["sha256"],r"[0-9a-f]{64}")
    policies=exact(top["policies"],{"releaseMetadataSHA256","releaseEntitlementsSHA256","releaseInfoPolicySHA256","ciToolchainSHA256"})
    for item in policies.values(): pattern(item,r"[0-9a-f]{64}")
    checks=exact(top["checks"],{"history","metadata","entitlements","infoPolicy","packageResolution","generatedProjectClean"})
    if any(item is not True for item in checks.values()): abort()
    paths=("Config/release-entitlements.json","Scripts/release/verify-signatures.sh")
    records={}
    for relative in paths:
        expected_blob=blob(relative,commit); current,item=read_regular(root/relative)
        if current != expected_blob: abort()
        records[relative]={"sha256":hashlib.sha256(current).hexdigest(),"fingerprint":fp(item)}
    if records[paths[0]]["sha256"] != policies["releaseEntitlementsSHA256"]: abort()
    unsigned_raw,_=read_regular(unsigned_path,64*1024)
    unsigned=json.loads(unsigned_raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    unsigned=exact(unsigned,{"appTreeSHA256","archiveTreeSHA256","candidateCommit","candidateJSONSHA256","evidenceType","product","schemaVersion","status","treeAlgorithm"})
    canonical=(json.dumps(unsigned,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode("utf-8")
    candidate_hash=hashlib.sha256(candidate_raw).hexdigest()
    if unsigned_raw != canonical or type(unsigned["schemaVersion"]) is not int or unsigned["schemaVersion"] != 1: abort()
    if (unsigned["evidenceType"] != "unsigned-build" or type(unsigned["evidenceType"]) is not str
        or unsigned["product"] != "UtterInk" or type(unsigned["product"]) is not str
        or unsigned["status"] != "valid" or type(unsigned["status"]) is not str
        or unsigned["treeAlgorithm"] != "utterink-logical-tree-v1" or type(unsigned["treeAlgorithm"]) is not str
        or unsigned["candidateCommit"] != commit or unsigned["candidateJSONSHA256"] != candidate_hash): abort()
    pattern(unsigned["candidateCommit"],r"[0-9a-f]{40}")
    for key in ("appTreeSHA256","archiveTreeSHA256","candidateJSONSHA256"): pattern(unsigned[key],r"[0-9a-f]{64}")
    meta={"candidateCommit":commit,"candidateJSONSHA256":candidate_hash,"unsignedBuildEvidenceSHA256":hashlib.sha256(canonical).hexdigest()}
    meta_path.write_text(json.dumps(meta,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
    binding_path.write_text(json.dumps(records,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
except (OSError,UnicodeError,ValueError,json.JSONDecodeError): abort()
PY
then fail invalid-candidate-evidence 22; fi

SOURCE_COMMIT="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["candidateCommit"])' "$CONTROL/candidate-meta.json")"
readonly SOURCE_COMMIT

assert_repository_binding() {
  /usr/bin/python3 -I - "$ROOT" "$SOURCE_COMMIT" "$CONTROL/repository-binding.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import hashlib,json,os,stat,subprocess,sys
root,commit,binding_path=Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3])
def abort(): raise SystemExit(1)
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def git(*args):
    value=subprocess.run(["/usr/bin/git","-C",str(root),*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
    if value.returncode: abort()
    return value.stdout
try:
    binding=json.loads(binding_path.read_text(encoding="utf-8"))
    for relative in ("Config/release-entitlements.json","Scripts/release/verify-signatures.sh"):
        record=binding[relative]; path=root/relative; before=os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.geteuid() or before.st_mode & 0o022: abort()
        fd=os.open(path,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
        try:
            opened=os.fstat(fd); chunks=[]
            while True:
                chunk=os.read(fd,65536)
                if not chunk: break
                chunks.append(chunk)
            after=os.fstat(fd)
        finally: os.close(fd)
        fp=lambda x:[x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns]
        if fp(before)!=record["fingerprint"] or fp(opened)!=record["fingerprint"] or fp(after)!=record["fingerprint"]: abort()
        data=b"".join(chunks)
        listing=git("ls-tree","-z",commit,"--",relative)
        if not listing.endswith(b"\0") or listing.count(b"\0") != 1: abort()
        header,name=listing[:-1].split(b"\t",1); mode,kind,oid=header.split(b" ",2)
        if name.decode()!=relative or kind!=b"blob" or mode not in {b"100644",b"100755"}: abort()
        if data!=git("cat-file","blob",oid.decode()) or hashlib.sha256(data).hexdigest()!=record["sha256"]: abort()
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): abort()
PY
}
assert_repository_binding || fail repository-binding-mismatch 22

snapshot_tree() {
  local destination="$1"
  /usr/bin/python3 -I - "$APP" "$destination" <<'PY' >/dev/null 2>&1
from pathlib import Path, PurePosixPath
import hashlib,json,os,stat,sys
root,destination=Path(sys.argv[1]),Path(sys.argv[2])
def abort(): raise SystemExit(1)
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns]
def safe_target(relative,target):
    value=PurePosixPath(target)
    if (not target or len(target.encode("utf-8",errors="strict"))>4096 or value.is_absolute()
        or any(ord(c)<32 or ord(c)==127 for c in target) or ".." in value.parts
        or ".." in PurePosixPath(relative).parent.joinpath(value).parts): abort()
    return target
try:
    root_before=os.lstat(root)
    if not stat.S_ISDIR(root_before.st_mode) or stat.S_ISLNK(root_before.st_mode) or root_before.st_uid!=os.geteuid() or root_before.st_mode&0o022: abort()
    root_fd=os.open(root,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
    root_open=os.fstat(root_fd)
    if fp(root_before)!=fp(root_open): abort()
    logical=[]; physical=[]
    def walk(fd,prefix):
        for name in sorted(os.listdir(fd),key=os.fsencode):
            raw=os.fsencode(name)
            if not name or b"/" in raw or any(b<32 or b==127 for b in raw): abort()
            relative=f"{prefix}/{name}" if prefix else name
            item=os.stat(name,dir_fd=fd,follow_symlinks=False)
            if item.st_dev!=root_open.st_dev or item.st_uid!=os.geteuid(): abort()
            mode=stat.S_IMODE(item.st_mode)
            if stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
                if item.st_mode&0o022: abort()
                child=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=fd)
                opened=os.fstat(child)
                if fp(opened)!=fp(item): os.close(child); abort()
                logical.append([relative,"directory",mode,""]); physical.append([relative,"directory",fp(item),""])
                walk(child,relative); after=os.fstat(child); os.close(child)
                if fp(after)!=fp(item): abort()
            elif stat.S_ISREG(item.st_mode):
                if item.st_mode&0o022 or item.st_nlink!=1: abort()
                child=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=fd); opened=os.fstat(child)
                digest=hashlib.sha256()
                while True:
                    chunk=os.read(child,65536)
                    if not chunk: break
                    digest.update(chunk)
                after=os.fstat(child); os.close(child)
                if fp(item)!=fp(opened) or fp(opened)!=fp(after): abort()
                payload=digest.hexdigest(); logical.append([relative,"file",mode,payload]); physical.append([relative,"file",fp(item),payload])
            elif stat.S_ISLNK(item.st_mode):
                payload=safe_target(relative,os.readlink(name,dir_fd=fd)); logical.append([relative,"symlink",mode,payload]); physical.append([relative,"symlink",fp(item),payload])
            else: abort()
    walk(root_fd,""); root_after=os.fstat(root_fd); os.close(root_fd)
    if fp(root_after)!=fp(root_before): abort()
    logical.sort(key=lambda x:x[0].encode("utf-8")); physical.sort(key=lambda x:x[0].encode("utf-8"))
    stable=hashlib.sha256(); physical_hash=hashlib.sha256(json.dumps(fp(root_before),separators=(",",":")).encode())
    for record in logical: stable.update((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8"))
    for record in physical: physical_hash.update((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8"))
    destination.write_text(json.dumps({"physicalSHA256":physical_hash.hexdigest(),"treeSHA256":stable.hexdigest()},sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
except (OSError,UnicodeError,ValueError): abort()
PY
}
snapshot_tree "$CONTROL/app-baseline.json" || fail invalid-candidate 24
assert_app_unchanged() {
  snapshot_tree "$CONTROL/app-current.json" || return 1
  /usr/bin/cmp -s "$CONTROL/app-baseline.json" "$CONTROL/app-current.json"
}

# Discover every physical path first; signable discovery is a projection of this
# complete inventory and every external path operation is bracketed by snapshots.
if ! /usr/bin/python3 -I - "$APP" "$CONTROL/discovery.bin" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
app,output=Path(sys.argv[1]),Path(sys.argv[2]); suffixes={".app",".appex",".xpc",".bundle",".plugin",".framework"}
def abort(): raise SystemExit(1)
try:
    root=os.lstat(app); fd=os.open(app,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
    records=[(b"bundle",b"UtterInk.app")]
    def walk(directory,prefix):
        for name in sorted(os.listdir(directory),key=os.fsencode):
            relative=f"{prefix}/{name}" if prefix else name; raw=("UtterInk.app/"+relative).encode("utf-8",errors="strict")
            if any(b<32 or b==127 for b in raw): abort()
            item=os.stat(name,dir_fd=directory,follow_symlinks=False)
            if stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
                child=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=directory)
                path=Path(name)
                if path.suffix in suffixes:
                    if path.suffix != ".framework": os.close(child); abort()
                    records.append((b"bundle",raw))
                walk(child,relative); os.close(child)
            elif stat.S_ISREG(item.st_mode): records.append((b"file",raw))
            elif stat.S_ISLNK(item.st_mode): records.append((b"symlink",raw))
            else: abort()
    walk(fd,""); os.close(fd)
    with output.open("wb") as stream:
        for kind,path in records: stream.write(kind+b"\0"+path+b"\0")
except (OSError,UnicodeError,ValueError): abort()
PY
then fail invalid-candidate 24; fi
assert_app_unchanged || fail candidate-mutated 24

: > "$CONTROL/components.unsorted"
assert_app_unchanged || fail candidate-mutated 24
while IFS= read -r -d '' discovered_kind && IFS= read -r -d '' relative_path; do
  absolute_path="$CANDIDATE/$relative_path"
  if [[ "$discovered_kind" == bundle ]]; then
    printf 'bundle\t%s\n' "$relative_path" >> "$CONTROL/components.unsorted"
  elif [[ "$discovered_kind" == file ]]; then
    "$FILE_TOOL" -b "$absolute_path" > "$CONTROL/file-description" 2> "$CONTROL/tool-error" || fail file-inspection-failed 24
    if /usr/bin/grep -Fq 'Mach-O' "$CONTROL/file-description"; then
      [[ -x "$absolute_path" ]] || fail unexpected-mach-o 24
      printf 'mach-o\t%s\n' "$relative_path" >> "$CONTROL/components.unsorted"
    elif [[ -x "$absolute_path" ]]; then fail unexpected-executable 24; fi
  fi
done < "$CONTROL/discovery.bin"
assert_app_unchanged || fail candidate-mutated 24
/usr/bin/sort -t $'\t' -k2,2 "$CONTROL/components.unsorted" > "$CONTROL/components"
[[ -s "$CONTROL/components" ]] || fail no-signable-components 24
/usr/bin/grep -Fqx $'bundle\tUtterInk.app' "$CONTROL/components" || fail invalid-candidate 24
/usr/bin/grep -Fqx $'mach-o\tUtterInk.app/Contents/MacOS/UtterInk' "$CONTROL/components" || fail invalid-candidate 24
if ! /usr/bin/python3 -I - "$CONTROL/components" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePosixPath
import sys
records=[tuple(line.split("\t",1)) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
if len(records)!=len(set(records)): raise SystemExit(1)
frameworks=[PurePosixPath(p) for k,p in records if k=="bundle" and p.endswith(".framework")]
machos=[PurePosixPath(p) for k,p in records if k=="mach-o"]
for framework in frameworks:
    if len([p for p in machos if framework in p.parents and p.name==framework.stem])!=1: raise SystemExit(1)
PY
then fail invalid-candidate 24; fi

# Extract the actual embedded leaf certificate from the signed outer app.
assert_app_unchanged || fail candidate-mutated 24
if ! "$CODESIGN" -d --extract-certificates "$CONTROL/embedded-leaf-" "$APP" > "$CONTROL/extract.out" 2> "$CONTROL/extract.err"; then
  fail certificate-unavailable 23
fi
assert_app_unchanged || fail candidate-mutated 24
[[ -f "$CONTROL/embedded-leaf-0" && ! -L "$CONTROL/embedded-leaf-0" ]] || fail certificate-unavailable 23
if ! "$OPENSSL" x509 -inform DER -in "$CONTROL/embedded-leaf-0" -out "$CONTROL/certificate.pem" 2> "$CONTROL/tool-error"; then fail certificate-invalid 23; fi
if ! "$SECURITY" verify-cert -c "$CONTROL/certificate.pem" -p codeSign > "$CONTROL/tool-output" 2> "$CONTROL/tool-error"; then fail certificate-untrusted 23; fi
if ! "$OPENSSL" x509 -in "$CONTROL/certificate.pem" -checkend 0 -noout > "$CONTROL/tool-output" 2> "$CONTROL/tool-error"; then fail certificate-expired 23; fi
if ! "$OPENSSL" x509 -in "$CONTROL/certificate.pem" -noout -subject -nameopt sep_multiline -startdate -enddate -fingerprint -sha256 > "$CONTROL/certificate-details" 2> "$CONTROL/tool-error"; then fail certificate-invalid 23; fi
if ! /usr/bin/python3 -I - "$CONTROL/certificate-details" "$IDENTITY" "$TEAM_ID" "$EXPECTED_CERTIFICATE_SHA256" "$CONTROL/certificate.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import json,re,sys
try: lines=Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError,UnicodeError): raise SystemExit(1)
identity,team,expected=sys.argv[2:5]
common=[line.strip().removeprefix("commonName = ") for line in lines if line.strip().startswith("commonName = ")]
units=[line.strip().removeprefix("organizationalUnitName = ") for line in lines if line.strip().startswith("organizationalUnitName = ")]
before=[line.split("=",1)[1].strip() for line in lines if line.startswith("notBefore=")]
after=[line.split("=",1)[1].strip() for line in lines if line.startswith("notAfter=")]
fps=[line.split("Fingerprint=",1)[1].replace(":","").strip().lower() for line in lines if "Fingerprint=" in line]
if common != [identity] or units != [team] or len(before)!=1 or len(after)!=1 or len(fps)!=1 or fps[0]!=expected or re.fullmatch(r"[0-9a-f]{64}",fps[0]) is None: raise SystemExit(1)
if any(not value or len(value)>128 or any(ord(c)<32 or ord(c)==127 for c in value) for value in (before[0],after[0])): raise SystemExit(1)
Path(sys.argv[5]).write_text(json.dumps({"notAfter":after[0],"notBefore":before[0],"sha256":fps[0],"trust":"valid"},sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
PY
then fail certificate-mismatch 23; fi

component_hash() {
  /usr/bin/python3 -I - "$1" "$2" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePosixPath
import hashlib,json,os,stat,sys
path,output=Path(sys.argv[1]),Path(sys.argv[2])
def abort(): raise SystemExit(1)
def target(relative,value):
    p=PurePosixPath(value)
    if not value or p.is_absolute() or ".." in p.parts or ".." in PurePosixPath(relative).parent.joinpath(p).parts: abort()
    return value
def fingerprint(item):
    return [item.st_dev,item.st_ino,item.st_mode,item.st_uid,item.st_nlink,item.st_size,item.st_mtime_ns,item.st_ctime_ns]
def file_hash(fd):
    digest=hashlib.sha256()
    while True:
        chunk=os.read(fd,65536)
        if not chunk: break
        digest.update(chunk)
    return digest.hexdigest()
try:
    item=os.lstat(path)
    if stat.S_ISREG(item.st_mode):
        fd=os.open(path,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); opened=os.fstat(fd); value=file_hash(fd); after=os.fstat(fd); os.close(fd)
        if fingerprint(item)!=fingerprint(opened) or fingerprint(opened)!=fingerprint(after): abort()
        physical=hashlib.sha256(json.dumps(fingerprint(item),separators=(",",":")).encode()).hexdigest()
    elif stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
        root=os.open(path,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); opened_root=os.fstat(root); records=[]; physical_records=[]
        if fingerprint(item)!=fingerprint(opened_root): abort()
        def walk(fd,prefix):
            for name in sorted(os.listdir(fd),key=os.fsencode):
                rel=f"{prefix}/{name}" if prefix else name; meta=os.stat(name,dir_fd=fd,follow_symlinks=False); mode=stat.S_IMODE(meta.st_mode)
                if stat.S_ISDIR(meta.st_mode) and not stat.S_ISLNK(meta.st_mode):
                    child=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=fd); opened=os.fstat(child)
                    if fingerprint(meta)!=fingerprint(opened): os.close(child); abort()
                    records.append([rel,"directory",mode,""]); physical_records.append([rel,"directory",fingerprint(meta),""]); walk(child,rel); after=os.fstat(child); os.close(child)
                    if fingerprint(opened)!=fingerprint(after): abort()
                elif stat.S_ISREG(meta.st_mode):
                    child=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=fd); opened=os.fstat(child); payload=file_hash(child); after=os.fstat(child); os.close(child)
                    if fingerprint(meta)!=fingerprint(opened) or fingerprint(opened)!=fingerprint(after): abort()
                    records.append([rel,"file",mode,payload]); physical_records.append([rel,"file",fingerprint(meta),payload])
                elif stat.S_ISLNK(meta.st_mode):
                    payload=target(rel,os.readlink(name,dir_fd=fd)); records.append([rel,"symlink",mode,payload]); physical_records.append([rel,"symlink",fingerprint(meta),payload])
                else: abort()
        walk(root,""); after_root=os.fstat(root); os.close(root)
        if fingerprint(opened_root)!=fingerprint(after_root): abort()
        records.sort(key=lambda x:x[0].encode("utf-8")); physical_records.sort(key=lambda x:x[0].encode("utf-8")); digest=hashlib.sha256(); physical_digest=hashlib.sha256(json.dumps(fingerprint(item),separators=(",",":")).encode())
        for record in records: digest.update((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8"))
        for record in physical_records: physical_digest.update((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8"))
        value=digest.hexdigest(); physical=physical_digest.hexdigest()
    else: abort()
    output.write_text(json.dumps({"physicalSHA256":physical,"sha256":value},sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
except (OSError,UnicodeError,ValueError): abort()
PY
}

: > "$CONTROL/components.jsonl"
component_index=0
while IFS=$'\t' read -r component_kind relative_path; do
  [[ -n "$component_kind" && -n "$relative_path" ]] || fail invalid-candidate 24
  component="$CANDIDATE/$relative_path"; component_index=$((component_index+1)); prefix="$CONTROL/component-$component_index"
  component_hash "$component" "$prefix.before-record" || fail component-hash-failed 25
  "$CODESIGN" --verify --strict --verbose=4 "$component" > "$prefix.verify.out" 2> "$prefix.verify.err" || fail signature-invalid 25
  "$CODESIGN" -d --verbose=4 "$component" > "$prefix.metadata.out" 2> "$prefix.metadata.err" || fail signature-metadata-invalid 25
  "$CODESIGN" -d --verbose=4 --entitlements :- "$component" > "$prefix.entitlements" 2> "$prefix.entitlements.err" || fail signature-entitlements-invalid 25
  "$CODESIGN" -d -r- "$component" > "$prefix.requirement.out" 2> "$prefix.requirement.err" || fail signature-requirement-invalid 25
  architecture=''
  if [[ "$component_kind" == mach-o ]]; then
    "$LIPO" -archs "$component" > "$prefix.architecture" 2> "$prefix.architecture.err" || fail architecture-invalid 25
    architecture="$(/bin/cat "$prefix.architecture")"; [[ "$architecture" == arm64 ]] || fail architecture-invalid 25
  fi
  component_hash "$component" "$prefix.after-record" || fail component-hash-failed 25
  /usr/bin/cmp -s "$prefix.before-record" "$prefix.after-record" || fail candidate-mutated 25
  /usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha256"],end="")' "$prefix.after-record" > "$prefix.sha256"
  role=nested
  if [[ "$relative_path" == UtterInk.app || "$relative_path" == UtterInk.app/Contents/MacOS/UtterInk ]]; then role=app; fi
  if ! /usr/bin/python3 -I - "$component_kind" "$relative_path" "$architecture" "$role" "$IDENTITY" "$TEAM_ID" \
    "$prefix.metadata.err" "$prefix.entitlements" "$prefix.requirement.err" "$prefix.sha256" "$CONTROL/components.jsonl" <<'PY' >/dev/null 2>&1
from pathlib import Path
import json,plistlib,re,sys
kind,relative,architecture,role,identity,team=sys.argv[1:7]; metadata_path,entitlement_path,requirement_path,hash_path,output_path=map(Path,sys.argv[7:12])
try:
    metadata=metadata_path.read_text(encoding="utf-8").splitlines(); requirement=requirement_path.read_text(encoding="utf-8").strip(); raw=entitlement_path.read_bytes()
    authorities=[line.split("=",1)[1] for line in metadata if line.startswith("Authority=")]
    teams=[line.split("=",1)[1] for line in metadata if line.startswith("TeamIdentifier=")]
    identifiers=[line.split("=",1)[1] for line in metadata if line.startswith("Identifier=")]
    timestamps=[line.split("=",1)[1] for line in metadata if line.startswith("Timestamp=")]
    if (not authorities or authorities[0]!=identity or authorities.count(identity)!=1 or teams!=[team] or len(identifiers)!=1
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}",identifiers[0]) is None or len(timestamps)!=1 or not timestamps[0]
        or not any(line.startswith("Runtime Version=") for line in metadata) or not any("(runtime)" in line for line in metadata)): raise ValueError
    if role=="app" and identifiers[0]!="dev.utterink.UtterInk": raise ValueError
    identifier_match=re.search(r'(?:^|\s)identifier\s+"([^"]+)"',requirement)
    ou_match=re.search(r'certificate leaf\[subject[.]OU\]\s*=\s*"([^"]+)"',requirement)
    if "designated =>" not in requirement or identifier_match is None or identifier_match.group(1)!=identifiers[0] or ou_match is None or ou_match.group(1)!=team: raise ValueError
    if role=="nested" and raw==b"": entitlements={}
    else: entitlements=plistlib.loads(raw)
    expected={"com.apple.security.device.audio-input":True} if role=="app" else {}
    if entitlements!=expected: raise ValueError
    digest=hash_path.read_text(encoding="ascii")
    if re.fullmatch(r"[0-9a-f]{64}",digest) is None: raise ValueError
    record={"architecture":architecture or None,"designatedRequirement":"valid","entitlements":entitlements,"identifier":identifiers[0],"kind":kind,"path":relative,"runtime":"hardened","secureTimestamp":"present","sha256":digest,"teamID":team,"trust":"valid"}
    with output_path.open("a",encoding="utf-8") as stream: stream.write(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n")
except (OSError,UnicodeError,ValueError,plistlib.InvalidFileException): raise SystemExit(1)
PY
  then fail component-policy-mismatch 25; fi
done < "$CONTROL/components"

assert_app_unchanged || fail candidate-mutated 25
assert_repository_binding || fail repository-binding-mismatch 25
SIGNED_APP_TREE_SHA256="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["treeSHA256"])' "$CONTROL/app-baseline.json")"

if ! /usr/bin/python3 -I - "$CONTROL/candidate-meta.json" "$CONTROL/certificate.json" "$CONTROL/components.jsonl" "$SIGNED_APP_TREE_SHA256" "$TEAM_ID" "$CONTROL/evidence.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import json,re,sys
try:
    meta=json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")); certificate=json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")); components=[json.loads(line) for line in Path(sys.argv[3]).read_text(encoding="utf-8").splitlines()]
    tree,team=sys.argv[4:6]
    if not components or re.fullmatch(r"[0-9a-f]{64}",tree) is None: raise ValueError
    component_keys={"architecture","designatedRequirement","entitlements","identifier","kind","path","runtime","secureTimestamp","sha256","teamID","trust"}
    if any(set(item)!=component_keys or item["teamID"]!=team for item in components): raise ValueError
    paths=[item["path"] for item in components]
    if paths!=sorted(paths,key=lambda value:value.encode("utf-8")) or len(paths)!=len(set(paths)): raise ValueError
    evidence={"candidateCommit":meta["candidateCommit"],"candidateJSONSHA256":meta["candidateJSONSHA256"],"certificate":certificate,"components":components,"evidenceType":"signature-verification","product":"UtterInk","schemaVersion":1,"signedAppTreeSHA256":tree,"status":"valid","teamID":team,"treeAlgorithm":"utterink-logical-tree-v1","unsignedBuildEvidenceSHA256":meta["unsignedBuildEvidenceSHA256"]}
    if set(evidence)!={"candidateCommit","candidateJSONSHA256","certificate","components","evidenceType","product","schemaVersion","signedAppTreeSHA256","status","teamID","treeAlgorithm","unsignedBuildEvidenceSHA256"}: raise ValueError
    encoded=json.dumps(evidence,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n"
    if any(value in encoded for value in ("Developer ID Application","/private/tmp/","/Users/")): raise ValueError
    Path(sys.argv[6]).write_text(encoded,encoding="utf-8")
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): raise SystemExit(1)
PY
then fail evidence-generation-failed 26; fi

if ! /usr/bin/python3 -I - "$OUTPUT" "$CONTROL/evidence.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
output,source=Path(sys.argv[1]),Path(sys.argv[2]); parent_fd=descriptor=-1
try:
    data=source.read_bytes(); parent=os.lstat(output.parent)
    if not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode) or parent.st_uid!=os.geteuid() or parent.st_mode&0o022: raise OSError
    parent_fd=os.open(output.parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
    opened=os.fstat(parent_fd)
    if (opened.st_dev,opened.st_ino)!=(parent.st_dev,parent.st_ino): raise OSError
    descriptor=os.open(output.name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600,dir_fd=parent_fd)
    offset=0
    while offset<len(data): offset+=os.write(descriptor,data[offset:])
    os.fsync(descriptor); os.close(descriptor); descriptor=-1; os.fsync(parent_fd)
except OSError:
    if descriptor>=0: os.close(descriptor)
    try:
        if parent_fd>=0: os.unlink(output.name,dir_fd=parent_fd)
    except OSError: pass
    raise SystemExit(1)
finally:
    if parent_fd>=0: os.close(parent_fd)
PY
then fail evidence-publish-failed 26; fi

exit 0
