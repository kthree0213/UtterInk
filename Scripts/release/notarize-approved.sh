#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_NOTARY_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  printf 'notarization error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_NOTARY_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C UTTERINK_NOTARY_ENV_CLEAN=1)
  for allowed_name in \
    UTTERINK_RELEASE_TEST_MODE UTTERINK_RELEASE_TEST_TOOL_ROOT \
    UTTERINK_RELEASE_TEST_SCENARIO UTTERINK_RELEASE_TEST_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'notarization error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'notarization error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_NOTARY_ENV_CLEAN|UTTERINK_RELEASE_TEST_MODE|UTTERINK_RELEASE_TEST_TOOL_ROOT|UTTERINK_RELEASE_TEST_SCENARIO|UTTERINK_RELEASE_TEST_LOG|PWD|SHLVL|_) ;;
    *) printf 'notarization error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_NOTARY_ENV_CLEAN

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
  local category="$1" status="${2:-1}"
  printf 'notarization error: %s\n' "$category" >&2
  exit "$status"
}

DMG_ARGUMENT=''
APPROVAL_ARGUMENT=''
KEYCHAIN_PROFILE=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ -z "$DMG_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      DMG_ARGUMENT="$2"; shift 2 ;;
    --approval)
      [[ -z "$APPROVAL_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      APPROVAL_ARGUMENT="$2"; shift 2 ;;
    --keychain-profile)
      [[ -z "$KEYCHAIN_PROFILE" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      KEYCHAIN_PROFILE="$2"; shift 2 ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$DMG_ARGUMENT" && -n "$APPROVAL_ARGUMENT" && -n "$KEYCHAIN_PROFILE" ]] || fail invalid-arguments 2
[[ "$KEYCHAIN_PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail invalid-keychain-profile 2

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-script-path 20
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" || fail unsafe-script-path 20
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)" || fail unsafe-script-path 20
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail unsafe-repository 20
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail unsafe-repository 20
[[ "$GIT_ROOT" == "$ROOT" ]] || fail unsafe-repository 20
cd "$ROOT"

TEST_MODE=0
case "${UTTERINK_RELEASE_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode 20 ;;
esac

if [[ "$TEST_MODE" -eq 1 ]]; then
  if ! /usr/bin/python3 -I - "$ROOT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
root=Path(sys.argv[1])
try:
    item=os.lstat(root); git=os.lstat(root/".git"); marker=root/".utterink-notarization-test-repository"; mark=os.lstat(marker)
    if (root!=Path(os.path.abspath(root)) or not root.as_posix().startswith("/private/tmp/") or root.is_symlink()
        or root.resolve(strict=True)!=root or not stat.S_ISDIR(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022
        or not stat.S_ISDIR(git.st_mode) or stat.S_ISLNK(git.st_mode) or git.st_uid!=os.geteuid() or git.st_mode&0o022
        or not stat.S_ISREG(mark.st_mode) or stat.S_ISLNK(mark.st_mode) or mark.st_uid!=os.geteuid() or mark.st_mode&0o022
        or marker.read_bytes()!=b"utterink-notarization-test-repository-v1\n"): raise ValueError
except (OSError,ValueError): raise SystemExit(1)
PY
  then fail invalid-test-repository 20; fi
  TOOL_ROOT="${UTTERINK_RELEASE_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" ]] || fail invalid-test-tool-root 20
  if ! /usr/bin/python3 -I - "$TOOL_ROOT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
root=Path(sys.argv[1])
try:
    item=os.lstat(root); marker=root/".utterink-notarization-test-tools"; mark=os.lstat(marker)
    if (root!=Path(os.path.abspath(root)) or root.is_symlink() or root.resolve(strict=True)!=root
        or not stat.S_ISDIR(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022
        or not stat.S_ISREG(mark.st_mode) or stat.S_ISLNK(mark.st_mode) or mark.st_uid!=os.geteuid() or mark.st_mode&0o022
        or marker.read_bytes()!=b"utterink-notarization-test-tools-v1\n"): raise ValueError
    for name in ("xcrun","shasum","date"):
        tool=os.lstat(root/name)
        if (not stat.S_ISREG(tool.st_mode) or stat.S_ISLNK(tool.st_mode) or tool.st_uid!=os.geteuid()
            or tool.st_mode&0o022 or not tool.st_mode&stat.S_IXUSR): raise ValueError
except (OSError,ValueError): raise SystemExit(1)
PY
  then fail invalid-test-tool-root 20; fi
  [[ "${UTTERINK_RELEASE_TEST_LOG:-}" == "$ROOT"/* && "${UTTERINK_RELEASE_TEST_LOG}" != *$'\n'* ]] || fail invalid-test-log 20
  case "${UTTERINK_RELEASE_TEST_SCENARIO:-accepted}" in accepted|rejected|invalid-log|crash|history-failure|expires-after-history|expires-at-consumption|crash-before-consume|crash-after-consume) ;; *) fail invalid-test-scenario 20 ;; esac
  XCRUN="$TOOL_ROOT/xcrun"
  SHASUM="$TOOL_ROOT/shasum"
  DATE_TOOL="$TOOL_ROOT/date"
else
  unset UTTERINK_RELEASE_TEST_MODE UTTERINK_RELEASE_TEST_TOOL_ROOT UTTERINK_RELEASE_TEST_SCENARIO UTTERINK_RELEASE_TEST_LOG
  XCRUN=/usr/bin/xcrun
  SHASUM=/usr/bin/shasum
  DATE_TOOL=/bin/date
fi
for tool in "$XCRUN" "$SHASUM" "$DATE_TOOL"; do
  [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail required-tool-unavailable 20
done
readonly TEST_MODE XCRUN SHASUM DATE_TOOL ROOT KEYCHAIN_PROFILE

PREPARE="$ROOT/Scripts/release/prepare-notarization-request.py"
VERIFY_PROFILE="$ROOT/Scripts/release/verify-notary-profile-binding.sh"
VERIFY_RESULT="$ROOT/Scripts/release/verify-notarization-result.py"
INSPECT_DMG="$ROOT/Scripts/inspect-dmg.sh"
for script in "$PREPARE" "$VERIFY_PROFILE" "$VERIFY_RESULT" "$INSPECT_DMG"; do
  [[ -f "$script" && ! -L "$script" ]] || fail release-script-unavailable 20
done
[[ -x "$VERIFY_PROFILE" && -x "$INSPECT_DMG" ]] || fail release-script-unavailable 20
readonly PREPARE VERIFY_PROFILE VERIFY_RESULT INSPECT_DMG

[[ -d /private/tmp && ! -L /private/tmp ]] || fail temporary-directory-unavailable 20
CONTROL="$(/usr/bin/mktemp -d /private/tmp/utterink-notarize-approved.XXXXXX)" || fail temporary-directory-unavailable 20
[[ "$CONTROL" == /private/tmp/utterink-notarize-approved.* && -d "$CONTROL" && ! -L "$CONTROL" ]] || fail temporary-directory-unavailable 20
/bin/chmod 0700 "$CONTROL" || fail temporary-directory-unavailable 20
CONSUMED=0
POST_STAPLE=0
WORK=''

write_quarantine_marker() {
  [[ "$POST_STAPLE" -eq 1 && -n "$WORK" ]] || return 0
  /usr/bin/python3 -I - "$WORK/QUARANTINED" <<'PY' >/dev/null 2>&1 || true
import os,sys
try:
    fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    os.write(fd,b'{"reason":"post-staple-verification-failed","status":"unusable"}\n'); os.fsync(fd); os.close(fd)
except OSError: pass
PY
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$status" -ne 0 ]]; then write_quarantine_marker; fi
  if [[ "$CONTROL" == /private/tmp/utterink-notarize-approved.* && -d "$CONTROL" && ! -L "$CONTROL" ]]; then
    /bin/rm -rf -- "$CONTROL"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

NOW="$($DATE_TOOL -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || fail clock-unavailable 20
[[ "$NOW" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail clock-unavailable 20
readonly NOW

run_preflight() {
  local output="$1"
  local current_time="${2:-$NOW}"
  /usr/bin/python3 -I - \
    "$ROOT" "$DMG_ARGUMENT" "$APPROVAL_ARGUMENT" "$KEYCHAIN_PROFILE" \
    "$SHASUM" "$current_time" "$output" <<'PY'
from __future__ import annotations
from datetime import datetime,timezone
from pathlib import Path,PurePath
import hashlib,json,os,re,stat,subprocess,sys

root=Path(sys.argv[1]); dmg_raw=sys.argv[2]; approval_raw=sys.argv[3]; profile=sys.argv[4]
shasum=sys.argv[5]; now_raw=sys.argv[6]; output=Path(sys.argv[7]); MAX_JSON=1024*1024
def abort(): raise SystemExit(1)
def unique(pairs):
    value={}
    for key,item in pairs:
        if key in value: abort()
        value[key]=item
    return value
def exact(value,keys):
    if type(value) is not dict or set(value)!=keys: abort()
    return value
def pattern(value,regex):
    if type(value) is not str or re.fullmatch(regex,value) is None: abort()
    return value
def canonical(value): return (json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode("utf-8")
def fingerprint(item):
    return [item.st_dev,item.st_ino,item.st_mode,item.st_uid,item.st_gid,item.st_nlink,item.st_size,item.st_mtime_ns,item.st_ctime_ns,getattr(item,"st_flags",0)]
def checked_path(raw,first):
    if (not raw or len(raw.encode("utf-8",errors="strict"))>4096 or any(ord(c)<32 or ord(c)==127 for c in raw)
        or not os.path.isabs(raw) or ".." in PurePath(raw).parts): abort()
    path=Path(raw)
    if Path(os.path.abspath(raw))!=path or path.parent.resolve(strict=True)!=path.parent: abort()
    relative=path.relative_to(root)
    if len(relative.parts)<2 or relative.parts[0]!=first: abort()
    current=root; root_item=os.lstat(root)
    for part in relative.parts[:-1]:
        current/=part; item=os.lstat(current)
        if (not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid()
            or item.st_dev!=root_item.st_dev or item.st_mode&0o022): abort()
    return path,relative,root_item
def stable_read(path,mode,maximum=MAX_JSON):
    before=os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
        or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=mode or before.st_size>maximum): abort()
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|getattr(os,"O_CLOEXEC",0)); chunks=[]; total=0
    try:
        opened=os.fstat(fd)
        while True:
            chunk=os.read(fd,65536)
            if not chunk: break
            total+=len(chunk)
            if total>maximum: abort()
            chunks.append(chunk)
        after=os.fstat(fd)
    finally: os.close(fd)
    if fingerprint(before)!=fingerprint(opened) or fingerprint(opened)!=fingerprint(after) or fingerprint(after)!=fingerprint(os.lstat(path)): abort()
    return b"".join(chunks),before
def decode(raw):
    try: value=json.loads(raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    except (UnicodeError,ValueError,json.JSONDecodeError): abort()
    if raw!=canonical(value): abort()
    return value
def parse_time(value,utc_seconds=False):
    expression=(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" if utc_seconds else
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})")
    pattern(value,expression)
    normalized=value[:-1]+"+00:00" if value.endswith("Z") else value
    try: parsed=datetime.fromisoformat(normalized)
    except ValueError: abort()
    if parsed.tzinfo is None or parsed.utcoffset() is None: abort()
    return parsed.astimezone(timezone.utc)
def stable_dmg_hash(path):
    before=os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
        or before.st_nlink!=1 or before.st_mode&0o077 or before.st_size<=0): abort()
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|getattr(os,"O_CLOEXEC",0))
    try:
        opened=os.fstat(fd)
        result=subprocess.run([shasum,"-a","256"],stdin=fd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,check=False,
            env={key:value for key,value in os.environ.items()})
        after=os.fstat(fd)
    finally: os.close(fd)
    final=os.lstat(path)
    if result.returncode or fingerprint(before)!=fingerprint(opened) or fingerprint(opened)!=fingerprint(after) or fingerprint(after)!=fingerprint(final): abort()
    match=re.fullmatch(rb"([0-9a-f]{64})  -\n",result.stdout)
    if match is None: abort()
    return match.group(1).decode(),before
def checked_record_directory(name):
    path=root/name; item=os.lstat(path); root_item=os.lstat(root)
    if (not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid()
        or item.st_dev!=root_item.st_dev or item.st_mode&0o077): abort()
    return path
try:
    dmg,dmg_relative,root_item=checked_path(dmg_raw,".release-work")
    approval,approval_relative,_=checked_path(approval_raw,".release-approvals")
    if "consumed" in approval_relative.parts: abort()
    dmg_hash,dmg_item=stable_dmg_hash(dmg)
    approval_bytes,approval_item=stable_read(approval,0o600)
    approval_value=exact(decode(approval_bytes),{"action","requestID","product","appleTeamID","preStapleDMGSHA256","candidateCommit","profileBindingReceiptSHA256","attempt","approvedAt","expiresAt"})
    if approval_value["action"]!="apple-notarization-upload" or approval_value["product"]!="UtterInk" or type(approval_value["attempt"]) is not int or approval_value["attempt"]!=1: abort()
    request_id=pattern(approval_value["requestID"],r"[0-9a-f]{64}"); team=pattern(approval_value["appleTeamID"],r"[A-Z0-9]{10}")
    commit=pattern(approval_value["candidateCommit"],r"[0-9a-f]{40}"); receipt_digest=pattern(approval_value["profileBindingReceiptSHA256"],r"[0-9a-f]{64}")
    if pattern(approval_value["preStapleDMGSHA256"],r"[0-9a-f]{64}")!=dmg_hash: abort()
    approved=parse_time(approval_value["approvedAt"]); expires=parse_time(approval_value["expiresAt"]); now=parse_time(now_raw,True)
    if approved>now or now>=expires or expires<=approved or (expires-approved).total_seconds()>1800: abort()

    request_directory=checked_record_directory(".release-requests"); matches=[]
    for entry in sorted(os.listdir(request_directory)):
        if not entry.endswith(".json") or entry in (".",".."): abort()
        raw,item=stable_read(request_directory/entry,0o400); value=decode(raw)
        if type(value) is dict and value.get("requestID")==request_id: matches.append((request_directory/entry,raw,item,value))
    if len(matches)!=1: abort()
    request_path,request_bytes,request_item,request=matches[0]
    request=exact(request,{"schemaVersion","requestType","requestID","product","candidateCommit","candidateTree","appleTeamID","profileBindingReceiptSHA256","preStapleDMG","signatureVerification","attempt","statement"})
    if (type(request["schemaVersion"]) is not int or request["schemaVersion"]!=1 or request["requestType"]!="apple-notarization-request"
        or request["product"]!="UtterInk" or type(request["attempt"]) is not int or request["attempt"]!=1
        or request["statement"]!="one upload attempt only; rejection or any file change requires new approval."): abort()
    tree=pattern(request["candidateTree"],r"[0-9a-f]{40}")
    if (request["requestID"]!=request_id or request["appleTeamID"]!=team or request["candidateCommit"]!=commit
        or request["profileBindingReceiptSHA256"]!=receipt_digest): abort()
    dmg_contract=exact(request["preStapleDMG"],{"filename","sizeBytes","sha256"})
    if (dmg_contract["filename"]!=dmg.name or type(dmg_contract["sizeBytes"]) is not int or dmg_contract["sizeBytes"]!=dmg_item.st_size
        or dmg_contract["sha256"]!=dmg_hash): abort()
    signature=exact(request["signatureVerification"],{"evidenceSHA256","status","teamID"})
    if pattern(signature["evidenceSHA256"],r"[0-9a-f]{64}")=="0"*64 or signature["status"]!="valid" or signature["teamID"]!=team: abort()

    receipt_directory=checked_record_directory(".notary-profile-bindings"); receipts=[]
    for entry in sorted(os.listdir(receipt_directory)):
        if not entry.endswith(".json") or entry in (".",".."): abort()
        path=receipt_directory/entry; item=os.lstat(path); mode=stat.S_IMODE(item.st_mode)
        if mode!=0o600: abort()
        raw,item=stable_read(path,mode)
        value=decode(raw)
        if hashlib.sha256(raw).hexdigest()==receipt_digest: receipts.append((path,raw,item,value))
    if len(receipts)!=1: abort()
    receipt_path,receipt_bytes,receipt_item,receipt=receipts[0]
    receipt=exact(receipt,{"schemaVersion","bindingNonce","appleTeamID","signingCertificateSHA256","profileNameSalt","profileNameHashSHA256","notarytoolVersion","validatedAt","expiresAt","selfSHA256"})
    if type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"]!=1 or receipt["appleTeamID"]!=team: abort()
    pattern(receipt["bindingNonce"],r"[0-9a-f]{64}"); pattern(receipt["signingCertificateSHA256"],r"[0-9a-f]{64}")
    salt=pattern(receipt["profileNameSalt"],r"[0-9a-f]{64}"); profile_hash=pattern(receipt["profileNameHashSHA256"],r"[0-9a-f]{64}")
    pattern(receipt["selfSHA256"],r"[0-9a-f]{64}")
    for key in ("bindingNonce","signingCertificateSHA256","profileNameSalt","profileNameHashSHA256","selfSHA256"):
        if receipt[key] in {"0"*64,"f"*64}: abort()
    if (type(receipt["notarytoolVersion"]) is not str or not receipt["notarytoolVersion"]
        or len(receipt["notarytoolVersion"].encode())>256 or any(ord(c)<32 or ord(c)==127 for c in receipt["notarytoolVersion"])): abort()
    validated=parse_time(receipt["validatedAt"],True); receipt_expires=parse_time(receipt["expiresAt"],True)
    if validated>now or now>=receipt_expires or (receipt_expires-validated).total_seconds()!=86400: abort()
    if expires>receipt_expires: abort()
    expected_profile_hash=hashlib.sha256(b"UtterInk-notary-profile-v1\0"+bytes.fromhex(salt)+profile.encode("utf-8",errors="strict")).hexdigest()
    if profile_hash!=expected_profile_hash: abort()
    without_self={key:value for key,value in receipt.items() if key!="selfSHA256"}
    if receipt["selfSHA256"]!=hashlib.sha256(canonical(without_self)).hexdigest(): abort()
    metadata={
        "approval":str(approval),"approvalFingerprint":fingerprint(approval_item),"approvalSHA256":hashlib.sha256(approval_bytes).hexdigest(),
        "candidateCommit":commit,"candidateTree":tree,"dmg":str(dmg),"dmgFingerprint":fingerprint(dmg_item),"dmgSHA256":dmg_hash,
        "receipt":str(receipt_path),"receiptFingerprint":fingerprint(receipt_item),"receiptSHA256":receipt_digest,
        "request":str(request_path),"requestFingerprint":fingerprint(request_item),"requestID":request_id,"teamID":team,
    }
    serialized=canonical(metadata); fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    os.write(fd,serialized); os.fsync(fd); os.close(fd)
except (OSError,UnicodeError,ValueError,KeyError,subprocess.SubprocessError): abort()
PY
}

if ! run_preflight "$CONTROL/preflight.json" >/dev/null 2>&1; then fail approval-or-artifact-invalid 21; fi

read_metadata_field() {
  /usr/bin/python3 -I -c 'import json,sys;value=json.load(open(sys.argv[1],encoding="utf-8"))[sys.argv[2]];print(value)' "$CONTROL/preflight.json" "$1"
}
DMG="$(read_metadata_field dmg)" || fail approval-or-artifact-invalid 21
APPROVAL="$(read_metadata_field approval)" || fail approval-or-artifact-invalid 21
REQUEST="$(read_metadata_field request)" || fail approval-or-artifact-invalid 21
RECEIPT="$(read_metadata_field receipt)" || fail approval-or-artifact-invalid 21
REQUEST_ID="$(read_metadata_field requestID)" || fail approval-or-artifact-invalid 21
TEAM_ID="$(read_metadata_field teamID)" || fail approval-or-artifact-invalid 21
CANDIDATE_COMMIT="$(read_metadata_field candidateCommit)" || fail approval-or-artifact-invalid 21
CANDIDATE_TREE="$(read_metadata_field candidateTree)" || fail approval-or-artifact-invalid 21
PRE_STAPLE_HASH="$(read_metadata_field dmgSHA256)" || fail approval-or-artifact-invalid 21
RECEIPT_HASH="$(read_metadata_field receiptSHA256)" || fail approval-or-artifact-invalid 21
APPROVAL_HASH="$(read_metadata_field approvalSHA256)" || fail approval-or-artifact-invalid 21
readonly DMG APPROVAL REQUEST RECEIPT REQUEST_ID TEAM_ID CANDIDATE_COMMIT CANDIDATE_TREE PRE_STAPLE_HASH RECEIPT_HASH APPROVAL_HASH

verify_repository_bindings() {
  /usr/bin/python3 -I - "$ROOT" "$CANDIDATE_COMMIT" "$CANDIDATE_TREE" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,subprocess,sys
root=Path(sys.argv[1]); commit=sys.argv[2]; expected_tree=sys.argv[3]
paths=(
    "Scripts/release/notarize-approved.sh","Scripts/release/prepare-notarization-request.py",
    "Scripts/release/verify-notary-profile-binding.sh","Scripts/release/verify-notarization-result.py",
    "Scripts/inspect-dmg.sh","Scripts/release/read-metadata.py","Scripts/release/verify-info-policy.py",
    "Config/release-metadata.json","Config/release-info-policy.json","Config/release-entitlements.plist","Config/dmg-allowed-content.txt",
)
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def git(*args):
    result=subprocess.run(["/usr/bin/git","-C",str(root),*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
    if result.returncode: raise ValueError
    return result.stdout
try:
    if git("rev-parse","--verify","HEAD^{commit}").strip().decode()!=commit or git("rev-parse","HEAD^{tree}").strip().decode()!=expected_tree: raise ValueError
    for relative in paths:
        path=root/relative; item=os.lstat(path)
        if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022: raise ValueError
        listing=git("ls-tree","-z",commit,"--",relative)
        if not listing.endswith(b"\0") or listing.count(b"\0")!=1: raise ValueError
        header,name=listing[:-1].split(b"\t",1); mode,kind,oid=header.split(b" ",2)
        if name.decode("utf-8",errors="strict")!=relative or kind!=b"blob" or mode not in {b"100644",b"100755"}: raise ValueError
        if git("cat-file","blob",oid.decode("ascii"))!=path.read_bytes(): raise ValueError
except (OSError,UnicodeError,ValueError): raise SystemExit(1)
PY
}

verify_pinned_inputs() {
  /usr/bin/python3 -I - "$CONTROL/preflight.json" "$SHASUM" <<'PY' >/dev/null 2>&1
import json,os,re,stat,subprocess,sys
metadata=json.load(open(sys.argv[1],encoding="utf-8")); tool=sys.argv[2]
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
def checked(path,expected):
    before=os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
        or before.st_nlink!=1 or fp(before)!=expected): raise ValueError
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd)
    while os.read(fd,65536): pass
    after=os.fstat(fd); os.close(fd); final=os.lstat(path)
    if fp(opened)!=expected or fp(after)!=expected or fp(final)!=expected: raise ValueError
try:
    checked(metadata["request"],metadata["requestFingerprint"]); checked(metadata["receipt"],metadata["receiptFingerprint"])
    path=metadata["dmg"]; expected=metadata["dmgFingerprint"]; before=os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid() or before.st_nlink!=1 or fp(before)!=expected: raise ValueError
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd)
    result=subprocess.run([tool,"-a","256"],stdin=fd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); after=os.fstat(fd); os.close(fd); final=os.lstat(path)
    match=re.fullmatch(rb"([0-9a-f]{64})  -\n",result.stdout)
    if result.returncode or match is None or match.group(1).decode()!=metadata["dmgSHA256"] or fp(opened)!=expected or fp(after)!=expected or fp(final)!=expected: raise ValueError
except (OSError,ValueError,KeyError): raise SystemExit(1)
PY
}

verify_repository_bindings || fail repository-binding-invalid 22
if ! /usr/bin/python3 -I "$PREPARE" validate-approval --request "$REQUEST" --approval "$APPROVAL" \
  > "$CONTROL/approval-validation" 2> "$CONTROL/approval-validation-error"; then
  fail approval-validation-failed 23
fi
if ! /usr/bin/python3 -I - "$CONTROL/approval-validation" "$APPROVAL_HASH" <<'PY' >/dev/null 2>&1
import re,sys
try: raw=open(sys.argv[1],"rb").read()
except OSError: raise SystemExit(1)
if raw!=(sys.argv[2]+"\n").encode() or re.fullmatch(rb"[0-9a-f]{64}\n",raw) is None: raise SystemExit(1)
PY
then fail approval-validation-failed 23; fi
verify_repository_bindings || fail repository-binding-invalid 22
if ! run_preflight "$CONTROL/preflight-recheck.json" >/dev/null 2>&1 || ! /usr/bin/cmp -s "$CONTROL/preflight.json" "$CONTROL/preflight-recheck.json"; then
  fail input-mutated-before-consumption 24
fi

if ! /usr/bin/python3 -I - "$ROOT" "$REQUEST_ID" "$APPROVAL_HASH" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
root=Path(sys.argv[1]); request_id=sys.argv[2]; approval_hash=sys.argv[3]
def checked_optional_directory(path):
    try: item=os.lstat(path)
    except FileNotFoundError: return False
    if not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o077: raise ValueError
    return True
try:
    approvals=root/".release-approvals"
    consumed=approvals/"consumed"
    if checked_optional_directory(consumed) and os.path.lexists(consumed/f"{request_id}-{approval_hash}.json"): raise ValueError
    evidence=root/".release-evidence"
    if checked_optional_directory(evidence):
        notarization=evidence/"notarization"
        if checked_optional_directory(notarization) and os.path.lexists(notarization/request_id): raise ValueError
except (OSError,ValueError): raise SystemExit(1)
PY
then fail approval-already-consumed 25; fi

verify_repository_bindings || fail repository-binding-invalid 22
if ! "$VERIFY_PROFILE" --team-id "$TEAM_ID" --keychain-profile "$KEYCHAIN_PROFILE" \
  --receipt "$RECEIPT" --expected-receipt-sha256 "$RECEIPT_HASH" \
  > "$CONTROL/profile-validation" 2> "$CONTROL/profile-validation-error"; then
  fail profile-binding-invalid 26
fi
[[ ! -s "$CONTROL/profile-validation" ]] || fail profile-binding-invalid 26
verify_repository_bindings || fail repository-binding-invalid 22
NOW_AFTER_PROFILE="$($DATE_TOOL -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || fail clock-unavailable 20
[[ "$NOW_AFTER_PROFILE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail clock-unavailable 20
if ! run_preflight "$CONTROL/profile-verified-recheck.json" "$NOW_AFTER_PROFILE" >/dev/null 2>&1 || \
  ! /usr/bin/cmp -s "$CONTROL/preflight.json" "$CONTROL/profile-verified-recheck.json"; then
  fail input-mutated-before-consumption 24
fi

if ! WORK="$(/usr/bin/python3 -I - "$ROOT" "$CONTROL/preflight.json" "$DATE_TOOL" <<'PY'
from pathlib import Path
from datetime import datetime,timezone
import ctypes,hashlib,json,os,re,stat,subprocess,sys
root=Path(sys.argv[1]); metadata=json.load(open(sys.argv[2],encoding="utf-8")); date_tool=sys.argv[3]; approval=Path(metadata["approval"])
request_id=metadata["requestID"]; approval_hash=metadata["approvalSHA256"]
def abort(): raise SystemExit(1)
def checked_dir(path,create=False):
    if create:
        try: os.mkdir(path,0o700)
        except FileExistsError: pass
    item=os.lstat(path)
    if not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o077: abort()
    return path
def write_new(path,raw):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try: os.write(fd,raw); os.fsync(fd)
    finally: os.close(fd)
try:
    approval_dir=checked_dir(root/".release-approvals")
    consumed_dir=checked_dir(approval_dir/"consumed",True)
    evidence=checked_dir(root/".release-evidence",True); notarization=checked_dir(evidence/"notarization",True)
    destination=consumed_dir/f"{request_id}-{approval_hash}.json"
    if os.path.lexists(destination): abort()
    before=os.lstat(approval)
    if [before.st_dev,before.st_ino,before.st_mode,before.st_uid,before.st_gid,before.st_nlink,before.st_size,before.st_mtime_ns,before.st_ctime_ns,getattr(before,"st_flags",0)]!=metadata["approvalFingerprint"]: abort()
    source_fd=os.open(approval,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(source_fd); source_hash=hashlib.sha256(); source_chunks=[]
    while True:
        chunk=os.read(source_fd,65536)
        if not chunk: break
        source_hash.update(chunk)
        source_chunks.append(chunk)
    after=os.fstat(source_fd); os.close(source_fd)
    if ((opened.st_dev,opened.st_ino,opened.st_mode,opened.st_uid,opened.st_gid,opened.st_nlink,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns,getattr(opened,"st_flags",0))
        !=tuple(metadata["approvalFingerprint"]) or (after.st_dev,after.st_ino,after.st_mode,after.st_uid,after.st_gid,after.st_nlink,after.st_size,after.st_mtime_ns,after.st_ctime_ns,getattr(after,"st_flags",0))
        !=tuple(metadata["approvalFingerprint"]) or source_hash.hexdigest()!=approval_hash): abort()
    approval_value=json.loads(b"".join(source_chunks).decode("utf-8",errors="strict"))
    clock=subprocess.run([date_tool,"-u","+%Y-%m-%dT%H:%M:%SZ"],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,check=False)
    if clock.returncode or re.fullmatch(rb"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\n",clock.stdout) is None: abort()
    def timestamp(value):
        normalized=value[:-1]+"+00:00" if value.endswith("Z") else value
        parsed=datetime.fromisoformat(normalized)
        if parsed.tzinfo is None or parsed.utcoffset() is None: abort()
        return parsed.astimezone(timezone.utc)
    approved=timestamp(approval_value["approvedAt"]); expires=timestamp(approval_value["expiresAt"]); now=timestamp(clock.stdout.decode().strip())
    if approved>now or now>=expires or expires<=approved or (expires-approved).total_seconds()>1800: abort()
    library=ctypes.CDLL(None,use_errno=True)
    rename=library.renameatx_np; rename.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]; rename.restype=ctypes.c_int
    AT_FDCWD=-2; RENAME_EXCL=0x00000004; RENAME_NOFOLLOW_ANY=0x00000010
    work=notarization/request_id
    if os.path.lexists(work): abort()
    if os.environ.get("UTTERINK_RELEASE_TEST_SCENARIO")=="crash-before-consume": os._exit(91)
    if rename(AT_FDCWD,os.fsencode(approval),AT_FDCWD,os.fsencode(destination),RENAME_EXCL|RENAME_NOFOLLOW_ANY)!=0:
        abort()
    if os.path.lexists(approval): abort()
    item=os.lstat(destination)
    if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_nlink!=1 or stat.S_IMODE(item.st_mode)!=0o600: abort()
    fd=os.open(destination,os.O_RDONLY|os.O_NOFOLLOW); named=os.fstat(fd); destination_hash=hashlib.sha256()
    while True:
        chunk=os.read(fd,65536)
        if not chunk: break
        destination_hash.update(chunk)
    final=os.fstat(fd); os.fsync(fd); os.close(fd)
    if ((named.st_dev,named.st_ino)!=(item.st_dev,item.st_ino) or (final.st_dev,final.st_ino)!=(item.st_dev,item.st_ino)
        or destination_hash.hexdigest()!=approval_hash): abort()
    for directory in (approval_dir,consumed_dir):
        fd=os.open(directory,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|os.O_NOFOLLOW); os.fsync(fd); os.close(fd)
    if os.environ.get("UTTERINK_RELEASE_TEST_SCENARIO")=="crash-after-consume": os._exit(92)
    os.mkdir(work,0o700); checked_dir(work)
    for directory in (approval_dir,consumed_dir,work,notarization,evidence):
        fd=os.open(directory,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|os.O_NOFOLLOW); os.fsync(fd); os.close(fd)
    record={"approvalSHA256":approval_hash,"attempt":1,"requestID":request_id,"status":"consumed"}
    write_new(work/"approval-consumed.json",(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n").encode())
    print(work)
except (AttributeError,OSError,ValueError,KeyError): abort()
PY
)"; then fail approval-consumption-failed 25; fi
[[ "$WORK" == "$ROOT/.release-evidence/notarization/$REQUEST_ID" && -d "$WORK" && ! -L "$WORK" ]] || fail approval-consumption-failed 25
CONSUMED=1
readonly WORK

verify_repository_bindings || fail repository-binding-invalid 22
verify_pinned_inputs || fail artifact-mutated-before-submit 27

if ! /usr/bin/python3 -I - "$WORK/attempt-invoked" "$REQUEST_ID" <<'PY' >/dev/null 2>&1
import json,os,sys
raw=(json.dumps({"attempt":1,"requestID":sys.argv[2],"status":"invoked"},sort_keys=True,separators=(",",":"))+"\n").encode()
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(fd,raw); os.fsync(fd); os.close(fd)
PY
then fail evidence-write-failed 28; fi

if ! "$XCRUN" notarytool submit "$DMG" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait \
  --timeout 30m \
  --output-format json \
  > "$CONTROL/submission.json" 2> "$CONTROL/submission-error"; then
  fail notarization-submit-failed 29
fi
/bin/chmod 0600 "$CONTROL/submission.json" || fail evidence-write-failed 28
/bin/mv "$CONTROL/submission.json" "$WORK/submission.json" || fail evidence-write-failed 28

if ! /usr/bin/python3 -I - "$WORK/submission.json" "$CONTROL/submission-state" <<'PY' >/dev/null 2>&1
import json,os,re,sys
def unique(pairs):
    value={}
    for key,item in pairs:
        if key in value: raise ValueError
        value[key]=item
    return value
try:
    raw=open(sys.argv[1],"rb").read()
    if len(raw)>1024*1024: raise ValueError
    value=json.loads(raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    if type(value) is not dict or value.get("status") not in {"Accepted","Invalid","Rejected"}: raise ValueError
    identifier=value.get("id")
    if type(identifier) is not str or re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}",identifier) is None: raise ValueError
    out=(value["status"]+"\n"+identifier.lower()+"\n").encode(); fd=os.open(sys.argv[2],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,out); os.close(fd)
except (OSError,UnicodeError,ValueError,json.JSONDecodeError): raise SystemExit(1)
PY
then fail invalid-submission-result 30; fi
SUBMISSION_STATUS="$(/usr/bin/sed -n '1p' "$CONTROL/submission-state")"
SUBMISSION_ID="$(/usr/bin/sed -n '2p' "$CONTROL/submission-state")"
[[ "$SUBMISSION_STATUS" == Accepted ]] || fail notarization-not-accepted 31
[[ "$SUBMISSION_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || fail invalid-submission-result 30
readonly SUBMISSION_ID

if ! "$XCRUN" notarytool log "$SUBMISSION_ID" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --output-format json \
  > "$CONTROL/notary-log.json" 2> "$CONTROL/notary-log-error"; then
  fail notary-log-unavailable 32
fi
/bin/chmod 0600 "$CONTROL/notary-log.json" || fail evidence-write-failed 28
/bin/mv "$CONTROL/notary-log.json" "$WORK/notary-log.json" || fail evidence-write-failed 28

verify_repository_bindings || fail repository-binding-invalid 22
if ! /usr/bin/python3 -I "$VERIFY_RESULT" \
  --submission "$WORK/submission.json" \
  --log "$WORK/notary-log.json" \
  --expected-dmg-sha256 "$PRE_STAPLE_HASH" \
  --output "$WORK/notarization-result.json" \
  > "$CONTROL/result-stdout" 2> "$CONTROL/result-error"; then
  fail notary-log-review-failed 33
fi
if ! /usr/bin/cmp -s "$CONTROL/result-stdout" "$WORK/notarization-result.json"; then fail notary-log-review-failed 33; fi
verify_repository_bindings || fail repository-binding-invalid 22
verify_pinned_inputs || fail artifact-mutated-before-staple 34

POST_STAPLE=1
if ! "$XCRUN" stapler staple "$DMG" > "$CONTROL/stapler-output" 2> "$CONTROL/stapler-error"; then fail stapler-staple-failed 35; fi
if ! "$XCRUN" stapler validate "$DMG" > "$CONTROL/stapler-validate-output" 2> "$CONTROL/stapler-validate-error"; then fail stapler-validate-failed 36; fi

if ! /usr/bin/python3 -I - "$DMG" "$SHASUM" "$WORK/post-staple.sha256" "$CONTROL/post-staple-fingerprint.json" <<'PY' >/dev/null 2>&1
import json,os,re,stat,subprocess,sys
path=sys.argv[1]; tool=sys.argv[2]; output=sys.argv[3]; state=sys.argv[4]
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
try:
    before=os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid() or before.st_nlink!=1 or before.st_mode&0o077: raise ValueError
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    opened=os.fstat(fd); result=subprocess.run([tool,"-a","256"],stdin=fd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); after=os.fstat(fd); os.close(fd); final=os.lstat(path)
    if result.returncode or fp(before)!=fp(opened) or fp(opened)!=fp(after) or fp(after)!=fp(final): raise ValueError
    match=re.fullmatch(rb"([0-9a-f]{64})  -\n",result.stdout)
    if match is None: raise ValueError
    digest=match.group(1); outfd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(outfd,digest+b"\n"); os.fsync(outfd); os.close(outfd)
    raw=(json.dumps({"fingerprint":fp(final),"sha256":digest.decode()},sort_keys=True,separators=(",",":"))+"\n").encode(); fd2=os.open(state,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd2,raw); os.close(fd2)
except (OSError,ValueError): raise SystemExit(1)
PY
then fail post-staple-hash-failed 37; fi
POST_STAPLE_HASH="$(/usr/bin/tr -d '\n' < "$WORK/post-staple.sha256")"
[[ "$POST_STAPLE_HASH" =~ ^[0-9a-f]{64}$ ]] || fail post-staple-hash-failed 37
readonly POST_STAPLE_HASH

verify_repository_bindings || fail repository-binding-invalid 22
if ! "$INSPECT_DMG" --dmg "$DMG" --mode signed > "$CONTROL/inspection.json" 2> "$CONTROL/inspection-error"; then
  fail post-staple-inspection-failed 38
fi
/bin/chmod 0600 "$CONTROL/inspection.json" || fail evidence-write-failed 28
if ! /usr/bin/python3 -I - "$CONTROL/inspection.json" "$POST_STAPLE_HASH" <<'PY' >/dev/null 2>&1
import json,sys
try:
    value=json.load(open(sys.argv[1],encoding="utf-8"))
    if type(value) is not dict or value.get("status")!="valid" or value.get("mode")!="signed" or value.get("signature")!="developer-id" or value.get("dmgSHA256")!=sys.argv[2]: raise ValueError
except (OSError,ValueError,json.JSONDecodeError): raise SystemExit(1)
PY
then fail post-staple-inspection-failed 38; fi
/bin/mv "$CONTROL/inspection.json" "$WORK/inspection.json" || fail evidence-write-failed 28
verify_repository_bindings || fail repository-binding-invalid 22
if ! /usr/bin/python3 -I - "$DMG" "$POST_STAPLE_HASH" "$CONTROL/post-staple-fingerprint.json" <<'PY' >/dev/null 2>&1
import hashlib,json,os,stat,sys
path=sys.argv[1]; expected=sys.argv[2]; state=json.load(open(sys.argv[3]))
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
try:
    before=os.lstat(path); fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd); digest=hashlib.sha256()
    while True:
        chunk=os.read(fd,1024*1024)
        if not chunk: break
        digest.update(chunk)
    after=os.fstat(fd); os.close(fd); final=os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or fp(before)!=fp(opened) or fp(opened)!=fp(after) or fp(after)!=fp(final) or fp(final)!=state["fingerprint"] or digest.hexdigest()!=expected or state["sha256"]!=expected: raise ValueError
except (OSError,ValueError,KeyError): raise SystemExit(1)
PY
then fail artifact-mutated-during-inspection 39; fi

POST_STAPLE=0
printf 'notarization complete: request %s, post-staple SHA-256 %s\n' "$REQUEST_ID" "$POST_STAPLE_HASH"
