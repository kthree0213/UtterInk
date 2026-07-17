#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_SIGNED_DMG_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then printf 'signed DMG creation error: unsafe-launch-environment\n' >&2; exit 2; fi
if [[ "${UTTERINK_SIGNED_DMG_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C UTTERINK_SIGNED_DMG_ENV_CLEAN=1)
  for allowed_name in UTTERINK_SIGNING_TEST_MODE UTTERINK_SIGNING_TEST_TOOL_ROOT UTTERINK_SIGNING_TEST_SCENARIO UTTERINK_FIXTURE_LOG; do
    if [[ -n "${!allowed_name+x}" ]]; then clean_environment+=("$allowed_name=${!allowed_name}"); fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  printf 'signed DMG creation error: unsafe-launch-environment\n' >&2; exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  printf 'signed DMG creation error: unsafe-launch-environment\n' >&2; exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_SIGNED_DMG_ENV_CLEAN|UTTERINK_SIGNING_TEST_MODE|UTTERINK_SIGNING_TEST_TOOL_ROOT|UTTERINK_SIGNING_TEST_SCENARIO|UTTERINK_FIXTURE_LOG|PWD|SHLVL|_) ;;
    *) printf 'signed DMG creation error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_SIGNED_DMG_ENV_CLEAN

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
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH DEVELOPER_DIR SDKROOT TOOLCHAINS XCODE_DEFAULT_TOOLCHAIN_OVERRIDE DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH PERL5OPT PERL5LIB PERLLIB PERL5DB
umask 077

fail() { local category="$1" status="${2:-1}"; printf 'signed DMG creation error: %s\n' "$category" >&2; exit "$status"; }

CANDIDATE_ARGUMENT=''; IDENTITY=''; TEAM_ID=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --candidate) [[ -z "$CANDIDATE_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2; CANDIDATE_ARGUMENT="$2"; shift 2 ;;
    --identity) [[ -z "$IDENTITY" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2; IDENTITY="$2"; shift 2 ;;
    --team-id) [[ -z "$TEAM_ID" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2; TEAM_ID="$2"; shift 2 ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$CANDIDATE_ARGUMENT" && -n "$IDENTITY" && -n "$TEAM_ID" ]] || fail invalid-arguments 2
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
import os,stat,sys
root=Path(sys.argv[1])
try:
    item=os.lstat(root); git=os.lstat(root/".git"); marker=root/".utterink-signature-test-repository"; mark=os.lstat(marker)
    if (root!=Path(os.path.abspath(root)) or not root.as_posix().startswith("/private/tmp/") or root.is_symlink() or root.resolve(strict=True)!=root
        or not stat.S_ISDIR(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022
        or not stat.S_ISDIR(git.st_mode) or stat.S_ISLNK(git.st_mode) or git.st_uid!=os.geteuid() or git.st_mode&0o022
        or not stat.S_ISREG(mark.st_mode) or stat.S_ISLNK(mark.st_mode) or mark.st_uid!=os.geteuid() or mark.st_mode&0o022
        or marker.read_bytes()!=b"utterink-signature-test-repository-v1\n"): raise ValueError
except (OSError,ValueError): raise SystemExit(1)
PY
  then fail invalid-test-repository 20; fi
  TOOL_ROOT="${UTTERINK_SIGNING_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" ]] || fail invalid-test-tool-root 20
  if ! /usr/bin/python3 -I - "$TOOL_ROOT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
root=Path(sys.argv[1])
try:
    item=os.lstat(root); marker=root/".utterink-signature-test-tools"; mark=os.lstat(marker)
    if (root!=Path(os.path.abspath(root)) or root.is_symlink() or root.resolve(strict=True)!=root or not stat.S_ISDIR(item.st_mode)
        or item.st_uid!=os.geteuid() or item.st_mode&0o022 or not stat.S_ISREG(mark.st_mode) or stat.S_ISLNK(mark.st_mode)
        or mark.st_uid!=os.geteuid() or mark.st_mode&0o022 or marker.read_bytes()!=b"utterink-signature-test-tools-v1\n"): raise ValueError
    for name in ("file","lipo","codesign","security","openssl"):
        tool=os.lstat(root/name)
        if not stat.S_ISREG(tool.st_mode) or stat.S_ISLNK(tool.st_mode) or tool.st_uid!=os.geteuid() or tool.st_mode&0o022 or not tool.st_mode&stat.S_IXUSR: raise ValueError
except (OSError,ValueError): raise SystemExit(1)
PY
  then fail invalid-test-tool-root 20; fi
  [[ "${UTTERINK_FIXTURE_LOG:-}" == /private/tmp/* ]] || fail invalid-test-tool-root 20
  CODESIGN="$TOOL_ROOT/codesign"; SECURITY="$TOOL_ROOT/security"; OPENSSL="$TOOL_ROOT/openssl"
else
  unset UTTERINK_SIGNING_TEST_MODE UTTERINK_SIGNING_TEST_TOOL_ROOT UTTERINK_SIGNING_TEST_SCENARIO UTTERINK_FIXTURE_LOG
  CODESIGN=/usr/bin/codesign; SECURITY=/usr/bin/security; OPENSSL=/usr/bin/openssl
fi
for tool in "$CODESIGN" "$SECURITY" "$OPENSSL"; do [[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || fail signing-tool-unavailable 20; done
readonly TEST_MODE CODESIGN SECURITY OPENSSL

CREATE_DMG="$ROOT/Scripts/create-dmg.sh"; INSPECT_DMG="$ROOT/Scripts/inspect-dmg.sh"; VERIFY_SIGNATURES="$ROOT/Scripts/release/verify-signatures.sh"
for script in "$CREATE_DMG" "$INSPECT_DMG" "$VERIFY_SIGNATURES"; do [[ -f "$script" && -x "$script" && ! -L "$script" ]] || fail release-script-unavailable 20; done
readonly CREATE_DMG INSPECT_DMG VERIFY_SIGNATURES

if ! CANDIDATE="$(/usr/bin/python3 -I - "$ROOT" "$CANDIDATE_ARGUMENT" <<'PY'
from pathlib import Path,PurePath
import os,stat,sys
root=Path(sys.argv[1]); raw=sys.argv[2]
try:
    if not raw or len(raw.encode("utf-8",errors="strict"))>4096 or any(ord(c)<32 or ord(c)==127 for c in raw) or ".." in PurePath(raw).parts: raise ValueError
    candidate=Path(os.path.abspath(Path(raw) if os.path.isabs(raw) else root/raw)); relative=candidate.relative_to(root)
    if len(relative.parts)<2 or relative.parts[0]!=".release-work": raise ValueError
    root_item=os.lstat(root); current=root
    for part in relative.parts:
        current/=part; item=os.lstat(current)
        if not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_dev!=root_item.st_dev or item.st_uid!=os.geteuid() or item.st_mode&0o022: raise ValueError
    for name,kind in (("UtterInk.app","dir"),("candidate.json","file"),("unsigned-build-evidence.json","file"),("signature-verification.json","file")):
        item=os.lstat(candidate/name); valid=stat.S_ISDIR(item.st_mode) if kind=="dir" else stat.S_ISREG(item.st_mode)
        if not valid or stat.S_ISLNK(item.st_mode) or item.st_dev!=root_item.st_dev or item.st_uid!=os.geteuid() or item.st_mode&0o022 or (kind=="file" and item.st_nlink!=1): raise ValueError
    for name in ("UtterInk-0.1.0-arm64.dmg","pre-staple.sha256","signing-evidence.json"):
        if os.path.lexists(candidate/name): raise ValueError
    print(candidate)
except (OSError,UnicodeError,ValueError): raise SystemExit(1)
PY
)"; then fail unsafe-candidate 21; fi
readonly CANDIDATE
APP="$CANDIDATE/UtterInk.app"; RETAINED="$CANDIDATE/signature-verification.json"; UNSIGNED="$CANDIDATE/unsigned-build-evidence.json"; CANDIDATE_JSON="$CANDIDATE/candidate.json"
readonly APP RETAINED UNSIGNED CANDIDATE_JSON

WORK="$(/usr/bin/mktemp -d "$CANDIDATE/.utterink-signed-dmg.XXXXXX")" || fail work-directory-unavailable 21
[[ "$WORK" == "$CANDIDATE"/.utterink-signed-dmg.* && -d "$WORK" && ! -L "$WORK" ]] || fail work-directory-unavailable 21
/bin/chmod 0700 "$WORK" || fail work-directory-unavailable 21
WORK_DEVICE="$(/usr/bin/stat -f '%d' "$WORK")"; WORK_INODE="$(/usr/bin/stat -f '%i' "$WORK")"
RERUN="$CANDIDATE/.create-signature-verification-${WORK##*.}.json"
[[ ! -e "$RERUN" && ! -L "$RERUN" ]] || fail work-directory-unavailable 21

safe_cleanup() {
  /usr/bin/python3 -I - "$CANDIDATE" "$WORK_DEVICE" "$WORK_INODE" "${WORK##*/}" "${RERUN##*/}" <<'PY' >/dev/null 2>&1
import os,stat,sys
candidate,device,inode,work_name,rerun=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),sys.argv[4],sys.argv[5]
def clear(fd):
    for name in os.listdir(fd):
        item=os.stat(name,dir_fd=fd,follow_symlinks=False)
        if stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
            child=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=fd); clear(child); os.close(child); os.rmdir(name,dir_fd=fd)
        else: os.unlink(name,dir_fd=fd)
parent=os.open(candidate,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
try:
    try:
        item=os.stat(rerun,dir_fd=parent,follow_symlinks=False)
        if stat.S_ISREG(item.st_mode) and not stat.S_ISLNK(item.st_mode) and item.st_nlink==1: os.unlink(rerun,dir_fd=parent)
    except FileNotFoundError: pass
    matches=[]
    for name in os.listdir(parent):
        try: item=os.stat(name,dir_fd=parent,follow_symlinks=False)
        except OSError: continue
        if (item.st_dev,item.st_ino)==(device,inode) and stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode): matches.append(name)
    if len(matches)!=1: raise OSError
    child=os.open(matches[0],os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=parent); clear(child); os.close(child); os.rmdir(matches[0],dir_fd=parent)
finally: os.close(parent)
PY
}
cleanup() { local status=$?; trap - EXIT HUP INT TERM; safe_cleanup || status=40; exit "$status"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
case "${UTTERINK_SIGNING_TEST_SCENARIO:-}" in
  create-signal-hup|create-signal-int|create-signal-term)
    : > "${UTTERINK_FIXTURE_LOG}.${UTTERINK_SIGNING_TEST_SCENARIO}.ready"
    while :; do /bin/sleep 0.01; done ;;
esac

# Validate the retained evidence before any packaging, and pin every repository
# script and retained input to the candidate commit and its initial fingerprint.
if ! /usr/bin/python3 -I - "$ROOT" "$CANDIDATE_JSON" "$UNSIGNED" "$RETAINED" "$TEAM_ID" "$TEST_MODE" "$WORK/input-meta.json" "$WORK/bindings.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import hashlib,json,os,re,stat,subprocess,sys
root,candidate_path,unsigned_path,retained_path=map(Path,sys.argv[1:5]); team=sys.argv[5]; test_mode=sys.argv[6]=="1"; meta_path,binding_path=map(Path,sys.argv[7:9]); MAX=512*1024
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
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns]
def read(path,maximum=MAX):
    before=os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_nlink!=1 or before.st_uid!=os.geteuid() or before.st_mode&0o022 or before.st_size>maximum: abort()
    fd=os.open(path,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); opened=os.fstat(fd); chunks=[]
    while True:
        chunk=os.read(fd,65536)
        if not chunk: break
        chunks.append(chunk)
        if sum(map(len,chunks))>maximum: abort()
    after=os.fstat(fd); os.close(fd)
    if fp(before)!=fp(opened) or fp(opened)!=fp(after): abort()
    return b"".join(chunks),before
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def git(*args):
    result=subprocess.run(["/usr/bin/git","-C",str(root),*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
    if result.returncode: abort()
    return result.stdout
def blob(relative,commit):
    listing=git("ls-tree","-z",commit,"--",relative)
    if not listing.endswith(b"\0") or listing.count(b"\0")!=1: abort()
    header,name=listing[:-1].split(b"\t",1); mode,kind,oid=header.split(b" ",2)
    if name.decode("utf-8",errors="strict")!=relative or kind!=b"blob" or mode not in {b"100644",b"100755"}: abort()
    return git("cat-file","blob",oid.decode("ascii"))
try:
    candidate_raw,candidate_item=read(candidate_path,256*1024); candidate=json.loads(candidate_raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    candidate=exact(candidate,{"schemaVersion","evidenceType","product","source","release","toolchain","packageResolution","policies","checks"})
    if type(candidate["schemaVersion"]) is not int or candidate["schemaVersion"]!=1 or candidate["evidenceType"]!=("release-candidate-test" if test_mode else "release-candidate") or candidate["product"]!="UtterInk": abort()
    source=exact(candidate["source"],{"commit","tree","releaseTag","clean"}); commit=pattern(source["commit"],r"[0-9a-f]{40}"); pattern(source["tree"],r"[0-9a-f]{40}")
    if source["releaseTag"]!="v0.1.0" or source["clean"] is not True: abort()
    if git("rev-parse","--verify","HEAD^{commit}").strip().decode()!=commit or git("rev-parse",f"{commit}^{{tree}}").strip().decode()!=source["tree"]: abort()
    release=exact(candidate["release"],{"configuration","marketingVersion","buildNumber","bundleIdentifier","deploymentTarget","architecture","dmgFilename"})
    if release!={"configuration":"Release","marketingVersion":"0.1.0","buildNumber":"1","bundleIdentifier":"dev.utterink.UtterInk","deploymentTarget":"14.0","architecture":"arm64","dmgFilename":"UtterInk-0.1.0-arm64.dmg"}: abort()
    exact(candidate["toolchain"],{"lockSHA256","xcodeVersion","xcodeBuild","sdkVersion","sdkBuild","swiftVersion","xcodegenVersion","xcodegenBinarySHA256"})
    exact(candidate["packageResolution"],{"path","sha256"})
    policies=exact(candidate["policies"],{"releaseMetadataSHA256","releaseEntitlementsSHA256","releaseInfoPolicySHA256","ciToolchainSHA256"})
    checks=exact(candidate["checks"],{"history","metadata","entitlements","infoPolicy","packageResolution","generatedProjectClean"})
    if any(value is not True for value in checks.values()) or candidate["packageResolution"].get("path")!="Packages/UtterInkKit/Package.resolved": abort()
    for value in list(policies.values())+[candidate["packageResolution"].get("sha256"),candidate["toolchain"].get("lockSHA256"),candidate["toolchain"].get("xcodegenBinarySHA256")]: pattern(value,r"[0-9a-f]{64}")
    candidate_hash=hashlib.sha256(candidate_raw).hexdigest()
    unsigned_raw,unsigned_item=read(unsigned_path,64*1024); unsigned=json.loads(unsigned_raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    unsigned=exact(unsigned,{"appTreeSHA256","archiveTreeSHA256","candidateCommit","candidateJSONSHA256","evidenceType","product","schemaVersion","status","treeAlgorithm"})
    unsigned_canonical=(json.dumps(unsigned,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode("utf-8")
    if unsigned_raw!=unsigned_canonical or type(unsigned["schemaVersion"]) is not int or unsigned["schemaVersion"]!=1 or unsigned["evidenceType"]!="unsigned-build" or unsigned["product"]!="UtterInk" or unsigned["status"]!="valid" or unsigned["treeAlgorithm"]!="utterink-logical-tree-v1" or unsigned["candidateCommit"]!=commit or unsigned["candidateJSONSHA256"]!=candidate_hash: abort()
    pattern(unsigned["candidateCommit"],r"[0-9a-f]{40}")
    for key in ("appTreeSHA256","archiveTreeSHA256","candidateJSONSHA256"): pattern(unsigned[key],r"[0-9a-f]{64}")
    unsigned_hash=hashlib.sha256(unsigned_canonical).hexdigest()
    retained_raw,retained_item=read(retained_path,1024*1024); retained=json.loads(retained_raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    retained=exact(retained,{"candidateCommit","candidateJSONSHA256","certificate","components","evidenceType","product","schemaVersion","signedAppTreeSHA256","status","teamID","treeAlgorithm","unsignedBuildEvidenceSHA256"})
    canonical=(json.dumps(retained,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode("utf-8")
    if retained_raw!=canonical or type(retained["schemaVersion"]) is not int or retained["schemaVersion"]!=1 or retained["evidenceType"]!="signature-verification" or retained["product"]!="UtterInk" or retained["status"]!="valid" or retained["teamID"]!=team or retained["treeAlgorithm"]!="utterink-logical-tree-v1" or retained["candidateCommit"]!=commit or retained["candidateJSONSHA256"]!=candidate_hash or retained["unsignedBuildEvidenceSHA256"]!=unsigned_hash: abort()
    for key in ("candidateJSONSHA256","unsignedBuildEvidenceSHA256","signedAppTreeSHA256"): pattern(retained[key],r"[0-9a-f]{64}")
    certificate=exact(retained["certificate"],{"notAfter","notBefore","sha256","trust"}); cert_sha=pattern(certificate["sha256"],r"[0-9a-f]{64}")
    if (certificate["trust"]!="valid" or type(certificate["trust"]) is not str
        or type(certificate["notAfter"]) is not str or not certificate["notAfter"]
        or type(certificate["notBefore"]) is not str or not certificate["notBefore"]): abort()
    if type(retained["components"]) is not list or not retained["components"]: abort()
    component_keys={"architecture","designatedRequirement","entitlements","identifier","kind","path","runtime","secureTimestamp","sha256","teamID","trust"}
    paths=[]
    for component in retained["components"]:
        if type(component) is not dict or set(component)!=component_keys: abort()
        if component["architecture"] not in (None,"arm64") or component["designatedRequirement"]!="valid" or type(component["entitlements"]) is not dict: abort()
        pattern(component["identifier"],r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}"); pattern(component["sha256"],r"[0-9a-f]{64}")
        if (component["kind"] not in ("bundle","mach-o") or type(component["path"]) is not str or not component["path"].startswith("UtterInk.app")
            or component["runtime"]!="hardened" or component["secureTimestamp"]!="present"
            or component["teamID"]!=team or component["trust"]!="valid"): abort()
        if component["path"] in ("UtterInk.app","UtterInk.app/Contents/MacOS/UtterInk") and component["identifier"]!="dev.utterink.UtterInk": abort()
        paths.append(component["path"])
    if paths!=sorted(paths,key=lambda value:value.encode("utf-8")) or len(paths)!=len(set(paths)): abort()
    bindings={}
    for path,item,data in ((candidate_path,candidate_item,candidate_raw),(unsigned_path,unsigned_item,unsigned_raw),(retained_path,retained_item,retained_raw)):
        bindings[str(path)]={"fingerprint":fp(item),"sha256":hashlib.sha256(data).hexdigest(),"relative":None}
    for relative in ("Scripts/create-dmg.sh","Scripts/inspect-dmg.sh","Scripts/release/verify-signatures.sh"):
        path=root/relative; data,item=read(path); expected=blob(relative,commit)
        if data!=expected: abort()
        bindings[str(path)]={"fingerprint":fp(item),"sha256":hashlib.sha256(data).hexdigest(),"relative":relative}
    meta={"candidateCommit":commit,"certificateSHA256":cert_sha,"retainedSHA256":hashlib.sha256(retained_raw).hexdigest(),"signedAppTreeSHA256":retained["signedAppTreeSHA256"],"unsignedBuildEvidenceSHA256":unsigned_hash}
    meta_path.write_text(json.dumps(meta,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8"); binding_path.write_text(json.dumps(bindings,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): abort()
PY
then fail invalid-retained-evidence 22; fi

SOURCE_COMMIT="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["candidateCommit"])' "$WORK/input-meta.json")"
CERTIFICATE_SHA256="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["certificateSHA256"])' "$WORK/input-meta.json")"
SIGNED_APP_TREE_SHA256="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["signedAppTreeSHA256"])' "$WORK/input-meta.json")"
readonly SOURCE_COMMIT CERTIFICATE_SHA256 SIGNED_APP_TREE_SHA256

assert_inputs_bound() {
  /usr/bin/python3 -I - "$ROOT" "$SOURCE_COMMIT" "$WORK/bindings.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import hashlib,json,os,stat,subprocess,sys
root,commit,binding_path=Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3])
def abort(): raise SystemExit(1)
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def git(*args):
    result=subprocess.run(["/usr/bin/git","-C",str(root),*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
    if result.returncode: abort()
    return result.stdout
try:
    bindings=json.loads(binding_path.read_text(encoding="utf-8"))
    for raw,record in bindings.items():
        path=Path(raw); before=os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_nlink!=1 or before.st_uid!=os.geteuid() or before.st_mode&0o022: abort()
        fd=os.open(path,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); opened=os.fstat(fd); chunks=[]
        while True:
            chunk=os.read(fd,65536)
            if not chunk: break
            chunks.append(chunk)
        after=os.fstat(fd); os.close(fd); fp=lambda x:[x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns]
        data=b"".join(chunks)
        if fp(before)!=record["fingerprint"] or fp(opened)!=record["fingerprint"] or fp(after)!=record["fingerprint"] or hashlib.sha256(data).hexdigest()!=record["sha256"]: abort()
        relative=record["relative"]
        if relative is not None:
            listing=git("ls-tree","-z",commit,"--",relative)
            if not listing.endswith(b"\0") or listing.count(b"\0")!=1: abort()
            header,name=listing[:-1].split(b"\t",1); mode,kind,oid=header.split(b" ",2)
            if name.decode()!=relative or kind!=b"blob" or mode not in {b"100644",b"100755"} or data!=git("cat-file","blob",oid.decode()): abort()
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): abort()
PY
}
assert_inputs_bound || fail repository-binding-mismatch 22

if ! "$VERIFY_SIGNATURES" --candidate "$CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID" \
  --expected-certificate-sha256 "$CERTIFICATE_SHA256" --output "$RERUN" > "$WORK/verifier.out" 2> "$WORK/verifier.err"; then
  fail signature-verification-failed 22
fi
assert_inputs_bound || fail repository-binding-mismatch 22
[[ -f "$RERUN" && ! -L "$RERUN" && -s "$RERUN" ]] || fail signature-verification-failed 22
/usr/bin/cmp -s "$RETAINED" "$RERUN" || fail retained-evidence-mismatch 22

# Copy the exact verified app to private storage with no-follow descriptor
# traversal. Both source snapshots and the pinned copy must equal retained evidence.
PINNED_PARENT="$WORK/pinned-candidate"; /bin/mkdir -m 0700 "$PINNED_PARENT" || fail candidate-pinning-failed 23
PINNED_APP="$PINNED_PARENT/UtterInk.app"
if ! /usr/bin/python3 -I - "$APP" "$PINNED_PARENT" "$SIGNED_APP_TREE_SHA256" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePosixPath
import hashlib,json,os,stat,sys
source,destination_parent,expected=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
def abort(): raise SystemExit(1)
def safe_target(relative,value):
    target=PurePosixPath(value)
    if not value or target.is_absolute() or ".." in target.parts or ".." in PurePosixPath(relative).parent.joinpath(target).parts or any(ord(c)<32 or ord(c)==127 for c in value): abort()
    return value
def logical(root):
    root_item=os.lstat(root); root_fd=os.open(root,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); records=[]
    if not stat.S_ISDIR(root_item.st_mode) or stat.S_ISLNK(root_item.st_mode) or root_item.st_uid!=os.geteuid() or root_item.st_mode&0o022: abort()
    def walk(fd,prefix):
        for name in sorted(os.listdir(fd),key=os.fsencode):
            rel=f"{prefix}/{name}" if prefix else name; item=os.stat(name,dir_fd=fd,follow_symlinks=False); mode=stat.S_IMODE(item.st_mode)
            if item.st_dev!=root_item.st_dev or item.st_uid!=os.geteuid(): abort()
            if stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
                if item.st_mode&0o022: abort()
                records.append([rel,"directory",mode,""]); child=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=fd); walk(child,rel); os.close(child)
            elif stat.S_ISREG(item.st_mode):
                if item.st_mode&0o022 or item.st_nlink!=1: abort()
                child=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=fd); digest=hashlib.sha256()
                while True:
                    chunk=os.read(child,65536)
                    if not chunk: break
                    digest.update(chunk)
                os.close(child); records.append([rel,"file",mode,digest.hexdigest()])
            elif stat.S_ISLNK(item.st_mode): records.append([rel,"symlink",mode,safe_target(rel,os.readlink(name,dir_fd=fd))])
            else: abort()
    walk(root_fd,""); os.close(root_fd); records.sort(key=lambda x:x[0].encode("utf-8")); digest=hashlib.sha256()
    for record in records: digest.update((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8"))
    return digest.hexdigest()
def copy_dir(src,dst,prefix):
    for name in sorted(os.listdir(src),key=os.fsencode):
        rel=f"{prefix}/{name}" if prefix else name; item=os.stat(name,dir_fd=src,follow_symlinks=False); mode=stat.S_IMODE(item.st_mode)
        if stat.S_ISDIR(item.st_mode) and not stat.S_ISLNK(item.st_mode):
            os.mkdir(name,0o700,dir_fd=dst); s=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=src); d=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=dst); copy_dir(s,d,rel); os.fchmod(d,mode); os.close(s); os.close(d)
        elif stat.S_ISREG(item.st_mode):
            s=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=src); opened=os.fstat(s); d=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600,dir_fd=dst)
            while True:
                chunk=os.read(s,65536)
                if not chunk: break
                offset=0
                while offset<len(chunk): offset+=os.write(d,chunk[offset:])
            after=os.fstat(s); os.fchmod(d,mode); os.fsync(d); os.close(d); os.close(s)
            if (item.st_dev,item.st_ino,item.st_size,item.st_mtime_ns,item.st_ctime_ns)!=(opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns) or (opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns): abort()
        elif stat.S_ISLNK(item.st_mode): os.symlink(safe_target(rel,os.readlink(name,dir_fd=src)),name,dir_fd=dst)
        else: abort()
try:
    before=logical(source)
    if before!=expected: abort()
    parent=os.open(destination_parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); os.mkdir("UtterInk.app",0o700,dir_fd=parent)
    src=os.open(source,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); dst=os.open("UtterInk.app",os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=parent)
    copy_dir(src,dst,""); os.fchmod(dst,stat.S_IMODE(os.fstat(src).st_mode)); os.close(src); os.close(dst); os.close(parent)
    if logical(source)!=expected or logical(destination_parent/"UtterInk.app")!=expected: abort()
except (OSError,UnicodeError,ValueError): abort()
PY
then fail candidate-pinning-failed 23; fi

assert_inputs_bound || fail repository-binding-mismatch 23

# Resolve exactly one current identity/private key, bind its SHA-1 fingerprint
# to the same certificate SHA-256 retained from the embedded leaf, and use SHA-1 for signing.
if ! "$SECURITY" find-identity -v -p codesigning > "$WORK/identities.txt" 2> "$WORK/tool-error"; then fail identity-preflight-failed 24; fi
if ! /usr/bin/python3 -I - "$WORK/identities.txt" "$IDENTITY" "$WORK/identity-sha1" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re,sys
lines=Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(); matches=[]
for line in lines:
    match=re.fullmatch(r'\s*[0-9]+[)]\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*',line)
    if match and match.group(2)==sys.argv[2]: matches.append(match.group(1).lower())
if len(matches)!=1: raise SystemExit(1)
Path(sys.argv[3]).write_text(matches[0],encoding="ascii")
PY
then fail identity-preflight-failed 24; fi
IDENTITY_SHA1="$(/bin/cat "$WORK/identity-sha1")"; readonly IDENTITY_SHA1
if ! "$SECURITY" find-certificate -a -c "$IDENTITY" -p > "$WORK/keychain-certificate.pem" 2> "$WORK/tool-error"; then fail identity-preflight-failed 24; fi
if ! /usr/bin/python3 -I - "$WORK/keychain-certificate.pem" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys
value=Path(sys.argv[1]).read_text(encoding="ascii")
if value.count("-----BEGIN CERTIFICATE-----")!=1 or value.count("-----END CERTIFICATE-----")!=1: raise SystemExit(1)
PY
then fail identity-preflight-failed 24; fi
if ! "$SECURITY" verify-cert -c "$WORK/keychain-certificate.pem" -p codeSign > "$WORK/trust.out" 2> "$WORK/tool-error"; then fail identity-preflight-failed 24; fi
if ! "$OPENSSL" x509 -in "$WORK/keychain-certificate.pem" -checkend 0 -noout > "$WORK/checkend.out" 2> "$WORK/tool-error"; then fail identity-preflight-failed 24; fi
if ! "$OPENSSL" x509 -in "$WORK/keychain-certificate.pem" -noout -subject -nameopt sep_multiline,lname,space_eq -fingerprint -sha1 > "$WORK/keychain-sha1.txt" 2> "$WORK/tool-error"; then fail identity-preflight-failed 24; fi
if ! "$OPENSSL" x509 -in "$WORK/keychain-certificate.pem" -noout -fingerprint -sha256 > "$WORK/keychain-sha256.txt" 2> "$WORK/tool-error"; then fail identity-preflight-failed 24; fi
if ! /usr/bin/python3 -I - "$WORK/keychain-sha1.txt" "$WORK/keychain-sha256.txt" "$IDENTITY" "$TEAM_ID" "$IDENTITY_SHA1" "$CERTIFICATE_SHA256" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re,sys
sha1_lines=Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(); sha256_lines=Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
common=[line.strip().removeprefix("commonName = ") for line in sha1_lines if line.strip().startswith("commonName = ")]
units=[line.strip().removeprefix("organizationalUnitName = ") for line in sha1_lines if line.strip().startswith("organizationalUnitName = ")]
def fingerprint(lines,length):
    values=[line.split("Fingerprint=",1)[1].replace(":","").strip().lower() for line in lines if "Fingerprint=" in line]
    if len(values)!=1 or re.fullmatch(rf"[0-9a-f]{{{length}}}",values[0]) is None: raise SystemExit(1)
    return values[0]
if common!=[sys.argv[3]] or units!=[sys.argv[4]] or fingerprint(sha1_lines,40)!=sys.argv[5] or fingerprint(sha256_lines,64)!=sys.argv[6]: raise SystemExit(1)
PY
then fail identity-certificate-mismatch 24; fi

assert_pinned_tree() {
  /usr/bin/python3 -I - "$PINNED_APP" "$SIGNED_APP_TREE_SHA256" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePosixPath
import hashlib,json,os,stat,sys
root,expected=Path(sys.argv[1]),sys.argv[2]
def abort(): raise SystemExit(1)
def safe(rel,value):
    target=PurePosixPath(value)
    if not value or target.is_absolute() or ".." in target.parts or ".." in PurePosixPath(rel).parent.joinpath(target).parts: abort()
    return value
try:
    item=os.lstat(root); fd=os.open(root,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); records=[]
    if not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022: abort()
    def walk(directory,prefix):
        for name in sorted(os.listdir(directory),key=os.fsencode):
            rel=f"{prefix}/{name}" if prefix else name; meta=os.stat(name,dir_fd=directory,follow_symlinks=False); mode=stat.S_IMODE(meta.st_mode)
            if stat.S_ISDIR(meta.st_mode) and not stat.S_ISLNK(meta.st_mode):
                records.append([rel,"directory",mode,""]); child=os.open(name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=directory); walk(child,rel); os.close(child)
            elif stat.S_ISREG(meta.st_mode):
                child=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=directory); digest=hashlib.sha256()
                while True:
                    chunk=os.read(child,65536)
                    if not chunk: break
                    digest.update(chunk)
                os.close(child); records.append([rel,"file",mode,digest.hexdigest()])
            elif stat.S_ISLNK(meta.st_mode): records.append([rel,"symlink",mode,safe(rel,os.readlink(name,dir_fd=directory))])
            else: abort()
    walk(fd,""); os.close(fd); records.sort(key=lambda x:x[0].encode("utf-8")); digest=hashlib.sha256()
    for record in records: digest.update((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8"))
    if digest.hexdigest()!=expected: abort()
except (OSError,UnicodeError,ValueError): abort()
PY
}

DMG="$WORK/UtterInk-0.1.0-arm64.dmg"; PRE_STAPLE="$WORK/pre-staple.sha256"; FINAL_EVIDENCE="$WORK/signing-evidence.json"
assert_inputs_bound || fail repository-binding-mismatch 23
assert_pinned_tree || fail candidate-pinning-failed 23
if ! "$CREATE_DMG" --app "$PINNED_APP" --output "$DMG" --mode signed > "$WORK/create.out" 2> "$WORK/create.err"; then fail dmg-creation-failed 23; fi
assert_inputs_bound || fail repository-binding-mismatch 23
assert_pinned_tree || fail candidate-pinning-failed 23
[[ -f "$DMG" && ! -L "$DMG" && -s "$DMG" ]] || fail dmg-creation-failed 23

if ! "$CODESIGN" --force --timestamp --sign "$IDENTITY_SHA1" "$DMG" > "$WORK/codesign.out" 2> "$WORK/codesign.err"; then fail dmg-signing-failed 24; fi
if ! "$CODESIGN" --verify --strict --verbose=4 "$DMG" > "$WORK/dmg-verify.out" 2> "$WORK/dmg-verify.err"; then fail dmg-signature-invalid 24; fi
if ! "$CODESIGN" -d --verbose=4 "$DMG" > "$WORK/dmg-metadata.out" 2> "$WORK/dmg-metadata.err"; then fail dmg-signature-invalid 24; fi
if ! /usr/bin/python3 -I - "$WORK/dmg-metadata.err" "$IDENTITY" "$TEAM_ID" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(); identity,team=sys.argv[2:4]
authorities=[line.split("=",1)[1] for line in lines if line.startswith("Authority=")]; teams=[line.split("=",1)[1] for line in lines if line.startswith("TeamIdentifier=")]; timestamps=[line.split("=",1)[1] for line in lines if line.startswith("Timestamp=")]
if not authorities or authorities[0]!=identity or authorities.count(identity)!=1 or teams!=[team] or len(timestamps)!=1 or not timestamps[0]: raise SystemExit(1)
PY
then fail dmg-signature-invalid 24; fi

# Confirm the DMG is signed by the same actual leaf, not merely an Authority
# string with the same display name.
if ! "$CODESIGN" -d --extract-certificates "$WORK/dmg-leaf-" "$DMG" > "$WORK/dmg-extract.out" 2> "$WORK/dmg-extract.err"; then fail dmg-signature-invalid 24; fi
[[ -f "$WORK/dmg-leaf-0" && ! -L "$WORK/dmg-leaf-0" ]] || fail dmg-signature-invalid 24
if ! "$OPENSSL" x509 -inform DER -in "$WORK/dmg-leaf-0" -out "$WORK/dmg-leaf.pem" 2> "$WORK/tool-error"; then fail dmg-signature-invalid 24; fi
if ! "$SECURITY" verify-cert -c "$WORK/dmg-leaf.pem" -p codeSign > "$WORK/dmg-trust.out" 2> "$WORK/tool-error"; then fail dmg-signature-invalid 24; fi
if ! "$OPENSSL" x509 -in "$WORK/dmg-leaf.pem" -noout -fingerprint -sha256 > "$WORK/dmg-leaf-sha256" 2> "$WORK/tool-error"; then fail dmg-signature-invalid 24; fi
if ! /usr/bin/python3 -I - "$WORK/dmg-leaf-sha256" "$CERTIFICATE_SHA256" <<'PY' >/dev/null 2>&1
from pathlib import Path
import re,sys
values=[line.split("Fingerprint=",1)[1].replace(":","").strip().lower() for line in Path(sys.argv[1]).read_text(encoding="ascii").splitlines() if "Fingerprint=" in line]
if values!=[sys.argv[2]] or re.fullmatch(r"[0-9a-f]{64}",values[0]) is None: raise SystemExit(1)
PY
then fail identity-certificate-mismatch 24; fi
assert_inputs_bound || fail repository-binding-mismatch 24

if ! "$INSPECT_DMG" --dmg "$DMG" --mode signed > "$WORK/inspection.json" 2> "$WORK/inspection.err"; then fail dmg-inspection-failed 25; fi
assert_inputs_bound || fail repository-binding-mismatch 25
if ! /usr/bin/python3 -I - "$DMG" "$RETAINED" "$WORK/inspection.json" "$TEAM_ID" "$PRE_STAPLE" "$FINAL_EVIDENCE" <<'PY' >/dev/null 2>&1
from pathlib import Path
import hashlib,json,os,stat,sys
dmg,verification,inspection_path=map(Path,sys.argv[1:4]); team=sys.argv[4]; pre_staple,evidence=map(Path,sys.argv[5:7])
def read(path):
    before=os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid() or before.st_nlink!=1 or before.st_mode&0o022: raise ValueError
    fd=os.open(path,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); opened=os.fstat(fd); chunks=[]
    while True:
        chunk=os.read(fd,1024*1024)
        if not chunk: break
        chunks.append(chunk)
    after=os.fstat(fd); os.close(fd)
    fingerprint=lambda x:(x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
    if fingerprint(before)!=fingerprint(opened) or fingerprint(opened)!=fingerprint(after): raise ValueError
    return b"".join(chunks)
try:
    dmg_bytes=read(dmg); verification_bytes=read(verification); inspection_bytes=read(inspection_path); inspection=json.loads(inspection_bytes.decode("utf-8"))
    keys={"architecture","buildNumber","bundleIdentifier","dmgFilename","dmgSHA256","machOCount","manifest","minimumSystemVersion","mode","product","signature","status","version"}
    if set(inspection)!=keys: raise ValueError
    fixed={"architecture":"arm64","buildNumber":"1","bundleIdentifier":"dev.utterink.UtterInk","dmgFilename":"UtterInk-0.1.0-arm64.dmg","manifest":["Applications -> /Applications","UtterInk.app directory"],"minimumSystemVersion":"14.0","mode":"signed","product":"UtterInk","signature":"developer-id","status":"valid","version":"0.1.0"}
    if any(inspection.get(key)!=value for key,value in fixed.items()) or type(inspection["machOCount"]) is not int or isinstance(inspection["machOCount"],bool) or inspection["machOCount"]<1: raise ValueError
    verification_value=json.loads(verification_bytes.decode("utf-8"))
    if verification_value.get("evidenceType")!="signature-verification" or verification_value.get("status")!="valid" or verification_value.get("teamID")!=team: raise ValueError
    dmg_hash=hashlib.sha256(dmg_bytes).hexdigest()
    if inspection["dmgSHA256"]!=dmg_hash: raise ValueError
    verification_hash=hashlib.sha256(verification_bytes).hexdigest(); pre_staple.write_text(f"{dmg_hash}  {dmg.name}\n",encoding="ascii")
    value={"dmgFilename":dmg.name,"dmgSHA256":dmg_hash,"evidenceType":"signed-pre-staple-dmg","inspection":inspection,"product":"UtterInk","schemaVersion":1,"signatureVerificationSHA256":verification_hash,"status":"valid","teamID":team}
    encoded=json.dumps(value,sort_keys=True,separators=(",",":"))+"\n"
    if any(item in encoded for item in ("Developer ID Application","/private/tmp/","/Users/")): raise ValueError
    evidence.write_text(encoded,encoding="utf-8")
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): raise SystemExit(1)
PY
then fail evidence-generation-failed 26; fi
assert_inputs_bound || fail repository-binding-mismatch 26
/usr/bin/cmp -s "$RETAINED" "$RERUN" || fail retained-evidence-mismatch 26

if ! /usr/bin/python3 -I - "$CANDIDATE" "$DMG" "$PRE_STAPLE" "$FINAL_EVIDENCE" <<'PY' >/dev/null 2>&1
from pathlib import Path
import hashlib,json,os,signal,stat,sys
candidate=Path(sys.argv[1]); sources=[Path(value) for value in sys.argv[2:5]]; names=["UtterInk-0.1.0-arm64.dmg","pre-staple.sha256","signing-evidence.json"]; created=[]; parent=-1
class Interrupted(Exception): pass
def interrupted(_signum,_frame): raise Interrupted
for signum in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM): signal.signal(signum,interrupted)
try:
    data=[]
    for source in sources:
        item=os.lstat(source)
        if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode): raise OSError
        fd=os.open(source,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); chunks=[]
        while True:
            chunk=os.read(fd,1024*1024)
            if not chunk: break
            chunks.append(chunk)
        os.close(fd); data.append(b"".join(chunks))
    published=json.loads(data[2].decode("utf-8")); digest=hashlib.sha256(data[0]).hexdigest()
    if published.get("dmgSHA256")!=digest or published.get("inspection",{}).get("dmgSHA256")!=digest or data[1]!=f"{digest}  {names[0]}\n".encode("ascii"): raise OSError
    parent=os.open(candidate,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)); item=os.fstat(parent)
    if not stat.S_ISDIR(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022: raise OSError
    for value,name in zip(data,names):
        fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600,dir_fd=parent); created.append(name); offset=0
        while offset<len(value): offset+=os.write(fd,value[offset:])
        os.fsync(fd); os.close(fd)
    os.fsync(parent)
except (OSError,Interrupted):
    if parent>=0:
        for name in reversed(created):
            try: os.unlink(name,dir_fd=parent)
            except OSError: pass
    raise SystemExit(1)
finally:
    if parent>=0: os.close(parent)
PY
then fail output-publish-failed 27; fi

exit 0
