#!/usr/bin/env -S -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PS4 -u POSIXLY_CORRECT -u BASH_COMPAT -u UTTERINK_FINAL_DMG_ENV_CLEAN /bin/bash -p

set +x +v
if [[ "$-" != *p* ]]; then
  /usr/bin/printf 'final DMG verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "${UTTERINK_FINAL_DMG_ENV_CLEAN:-}" != 1 ]]; then
  clean_environment=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C UTTERINK_FINAL_DMG_ENV_CLEAN=1)
  for allowed_name in \
    UTTERINK_FINAL_DMG_TEST_MODE UTTERINK_FINAL_DMG_TEST_TOOL_ROOT \
    UTTERINK_FINAL_DMG_TEST_LOG UTTERINK_FINAL_DMG_TEST_SCENARIO; do
    if [[ -n "${!allowed_name+x}" ]]; then
      clean_environment+=("$allowed_name=${!allowed_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_environment[@]}" /bin/bash -p "$0" "$@"
  /usr/bin/printf 'final DMG verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
if [[ "$-" != hpB || "${PATH-}" != /usr/bin:/bin:/usr/sbin:/sbin || "${LC_ALL-}" != C ]]; then
  /usr/bin/printf 'final DMG verification error: unsafe-launch-environment\n' >&2
  exit 2
fi
while IFS= read -r -d '' environment_entry; do
  environment_name="${environment_entry%%=*}"
  case "$environment_name" in
    PATH|LC_ALL|UTTERINK_FINAL_DMG_ENV_CLEAN|UTTERINK_FINAL_DMG_TEST_MODE|UTTERINK_FINAL_DMG_TEST_TOOL_ROOT|UTTERINK_FINAL_DMG_TEST_LOG|UTTERINK_FINAL_DMG_TEST_SCENARIO|PWD|SHLVL|_) ;;
    *) /usr/bin/printf 'final DMG verification error: unsafe-launch-environment\n' >&2; exit 2 ;;
  esac
done < <(/usr/bin/env -0)
unset UTTERINK_FINAL_DMG_ENV_CLEAN

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
  /usr/bin/printf 'final DMG verification error: %s\n' "$category" >&2
  exit "$status"
}

DMG_ARGUMENT=''
EXPECTED_SHA256=''
EVIDENCE_ARGUMENT=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ -z "$DMG_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      DMG_ARGUMENT="$2"; shift 2 ;;
    --expected-sha256)
      [[ -z "$EXPECTED_SHA256" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      EXPECTED_SHA256="$2"; shift 2 ;;
    --evidence)
      [[ -z "$EVIDENCE_ARGUMENT" && "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail invalid-arguments 2
      EVIDENCE_ARGUMENT="$2"; shift 2 ;;
    *) fail invalid-arguments 2 ;;
  esac
done
[[ -n "$DMG_ARGUMENT" && "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ && -n "$EVIDENCE_ARGUMENT" ]] || fail invalid-arguments 2

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || fail unsafe-repository 20
SCRIPT_DIRECTORY="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$SCRIPT_PATH")" && /bin/pwd -P)" || fail unsafe-repository 20
ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIRECTORY/../.." && /bin/pwd -P)" || fail unsafe-repository 20
GIT_ROOT="$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail unsafe-repository 20
GIT_ROOT="$(CDPATH= cd -P -- "$GIT_ROOT" && /bin/pwd -P)" || fail unsafe-repository 20
[[ "$GIT_ROOT" == "$ROOT" ]] || fail unsafe-repository 20
cd "$ROOT"
readonly SCRIPT_DIRECTORY ROOT GIT_ROOT

TEST_MODE=0
case "${UTTERINK_FINAL_DMG_TEST_MODE:-}" in
  '') ;;
  1) TEST_MODE=1 ;;
  *) fail invalid-test-mode 20 ;;
esac

if [[ "$TEST_MODE" -eq 1 ]]; then
  if ! /usr/bin/python3 -I - "$ROOT" "${UTTERINK_FINAL_DMG_TEST_LOG:-}" "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-}" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os, re, stat, sys
root=Path(sys.argv[1]); log_raw=sys.argv[2]; scenario=sys.argv[3]
allowed={"success","quarantine-absent","initial-hash-failure","staple-failure","mount-failure","manifest-failure","signature-failure","dmg-gatekeeper-failure","app-gatekeeper-failure","metadata-failure","metadata-malformed","final-hash-failure","pinned-mutation","detach-failure","evidence-write-failure","evidence-partial-write-failure","evidence-final-replace","evidence-final-remove","evidence-created-dir-replace"}
try:
    root_item=os.lstat(root); git_item=os.lstat(root/".git"); marker=root/".utterink-final-dmg-test-repository"; marker_item=os.lstat(marker)
    if (root != Path(os.path.abspath(root)) or not root.as_posix().startswith("/private/tmp/utterink-final-dmg-tests.")
        or root.is_symlink() or root.resolve(strict=True)!=root or not stat.S_ISDIR(root_item.st_mode)
        or root_item.st_uid!=os.geteuid() or root_item.st_mode&0o022
        or not stat.S_ISDIR(git_item.st_mode) or stat.S_ISLNK(git_item.st_mode) or git_item.st_uid!=os.geteuid() or git_item.st_mode&0o022
        or not stat.S_ISREG(marker_item.st_mode) or stat.S_ISLNK(marker_item.st_mode) or marker_item.st_uid!=os.geteuid()
        or marker_item.st_nlink!=1 or marker_item.st_mode&0o022
        or marker.read_bytes()!=b"utterink-final-dmg-test-repository-v1\n"):
        raise ValueError
    log=Path(log_raw)
    if (not log_raw or log != Path(os.path.abspath(log)) or log.parent!=root or not log.name.startswith(".test-")
        or any(ord(c)<32 or ord(c)==127 for c in log_raw) or scenario not in allowed):
        raise ValueError
    if os.path.lexists(log):
        item=os.lstat(log)
        if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid() or item.st_nlink!=1 or item.st_mode&0o022:
            raise ValueError
except (OSError,RuntimeError,ValueError): raise SystemExit(1)
PY
  then fail invalid-test-repository 20; fi
  TOOL_ROOT="${UTTERINK_FINAL_DMG_TEST_TOOL_ROOT:-}"
  [[ "$TOOL_ROOT" == "$ROOT/FixtureTools" ]] || fail invalid-test-tool-root 20
  if ! /usr/bin/python3 -I - "$TOOL_ROOT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,stat,sys
root=Path(sys.argv[1])
try:
    item=os.lstat(root); marker=root/".utterink-final-dmg-test-tools"; marker_item=os.lstat(marker)
    if (root!=Path(os.path.abspath(root)) or root.is_symlink() or root.resolve(strict=True)!=root
        or not stat.S_ISDIR(item.st_mode) or item.st_uid!=os.geteuid() or item.st_mode&0o022
        or not stat.S_ISREG(marker_item.st_mode) or stat.S_ISLNK(marker_item.st_mode) or marker_item.st_uid!=os.geteuid()
        or marker_item.st_nlink!=1 or marker_item.st_mode&0o022
        or marker.read_bytes()!=b"utterink-final-dmg-test-tools-v1\n"):
        raise ValueError
    for name in ("hdiutil","codesign","spctl","xcrun","xattr","shasum","ditto","file"):
        tool=os.lstat(root/name)
        if (not stat.S_ISREG(tool.st_mode) or stat.S_ISLNK(tool.st_mode) or tool.st_uid!=os.geteuid()
            or tool.st_nlink!=1 or tool.st_mode&0o022 or not tool.st_mode&stat.S_IXUSR): raise ValueError
except (OSError,RuntimeError,ValueError): raise SystemExit(1)
PY
  then fail invalid-test-tool-root 20; fi
  HDIUTIL="$TOOL_ROOT/hdiutil"
  CODESIGN="$TOOL_ROOT/codesign"
  SPCTL="$TOOL_ROOT/spctl"
  XCRUN="$TOOL_ROOT/xcrun"
  XATTR="$TOOL_ROOT/xattr"
  SHASUM="$TOOL_ROOT/shasum"
  DITTO="$TOOL_ROOT/ditto"
  FILE_TOOL="$TOOL_ROOT/file"
else
  unset UTTERINK_FINAL_DMG_TEST_MODE UTTERINK_FINAL_DMG_TEST_TOOL_ROOT UTTERINK_FINAL_DMG_TEST_LOG UTTERINK_FINAL_DMG_TEST_SCENARIO
  HDIUTIL=/usr/bin/hdiutil
  CODESIGN=/usr/bin/codesign
  SPCTL=/usr/sbin/spctl
  XCRUN=/usr/bin/xcrun
  XATTR=/usr/bin/xattr
  SHASUM=/usr/bin/shasum
  DITTO=/usr/bin/ditto
  FILE_TOOL=/usr/bin/file
fi
readonly TEST_MODE HDIUTIL CODESIGN SPCTL XCRUN XATTR SHASUM DITTO FILE_TOOL

[[ -d /private/tmp && ! -L /private/tmp ]] || fail temporary-directory-unavailable 20
CONTROL="$(/usr/bin/mktemp -d /private/tmp/utterink-final-dmg.XXXXXX)" || fail temporary-directory-unavailable 20
[[ "$CONTROL" == /private/tmp/utterink-final-dmg.* && -d "$CONTROL" && ! -L "$CONTROL" ]] || fail temporary-directory-unavailable 20
/bin/chmod 0700 "$CONTROL" || fail temporary-directory-unavailable 20
MOUNT_ROOT="$CONTROL/mount-root"
PINNED_ROOT="$CONTROL/pinned"
COPIED_ROOT="$CONTROL/copied"
/bin/mkdir -m 0700 "$MOUNT_ROOT" "$PINNED_ROOT" "$COPIED_ROOT" || fail temporary-directory-unavailable 20
ATTACHED=0
ATTACH_DEVICE=''

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$ATTACHED" -eq 1 && "$ATTACH_DEVICE" =~ ^/dev/disk[0-9]+$ ]]; then
    "$HDIUTIL" detach "$ATTACH_DEVICE" -force >/dev/null 2>&1 || true
  fi
  if [[ -f "$CONTROL/evidence-state.json" && ! -L "$CONTROL/evidence-state.json" ]]; then
    /usr/bin/python3 -I - "$CONTROL/evidence-state.json" <<'PY' >/dev/null 2>&1 || true
import json,os,sys
import stat
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
def remove_created(record):
    if type(record) is not dict or set(record)!={"path","fingerprint"}: return
    raw=record.get("path"); expected=record.get("fingerprint")
    if type(raw) is not str or type(expected) is not list: return
    try:
        before=os.lstat(raw)
        if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
            or before.st_mode&0o077 or fp(before)!=expected): return
        with os.scandir(raw) as entries:
            if next(entries,None) is not None: return
        after=os.lstat(raw)
        if fp(after)!=expected: return
        os.rmdir(raw)
    except OSError: pass
try:
    value=json.load(open(sys.argv[1],encoding="utf-8"))
    created=value.get("created",[])
    if type(created) is not list: raise ValueError
    for record in reversed(created): remove_created(record)
except (OSError,ValueError,json.JSONDecodeError): pass
PY
  fi
  if [[ "$CONTROL" == /private/tmp/utterink-final-dmg.* && -d "$CONTROL" && ! -L "$CONTROL" ]]; then
    /bin/rm -rf -- "$CONTROL"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! /usr/bin/python3 -I - "$CONTROL/tools.json" "$HDIUTIL" "$CODESIGN" "$SPCTL" "$XCRUN" "$XATTR" "$SHASUM" "$DITTO" "$FILE_TOOL" <<'PY' >/dev/null 2>&1
import json,os,stat,sys
output=sys.argv[1]; paths=sys.argv[2:]
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
try:
    records={}
    for path in paths:
        item=os.lstat(path)
        if (not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid not in {0,os.geteuid()}
            or item.st_nlink!=1 or item.st_mode&0o022 or not item.st_mode&stat.S_IXUSR): raise ValueError
        records[path]=fp(item)
    raw=(json.dumps(records,sort_keys=True,separators=(",",":"))+"\n").encode()
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(fd,raw); os.close(fd)
except (OSError,ValueError): raise SystemExit(1)
PY
then fail tool-unavailable 20; fi

assert_tools_unchanged() {
  /usr/bin/python3 -I - "$CONTROL/tools.json" <<'PY' >/dev/null 2>&1
import json,os,sys
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
try:
    value=json.load(open(sys.argv[1],encoding="utf-8"))
    if type(value) is not dict or not value: raise ValueError
    for path,expected in value.items():
        item=os.lstat(path)
        if fp(item)!=expected: raise ValueError
except (OSError,ValueError,KeyError,json.JSONDecodeError): raise SystemExit(1)
PY
}
assert_tools_unchanged || fail tool-unavailable 20

assert_repository_binding() {
  /usr/bin/python3 -I - "$ROOT" "$CONTROL/repository.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import hashlib,json,os,re,stat,subprocess,sys
root=Path(sys.argv[1]); state_path=Path(sys.argv[2])
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def git(*args):
    result=subprocess.run(["/usr/bin/git","-C",str(root),*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
    if result.returncode: raise ValueError
    return result.stdout
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
try:
    commit=git("rev-parse","--verify","HEAD^{commit}").strip().decode("ascii")
    tree=git("rev-parse","HEAD^{tree}").strip().decode("ascii")
    if re.fullmatch(r"[0-9a-f]{40}",commit) is None or re.fullmatch(r"[0-9a-f]{40}",tree) is None or git("status","--porcelain=v1","--untracked-files=all")!=b"": raise ValueError
    records={}
    for relative in ("Scripts/release/verify-final-dmg.sh","Config/dmg-allowed-content.txt","docs/release/evidence-schema.json"):
        path=root/relative; before=os.lstat(path)
        if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
            or before.st_nlink!=1 or before.st_mode&0o022): raise ValueError
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd); chunks=[]
        while True:
            chunk=os.read(fd,65536)
            if not chunk: break
            chunks.append(chunk)
        after=os.fstat(fd); os.close(fd); data=b"".join(chunks)
        if fp(before)!=fp(opened) or fp(opened)!=fp(after): raise ValueError
        listing=git("ls-tree","-z",commit,"--",relative)
        if not listing.endswith(b"\0") or listing.count(b"\0")!=1: raise ValueError
        header,name=listing[:-1].split(b"\t",1); mode,kind,oid=header.split(b" ",2)
        if name.decode()!=relative or kind!=b"blob" or mode not in {b"100644",b"100755"}: raise ValueError
        if git("cat-file","blob",oid.decode("ascii"))!=data: raise ValueError
        records[relative]={"fingerprint":fp(before),"sha256":hashlib.sha256(data).hexdigest()}
    if (root/"Config/dmg-allowed-content.txt").read_bytes()!=b"Applications -> /Applications\nUtterInk.app directory\n": raise ValueError
    current={"candidateCommit":commit,"candidateTree":tree,"records":records}
    if state_path.exists():
        if json.loads(state_path.read_text(encoding="utf-8"))!=current: raise ValueError
    else:
        raw=(json.dumps(current,sort_keys=True,separators=(",",":"))+"\n").encode()
        fd=os.open(state_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(fd,raw); os.close(fd)
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): raise SystemExit(1)
PY
}
assert_repository_binding || fail repository-binding-invalid 20

if ! /usr/bin/python3 -I - "$ROOT" "$EVIDENCE_ARGUMENT" "$CONTROL/evidence-state.json" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePath
import json,os,stat,subprocess,sys
root=Path(sys.argv[1]); raw=sys.argv[2]; state=Path(sys.argv[3]); created=[]
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","GIT_NO_REPLACE_OBJECTS":"1","GIT_NO_LAZY_FETCH":"1","GIT_TERMINAL_PROMPT":"0"}
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
def remove_created(record):
    if type(record) is not dict or set(record)!={"path","fingerprint"}: return
    raw=record.get("path"); expected=record.get("fingerprint")
    if type(raw) is not str or type(expected) is not list: return
    try:
        before=os.lstat(raw)
        if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
            or before.st_mode&0o077 or fp(before)!=expected): return
        with os.scandir(raw) as entries:
            if next(entries,None) is not None: return
        after=os.lstat(raw)
        if fp(after)!=expected: return
        os.rmdir(raw)
    except OSError: pass
try:
    if (not raw or len(raw.encode("utf-8",errors="strict"))>4096 or any(ord(c)<32 or ord(c)==127 for c in raw)
        or ".." in PurePath(raw).parts): raise ValueError
    target=Path(os.path.abspath(raw if os.path.isabs(raw) else root/raw))
    relative=target.relative_to(root)
    if len(relative.parts)<2 or relative.parts[0] not in {".release-work",".release-evidence"}: raise ValueError
    checked=subprocess.run(["/usr/bin/git","-C",str(root),"check-ignore","-q","--",relative.as_posix()],env=env)
    if checked.returncode!=0: raise ValueError
    current=root
    for part in relative.parts:
        current=current/part
        try: item=os.lstat(current)
        except FileNotFoundError:
            os.mkdir(current,0o700); item=os.lstat(current); created.append({"path":str(current),"fingerprint":fp(item)})
        if (not stat.S_ISDIR(item.st_mode) or stat.S_ISLNK(item.st_mode) or item.st_uid!=os.geteuid()
            or item.st_mode&0o077 or current.resolve(strict=True)!=current): raise ValueError
    if any(os.scandir(target)): raise ValueError
    value={"created":created,"fingerprint":fp(os.lstat(target)),"path":str(target)}
    data=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
    fd=os.open(state,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(fd,data); os.close(fd)
except (OSError,RuntimeError,UnicodeError,ValueError):
    for record in reversed(created): remove_created(record)
    raise SystemExit(1)
PY
then fail unsafe-evidence 22; fi
EVIDENCE="$(/usr/bin/python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["path"])' "$CONTROL/evidence-state.json")"
[[ -n "$EVIDENCE" && -d "$EVIDENCE" && ! -L "$EVIDENCE" ]] || fail unsafe-evidence 22
readonly EVIDENCE

if [[ "$TEST_MODE" -eq 1 && "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-}" == evidence-created-dir-replace ]]; then
  if ! /usr/bin/python3 -I - "$CONTROL/evidence-state.json" <<'PY' >/dev/null 2>&1
from pathlib import Path
import json,os,stat,sys
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
try:
    value=json.load(open(sys.argv[1],encoding="utf-8")); created=value["created"]
    if type(created) is not list or not created: raise ValueError
    record=created[-1]
    if type(record) is not dict or set(record)!={"path","fingerprint"} or record["path"]!=value["path"]: raise ValueError
    target=Path(record["path"]); before=os.lstat(target)
    if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_uid!=os.geteuid()
        or before.st_mode&0o077 or fp(before)!=record["fingerprint"]): raise ValueError
    moved=target.with_name(target.name+".owned-moved")
    if os.path.lexists(moved): raise ValueError
    os.rename(target,moved); os.mkdir(target,0o700)
    replacement=os.lstat(target)
    if (not stat.S_ISDIR(replacement.st_mode) or stat.S_ISLNK(replacement.st_mode) or replacement.st_uid!=os.geteuid()
        or replacement.st_mode&0o077 or (replacement.st_dev,replacement.st_ino)==(before.st_dev,before.st_ino)): raise ValueError
except (OSError,KeyError,TypeError,ValueError,json.JSONDecodeError): raise SystemExit(1)
PY
  then fail unsafe-evidence 22; fi
fi

if ! DMG="$(/usr/bin/python3 -I - "$DMG_ARGUMENT" <<'PY' 2>/dev/null
from pathlib import Path
import os,stat,sys
raw=sys.argv[1]
try:
    if (not raw or len(raw.encode("utf-8",errors="strict"))>4096 or any(ord(c)<32 or ord(c)==127 for c in raw)): raise ValueError
    path=Path(raw)
    if path!=Path(os.path.abspath(path)) or path.name!="UtterInk-0.1.0-arm64.dmg" or path.suffix!=".dmg": raise ValueError
    item=os.lstat(path)
    if (not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode) or path.resolve(strict=True)!=path
        or item.st_uid!=os.geteuid() or item.st_nlink!=1 or item.st_mode&0o022
        or item.st_size<=0 or item.st_size>16*1024*1024*1024): raise ValueError
    print(path)
except (OSError,RuntimeError,UnicodeError,ValueError): raise SystemExit(1)
PY
)"; then fail unsafe-dmg 21; fi
readonly DMG
PINNED_DMG="$PINNED_ROOT/${DMG##*/}"
readonly PINNED_DMG

CANDIDATE="${DMG%/*}/candidate.json"
readonly CANDIDATE
assert_candidate_binding() {
  /usr/bin/python3 -I - "$CANDIDATE" "$CONTROL/repository.json" "$CONTROL/candidate-identity.json" <<'PY' >/dev/null 2>&1
import hashlib,json,os,re,stat,sys
path,state_path,identity_path=sys.argv[1:]
def abort(): raise SystemExit(1)
def unique(pairs):
    value={}
    for key,item in pairs:
        if key in value: abort()
        value[key]=item
    return value
def exact(value,keys):
    if type(value) is not dict or set(value)!=set(keys): abort()
    return value
def text(value,pattern):
    if type(value) is not str or re.fullmatch(pattern,value) is None: abort()
    return value
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
fd=-1
try:
    repository=json.load(open(state_path,encoding="utf-8")); before=os.lstat(path); fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd)
    if (not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(before.st_mode) or opened.st_uid!=os.geteuid() or opened.st_nlink!=1
        or opened.st_mode&0o022 or opened.st_size<=0 or opened.st_size>512*1024 or fp(before)!=fp(opened)): abort()
    chunks=[]; total=0
    while True:
        chunk=os.read(fd,65536)
        if not chunk: break
        total+=len(chunk)
        if total>512*1024: abort()
        chunks.append(chunk)
    after=os.fstat(fd); named=os.lstat(path)
    if fp(after)!=fp(opened) or fp(named)!=fp(opened): abort()
    raw=b"".join(chunks); value=json.loads(raw.decode("utf-8",errors="strict"),object_pairs_hook=unique)
    if raw!=(json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode("utf-8"): abort()
    value=exact(value,{"schemaVersion","evidenceType","product","source","release","toolchain","packageResolution","policies","checks"})
    if type(value["schemaVersion"]) is not int or value["schemaVersion"]!=1 or value["evidenceType"]!="release-candidate" or value["product"]!="UtterInk": abort()
    source=exact(value["source"],{"commit","tree","releaseTag","clean"})
    text(source["commit"],r"[0-9a-f]{40}"); text(source["tree"],r"[0-9a-f]{40}")
    if source!={"commit":repository["candidateCommit"],"tree":repository["candidateTree"],"releaseTag":"v0.1.0","clean":True}: abort()
    release=exact(value["release"],{"configuration","marketingVersion","buildNumber","bundleIdentifier","deploymentTarget","architecture","dmgFilename"})
    expected_release={"configuration":"Release","marketingVersion":"0.1.0","buildNumber":"1","bundleIdentifier":"dev.utterink.UtterInk","deploymentTarget":"14.0","architecture":"arm64","dmgFilename":"UtterInk-0.1.0-arm64.dmg"}
    if release!=expected_release or any(type(item) is not str for item in release.values()): abort()
    toolchain=exact(value["toolchain"],{"lockSHA256","xcodeVersion","xcodeBuild","sdkVersion","sdkBuild","swiftVersion","xcodegenVersion","xcodegenBinarySHA256"})
    text(toolchain["lockSHA256"],r"[0-9a-f]{64}"); text(toolchain["xcodegenBinarySHA256"],r"[0-9a-f]{64}")
    text(toolchain["sdkBuild"],r"[0-9]{2}[A-Z][0-9]{1,4}[a-z]?")
    text(toolchain["swiftVersion"],r"(?:swift-driver version: [0-9]+(?:\.[0-9]+)* )?Apple Swift version 6\.3(?:\.[0-9]+)* \(swiftlang-[A-Za-z0-9.]+ clang-[A-Za-z0-9.]+\)")
    if {key:toolchain[key] for key in ("xcodeVersion","xcodeBuild","sdkVersion","xcodegenVersion")}!={"xcodeVersion":"26.4.1","xcodeBuild":"17E202","sdkVersion":"26.4","xcodegenVersion":"2.45.4"}: abort()
    package=exact(value["packageResolution"],{"path","sha256"})
    if package["path"]!="Packages/UtterInkKit/Package.resolved": abort()
    text(package["sha256"],r"[0-9a-f]{64}")
    policies=exact(value["policies"],{"releaseMetadataSHA256","releaseEntitlementsSHA256","releaseInfoPolicySHA256","ciToolchainSHA256"})
    for item in policies.values(): text(item,r"[0-9a-f]{64}")
    checks=exact(value["checks"],{"history","metadata","entitlements","infoPolicy","packageResolution","generatedProjectClean"})
    if any(type(item) is not bool or item is not True for item in checks.values()): abort()
    identity={"candidateCommit":source["commit"],"candidateTree":source["tree"],"fingerprint":fp(opened),"sha256":hashlib.sha256(raw).hexdigest()}
    if os.path.exists(identity_path):
        if json.load(open(identity_path,encoding="utf-8"))!=identity: abort()
    else:
        encoded=(json.dumps(identity,sort_keys=True,separators=(",",":"))+"\n").encode(); output=os.open(identity_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(output,encoded); os.close(output)
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): abort()
finally:
    if fd>=0: os.close(fd)
PY
}
assert_candidate_binding || fail candidate-identity-invalid 23

assert_tools_unchanged || fail tool-unavailable 20
if ! /usr/bin/python3 -I - "$DMG" "$EXPECTED_SHA256" "$PINNED_DMG" "$CONTROL/dmg-state.json" "$SHASUM" <<'PY' >/dev/null 2>&1
import hashlib,json,os,re,stat,subprocess,sys
source,expected,snapshot,state,tool=sys.argv[1:]
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
source_fd=snapshot_fd=-1
try:
    before=os.lstat(source); source_fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(source_fd)
    if (not stat.S_ISREG(opened.st_mode) or fp(before)!=fp(opened) or opened.st_nlink!=1): raise ValueError
    result=subprocess.run([tool,"-a","256"],stdin=source_fd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    match=re.fullmatch(rb"([0-9a-f]{64})  -\n",result.stdout)
    if result.returncode or match is None or match.group(1).decode()!=expected: raise ValueError
    os.lseek(source_fd,0,os.SEEK_SET); snapshot_fd=os.open(snapshot,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o400); digest=hashlib.sha256()
    while True:
        chunk=os.read(source_fd,1024*1024)
        if not chunk: break
        digest.update(chunk); view=memoryview(chunk)
        while view:
            count=os.write(snapshot_fd,view)
            if count<=0: raise ValueError
            view=view[count:]
    os.fsync(snapshot_fd); source_after=os.fstat(source_fd); path_after=os.lstat(source); snapshot_after=os.fstat(snapshot_fd)
    if (fp(source_after)!=fp(opened) or fp(path_after)!=fp(opened) or not stat.S_ISREG(snapshot_after.st_mode)
        or snapshot_after.st_nlink!=1 or snapshot_after.st_size!=opened.st_size or digest.hexdigest()!=expected): raise ValueError
    value={"fingerprint":fp(opened),"sha256":expected,"sizeBytes":opened.st_size,"snapshotFingerprint":fp(snapshot_after)}
    raw=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode(); fd=os.open(state,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(fd,raw); os.close(fd)
except (OSError,ValueError): raise SystemExit(1)
finally:
    if snapshot_fd>=0: os.close(snapshot_fd)
    if source_fd>=0: os.close(source_fd)
PY
then fail initial-hash-mismatch 30; fi

assert_tools_unchanged || fail tool-unavailable 20
if ! "$XCRUN" stapler validate "$PINNED_DMG" >"$CONTROL/stapler.out" 2>"$CONTROL/stapler.err"; then
  fail staple-validation-failed 31
fi

assert_tools_unchanged || fail tool-unavailable 20
if ! "$HDIUTIL" attach -readonly -nobrowse -noautoopen -owners on -mountroot "$MOUNT_ROOT" -plist "$PINNED_DMG" \
  >"$CONTROL/attach.plist" 2>"$CONTROL/attach.err"; then
  fail readonly-mount-failed 32
fi
ATTACHED=1
if ! /usr/bin/python3 -I - "$CONTROL/attach.plist" "$MOUNT_ROOT" "$CONTROL/attach-device" "$CONTROL/mount-point" "$TEST_MODE" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,plistlib,re,stat,sys
source=Path(sys.argv[1]); mount_root=Path(sys.argv[2]); device_out=Path(sys.argv[3]); mount_out=Path(sys.argv[4]); test_mode=sys.argv[5]=="1"
try:
    if source.stat().st_size>1024*1024: raise ValueError
    with source.open("rb") as stream: value=plistlib.load(stream)
    entities=value.get("system-entities") if type(value) is dict else None
    if type(entities) is not list or not 1<=len(entities)<=16 or any(type(x) is not dict for x in entities): raise ValueError
    pattern=re.compile(r"/dev/(disk[0-9]+)(?:s[0-9]+)?")
    devices=[]; whole=[]; mounted=[]; bases=[]
    for entity in entities:
        item=entity.get("dev-entry")
        if type(item) is not str: raise ValueError
        match=pattern.fullmatch(item)
        if match is None: raise ValueError
        devices.append(item); bases.append(match.group(1))
        if item==f"/dev/{match.group(1)}": whole.append(item)
        if entity.get("mount-point") is not None: mounted.append(entity)
    if len(devices)!=len(set(devices)) or len(whole)!=1 or len(set(bases))!=1: raise ValueError
    device_out.write_text(whole[0]+"\n",encoding="ascii")
    if len(mounted)!=1 or mounted[0].get("content-hint") not in {"Apple_HFS","Apple_HFSX"}: raise ValueError
    mount=Path(mounted[0]["mount-point"]); resolved_root=mount_root.resolve(strict=True)
    if (mount!=Path(os.path.abspath(mount)) or mount.parent!=resolved_root or mount.name!="UtterInk"
        or mount.is_symlink() or not mount.is_dir() or mount.resolve(strict=True)!=mount): raise ValueError
    if not test_mode and not os.path.ismount(mount): raise ValueError
    mount_out.write_text(str(mount)+"\n",encoding="utf-8")
except (OSError,RuntimeError,TypeError,ValueError,plistlib.InvalidFileException): raise SystemExit(1)
PY
then
  if [[ -f "$CONTROL/attach-device" && ! -L "$CONTROL/attach-device" ]]; then ATTACH_DEVICE="$(/bin/cat "$CONTROL/attach-device")"; fi
  fail readonly-mount-failed 32
fi
ATTACH_DEVICE="$(/bin/cat "$CONTROL/attach-device")"
MOUNT_POINT="$(/bin/cat "$CONTROL/mount-point")"
[[ "$ATTACH_DEVICE" =~ ^/dev/disk[0-9]+$ && -d "$MOUNT_POINT" && ! -L "$MOUNT_POINT" ]] || fail readonly-mount-failed 32

if ! /usr/bin/python3 -I - "$MOUNT_POINT" "$CONTROL/bundle-signables.nul" "$CONTROL/regular-files.nul" "$CONTROL/app-tree.json" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePosixPath
import hashlib,json,os,stat,sys
mount=Path(sys.argv[1]); signable_out=Path(sys.argv[2]); regular_out=Path(sys.argv[3]); tree_out=Path(sys.argv[4])
bundle_suffixes={".app",".appex",".bundle",".framework",".plugin",".xpc"}
def abort(): raise SystemExit(1)
def unsafe_name(name): return not name or name in {".",".."} or any(ord(c)<32 or ord(c)==127 for c in name)
try:
    entries=sorted(os.scandir(mount),key=lambda x:x.name.encode("utf-8",errors="strict"))
    actual=[]
    for entry in entries:
        if unsafe_name(entry.name): abort()
        item=entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(item.st_mode): actual.append(f"{entry.name} -> {os.readlink(entry.path)}")
        elif stat.S_ISDIR(item.st_mode): actual.append(f"{entry.name} directory")
        else: actual.append(f"{entry.name} file")
    if actual != ["Applications -> /Applications","UtterInk.app directory"]: abort()
    applications=mount/"Applications"; app=mount/"UtterInk.app"
    if not applications.is_symlink() or os.readlink(applications)!="/Applications": abort()
    app_item=os.lstat(app)
    if not stat.S_ISDIR(app_item.st_mode) or stat.S_ISLNK(app_item.st_mode): abort()
    app_resolved=app.resolve(strict=True); records=[]; signables=[app]; regulars=[]
    def walk(directory,relative):
        for entry in sorted(os.scandir(directory),key=lambda x:x.name.encode("utf-8",errors="strict")):
            if unsafe_name(entry.name): abort()
            path=Path(entry.path); rel=PurePosixPath(relative,entry.name) if relative else PurePosixPath(entry.name)
            item=entry.stat(follow_symlinks=False); mode=stat.S_IMODE(item.st_mode)
            if item.st_mode&0o022: abort()
            if stat.S_ISLNK(item.st_mode):
                target=os.readlink(path); target_path=PurePosixPath(target)
                if not target or target_path.is_absolute() or ".." in target_path.parts: abort()
                try: path.resolve(strict=True).relative_to(app_resolved)
                except (OSError,RuntimeError,ValueError): abort()
                records.append([rel.as_posix(),"symlink",mode,target])
            elif stat.S_ISDIR(item.st_mode):
                records.append([rel.as_posix(),"directory",mode,""])
                if path.suffix.lower() in bundle_suffixes: signables.append(path)
                walk(path,rel)
            elif stat.S_ISREG(item.st_mode):
                if item.st_nlink!=1: abort()
                digest=hashlib.sha256()
                fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
                while True:
                    chunk=os.read(fd,65536)
                    if not chunk: break
                    digest.update(chunk)
                os.close(fd); records.append([rel.as_posix(),"file",mode,digest.hexdigest()])
                regulars.append(path)
            else: abort()
    walk(app,PurePosixPath())
    required={"Contents/Info.plist","Contents/MacOS/UtterInk"}
    if not required.issubset({row[0] for row in records if row[1]=="file"}): abort()
    main=os.lstat(app/"Contents/MacOS/UtterInk")
    if not main.st_mode&0o111: abort()
    unique={str(path):path for path in signables}
    ordered=sorted(unique.values(),key=lambda p:(-len(p.relative_to(mount).parts),p.relative_to(mount).as_posix().encode("utf-8")))
    with signable_out.open("wb") as stream:
        for path in ordered: stream.write(os.fsencode(path)+b"\0")
    with regular_out.open("wb") as stream:
        for path in sorted(regulars,key=lambda p:p.relative_to(mount).as_posix().encode("utf-8")): stream.write(os.fsencode(path)+b"\0")
    records.sort(key=lambda row:row[0].encode("utf-8"))
    tree_out.write_text(json.dumps(records,separators=(",",":"))+"\n",encoding="utf-8")
except (OSError,RuntimeError,UnicodeError,ValueError): abort()
PY
then fail manifest-validation-failed 33; fi

: > "$CONTROL/mach-o-signables.nul"
while IFS= read -r -d '' regular_file; do
  assert_tools_unchanged || fail tool-unavailable 20
  if ! "$FILE_TOOL" -b "$regular_file" >"$CONTROL/file-description" 2>"$CONTROL/file-error"; then
    fail signature-validation-failed 34
  fi
  if ! /usr/bin/python3 -I - "$CONTROL/file-description" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys
try:
    raw=Path(sys.argv[1]).read_bytes()
    if not raw or len(raw)>4096 or b"\0" in raw: raise ValueError
except (OSError,ValueError): raise SystemExit(1)
PY
  then fail signature-validation-failed 34; fi
  if /usr/bin/grep -Fq 'Mach-O' "$CONTROL/file-description"; then
    /usr/bin/printf '%s\0' "$regular_file" >> "$CONTROL/mach-o-signables.nul"
  fi
done < "$CONTROL/regular-files.nul"
if ! /usr/bin/python3 -I - "$MOUNT_POINT" "$CONTROL/bundle-signables.nul" "$CONTROL/mach-o-signables.nul" "$CONTROL/signables.nul" <<'PY' >/dev/null 2>&1
from pathlib import Path
import os,sys
mount=Path(sys.argv[1]).resolve(strict=True); sources=sys.argv[2:4]; output=Path(sys.argv[4])
try:
    paths=[]; machos=[]
    for index,source in enumerate(sources):
        raw=Path(source).read_bytes()
        if raw and not raw.endswith(b"\0"): raise ValueError
        for item in raw.split(b"\0")[:-1]:
            path=Path(os.fsdecode(item)); path.resolve(strict=True).relative_to(mount); paths.append(path)
            if index==1: machos.append(path)
    if mount/"UtterInk.app/Contents/MacOS/UtterInk" not in machos: raise ValueError
    unique={os.fsencode(path):path for path in paths}
    ordered=sorted(unique.values(),key=lambda p:(-len(p.relative_to(mount).parts),p.relative_to(mount).as_posix().encode("utf-8")))
    with output.open("wb") as stream:
        for path in ordered: stream.write(os.fsencode(path)+b"\0")
except (OSError,RuntimeError,UnicodeError,ValueError): raise SystemExit(1)
PY
then fail signature-validation-failed 34; fi

SIGNATURE_COMPONENT_COUNT=0
assert_tools_unchanged || fail tool-unavailable 20
if ! "$CODESIGN" --verify --strict --verbose=4 "$PINNED_DMG" >"$CONTROL/codesign-dmg.out" 2>"$CONTROL/codesign-dmg.err"; then
  fail signature-validation-failed 34
fi
SIGNATURE_COMPONENT_COUNT=1
while IFS= read -r -d '' component; do
  assert_tools_unchanged || fail tool-unavailable 20
  SIGNATURE_COMPONENT_COUNT=$((SIGNATURE_COMPONENT_COUNT + 1))
  if ! "$CODESIGN" --verify --strict --verbose=4 "$component" >"$CONTROL/codesign-component.out" 2>"$CONTROL/codesign-component.err"; then
    fail signature-validation-failed 34
  fi
done < "$CONTROL/signables.nul"
[[ "$SIGNATURE_COMPONENT_COUNT" -ge 3 ]] || fail signature-validation-failed 34

assert_tools_unchanged || fail tool-unavailable 20
if ! "$SPCTL" --assess --type open --context context:primary-signature --verbose=4 "$PINNED_DMG" \
  >"$CONTROL/spctl-dmg.out" 2>"$CONTROL/spctl-dmg.err"; then
  fail dmg-gatekeeper-assessment-failed 35
fi

COPIED_APP="$COPIED_ROOT/UtterInk.app"
if ! "$DITTO" "$MOUNT_POINT/UtterInk.app" "$COPIED_APP" >"$CONTROL/ditto.out" 2>"$CONTROL/ditto.err"; then
  fail app-gatekeeper-assessment-failed 36
fi
if ! /usr/bin/python3 -I - "$COPIED_APP" "$CONTROL/app-tree.json" <<'PY' >/dev/null 2>&1
from pathlib import Path,PurePosixPath
import hashlib,json,os,stat,sys
app=Path(sys.argv[1]); expected=json.load(open(sys.argv[2],encoding="utf-8")); root=app.resolve(strict=True); records=[]
def abort(): raise SystemExit(1)
def walk(directory,relative):
    for entry in sorted(os.scandir(directory),key=lambda x:x.name.encode("utf-8",errors="strict")):
        path=Path(entry.path); rel=PurePosixPath(relative,entry.name) if relative else PurePosixPath(entry.name); item=entry.stat(follow_symlinks=False); mode=stat.S_IMODE(item.st_mode)
        if stat.S_ISLNK(item.st_mode):
            target=os.readlink(path); target_path=PurePosixPath(target)
            if not target or target_path.is_absolute() or ".." in target_path.parts: abort()
            try: path.resolve(strict=True).relative_to(root)
            except (OSError,RuntimeError,ValueError): abort()
            records.append([rel.as_posix(),"symlink",mode,target])
        elif stat.S_ISDIR(item.st_mode): records.append([rel.as_posix(),"directory",mode,""]); walk(path,rel)
        elif stat.S_ISREG(item.st_mode):
            digest=hashlib.sha256(); fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
            while True:
                chunk=os.read(fd,65536)
                if not chunk: break
                digest.update(chunk)
            os.close(fd); records.append([rel.as_posix(),"file",mode,digest.hexdigest()])
        else: abort()
try:
    if app.is_symlink() or not app.is_dir(): abort()
    walk(app,PurePosixPath()); records.sort(key=lambda row:row[0].encode("utf-8"))
    if records!=expected: abort()
except (OSError,RuntimeError,UnicodeError,ValueError): abort()
PY
then fail app-gatekeeper-assessment-failed 36; fi
assert_tools_unchanged || fail tool-unavailable 20
if ! "$SPCTL" --assess --type execute --verbose=4 "$COPIED_APP" >"$CONTROL/spctl-app.out" 2>"$CONTROL/spctl-app.err"; then
  fail app-gatekeeper-assessment-failed 36
fi

assert_tools_unchanged || fail tool-unavailable 20
if ! /usr/bin/python3 -I - "$DMG" "$CONTROL/dmg-state.json" "$XATTR" "$TEST_MODE" "$CONTROL/quarantine-state" <<'PY' >/dev/null 2>&1
import ctypes,json,os,stat,subprocess,sys
source,state_path,tool=sys.argv[1:4]; mode=sys.argv[4]; destination=sys.argv[5]
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
def fd_names(fd):
    library=ctypes.CDLL(None,use_errno=True); function=library.flistxattr
    function.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int]; function.restype=ctypes.c_ssize_t
    size=function(fd,None,0,0)
    if size<0 or size>64*1024: raise OSError(ctypes.get_errno(),"flistxattr")
    if size==0: return []
    buffer=ctypes.create_string_buffer(size); actual=function(fd,buffer,size,0)
    if actual!=size: raise OSError(ctypes.get_errno(),"flistxattr")
    raw=bytes(buffer.raw[:actual]); names=raw.split(b"\0")
    if not names or names[-1]!=b"" or any(not name for name in names[:-1]): raise ValueError
    return sorted(name.decode("utf-8",errors="strict") for name in names[:-1])
descriptor=-1
try:
    state=json.load(open(state_path,encoding="utf-8")); before=os.lstat(source); descriptor=os.open(source,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or fp(before)!=state["fingerprint"] or fp(opened)!=state["fingerprint"]: raise ValueError
    if mode not in {"0","1"}: raise ValueError
    authoritative_before=fd_names(descriptor)
    result=subprocess.run([tool,source],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    authoritative_after=fd_names(descriptor)
    after=os.fstat(descriptor); path_after=os.lstat(source)
    if result.returncode or fp(after)!=state["fingerprint"] or fp(path_after)!=state["fingerprint"]: raise ValueError
    raw=result.stdout
    if len(raw)>64*1024 or b"\0" in raw: raise ValueError
    text=raw.decode("utf-8",errors="strict"); lines=text.splitlines()
    if text and not text.endswith("\n"): raise ValueError
    if len(lines)!=len(set(lines)) or any(not line or len(line.encode())>1024 or any(ord(c)<32 or ord(c)==127 for c in line) for line in lines): raise ValueError
    if authoritative_before!=authoritative_after or sorted(lines)!=authoritative_before: raise ValueError
    lines=authoritative_before
    value="present" if "com.apple.quarantine" in lines else "absent"
    fd=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600); os.write(fd,(value+"\n").encode()); os.close(fd)
except (OSError,UnicodeError,ValueError,KeyError,json.JSONDecodeError): raise SystemExit(1)
finally:
    if descriptor>=0: os.close(descriptor)
PY
then fail metadata-inspection-failed 37; fi

if ! "$HDIUTIL" detach "$ATTACH_DEVICE" >"$CONTROL/detach.out" 2>"$CONTROL/detach.err"; then
  fail detach-failed 39
fi
ATTACHED=0

assert_tools_unchanged || fail tool-unavailable 20
if ! /usr/bin/python3 -I - "$DMG" "$PINNED_DMG" "$EXPECTED_SHA256" "$CONTROL/dmg-state.json" "$SHASUM" <<'PY' >/dev/null 2>&1
import hashlib,json,os,re,stat,subprocess,sys
source,snapshot,expected,state_path,tool=sys.argv[1:]
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
fd=-1
try:
    state=json.load(open(state_path,encoding="utf-8")); before=os.lstat(source); fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd)
    if (not stat.S_ISREG(opened.st_mode) or fp(before)!=state["fingerprint"] or fp(opened)!=state["fingerprint"]): raise ValueError
    result=subprocess.run([tool,"-a","256"],stdin=fd,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); after=os.fstat(fd); path_after=os.lstat(source)
    match=re.fullmatch(rb"([0-9a-f]{64})  -\n",result.stdout)
    if (result.returncode or match is None or match.group(1).decode()!=expected or expected!=state["sha256"]
        or fp(after)!=state["fingerprint"] or fp(path_after)!=state["fingerprint"]): raise ValueError
    snapshot_before=os.lstat(snapshot); snapshot_fd=os.open(snapshot,os.O_RDONLY|os.O_NOFOLLOW); snapshot_opened=os.fstat(snapshot_fd); digest=hashlib.sha256()
    while True:
        chunk=os.read(snapshot_fd,1024*1024)
        if not chunk: break
        digest.update(chunk)
    snapshot_after=os.fstat(snapshot_fd); os.close(snapshot_fd)
    if (fp(snapshot_before)!=state["snapshotFingerprint"] or fp(snapshot_opened)!=state["snapshotFingerprint"]
        or fp(snapshot_after)!=state["snapshotFingerprint"] or digest.hexdigest()!=expected): raise ValueError
except (OSError,ValueError,KeyError,json.JSONDecodeError): raise SystemExit(1)
finally:
    if fd>=0: os.close(fd)
PY
then fail final-hash-mismatch 38; fi

assert_tools_unchanged || fail tool-unavailable 20
assert_candidate_binding || fail candidate-identity-invalid 23
assert_repository_binding || fail repository-binding-invalid 20
QUARANTINE_STATE="$(/usr/bin/tr -d '\n' < "$CONTROL/quarantine-state")"
[[ "$QUARANTINE_STATE" == present || "$QUARANTINE_STATE" == absent ]] || fail evidence-write-failed 40
if ! /usr/bin/python3 -I - "$CONTROL/repository.json" "$CONTROL/dmg-state.json" "$CONTROL/evidence-state.json" "$EXPECTED_SHA256" "$SIGNATURE_COMPONENT_COUNT" "$QUARANTINE_STATE" "$TEST_MODE" "${UTTERINK_FINAL_DMG_TEST_SCENARIO:-}" <<'PY' 2>/dev/null
import json,os,re,secrets,stat,sys
repository=json.load(open(sys.argv[1],encoding="utf-8")); dmg=json.load(open(sys.argv[2],encoding="utf-8")); evidence=json.load(open(sys.argv[3],encoding="utf-8")); expected=sys.argv[4]
count=int(sys.argv[5]); quarantine=sys.argv[6]; test_mode=sys.argv[7]=="1"; scenario=sys.argv[8]
directory_fd=-1; output_fd=-1; published_fd=-1; owned_identity=None; temporary_name=None
final_name="final-dmg-verification.json"
def fp(x): return [x.st_dev,x.st_ino,x.st_mode,x.st_uid,x.st_gid,x.st_nlink,x.st_size,x.st_mtime_ns,x.st_ctime_ns,getattr(x,"st_flags",0)]
def named(name): return os.stat(name,dir_fd=directory_fd,follow_symlinks=False)
def owned_unlink(name):
    if name is None or owned_identity is None: return
    try:
        item=named(name)
        if stat.S_ISREG(item.st_mode) and (item.st_dev,item.st_ino)==owned_identity:
            os.unlink(name,dir_fd=directory_fd)
    except OSError: pass
try:
    commit=repository["candidateCommit"]
    if re.fullmatch(r"[0-9a-f]{40}",commit) is None or dmg["sha256"]!=expected or count<3 or quarantine not in {"present","absent"}: raise ValueError
    value={
        "appGatekeeperAssessment":"accepted",
        "candidateCommit":commit,
        "dmgFilename":"UtterInk-0.1.0-arm64.dmg",
        "dmgGatekeeperAssessment":"accepted",
        "dmgSHA256":expected,
        "dmgSizeBytes":dmg["sizeBytes"],
        "evidenceType":"final-dmg-verification",
        "hashAfterVerification":expected,
        "hashBeforeVerification":expected,
        "manifest":["Applications -> /Applications","UtterInk.app directory"],
        "mountMode":"read-only",
        "originalArtifactUnchanged":True,
        "originalQuarantineState":quarantine,
        "product":"UtterInk",
        "schemaVersion":1,
        "signatureComponentCount":count,
        "stapleValidation":"passed",
        "status":"valid",
        "strictSignatureValidation":"passed",
    }
    raw=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
    users_prefix=b"/"+b"Users"+b"/"
    if any(marker in raw for marker in (users_prefix,b"/private/tmp/",b"mount-root",b"Authority=",b"TeamIdentifier=")): raise ValueError
    directory=evidence["path"]; before=os.lstat(directory)
    if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode) or fp(before)!=evidence["fingerprint"]
        or before.st_uid!=os.geteuid() or before.st_mode&0o077): raise ValueError
    directory_fd=os.open(directory,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|os.O_NOFOLLOW); opened=os.fstat(directory_fd)
    if fp(opened)!=evidence["fingerprint"] or os.listdir(directory_fd): raise ValueError
    if test_mode and scenario=="evidence-write-failure":
        canary=os.open("concurrent-canary",os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory_fd)
        os.write(canary,b"concurrent-canary\n"); os.fsync(canary); os.close(canary)
    temporary_name=f".final-dmg-verification.{secrets.token_hex(32)}.tmp"
    output_fd=os.open(temporary_name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory_fd)
    os.fchmod(output_fd,0o600); output_identity=os.fstat(output_fd); owned_identity=(output_identity.st_dev,output_identity.st_ino)
    if (not stat.S_ISREG(output_identity.st_mode) or output_identity.st_nlink!=1
        or output_identity.st_uid!=os.geteuid() or stat.S_IMODE(output_identity.st_mode)!=0o600): raise ValueError
    if test_mode and scenario=="evidence-partial-write-failure":
        os.write(output_fd,raw[:17]); os.fsync(output_fd); raise OSError
    view=memoryview(raw)
    while view:
        written=os.write(output_fd,view)
        if written<=0: raise OSError
        view=view[written:]
    os.fsync(output_fd); os.lseek(output_fd,0,os.SEEK_SET); observed=b""
    while len(observed)<len(raw):
        chunk=os.read(output_fd,min(65536,len(raw)-len(observed)))
        if not chunk: break
        observed+=chunk
    final=os.fstat(output_fd); temporary_item=named(temporary_name)
    if (observed!=raw or fp(final)!=fp(temporary_item) or (final.st_dev,final.st_ino)!=owned_identity
        or not stat.S_ISREG(final.st_mode) or final.st_nlink!=1 or final.st_uid!=os.geteuid()
        or stat.S_IMODE(final.st_mode)!=0o600 or final.st_size!=len(raw)): raise ValueError
    os.fsync(directory_fd)
    if os.listdir(directory_fd)!=[temporary_name]: raise ValueError
    os.link(temporary_name,final_name,src_dir_fd=directory_fd,dst_dir_fd=directory_fd,follow_symlinks=False)
    linked=named(final_name)
    if (linked.st_dev,linked.st_ino)!=owned_identity or linked.st_nlink!=2: raise ValueError
    os.unlink(temporary_name,dir_fd=directory_fd); temporary_name=None; os.fsync(directory_fd)
    if test_mode and scenario=="evidence-final-replace":
        os.unlink(final_name,dir_fd=directory_fd)
        replacement=os.open(final_name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory_fd)
        os.write(replacement,b"concurrent-replacement\n"); os.fsync(replacement); os.close(replacement)
    elif test_mode and scenario=="evidence-final-remove":
        os.unlink(final_name,dir_fd=directory_fd)
    published_before=named(final_name); published_fd=os.open(final_name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=directory_fd)
    published_opened=os.fstat(published_fd); published=b""
    while len(published)<len(raw):
        chunk=os.read(published_fd,min(65536,len(raw)-len(published)))
        if not chunk: break
        published+=chunk
    published_after=os.fstat(published_fd); os.close(published_fd); published_fd=-1; published_named=named(final_name)
    owned_after=os.fstat(output_fd)
    if (published!=raw or fp(published_before)!=fp(published_opened) or fp(published_opened)!=fp(published_after)
        or fp(published_after)!=fp(published_named) or fp(published_named)!=fp(owned_after)
        or (published_named.st_dev,published_named.st_ino)!=owned_identity
        or not stat.S_ISREG(published_named.st_mode) or published_named.st_nlink!=1
        or published_named.st_uid!=os.geteuid() or stat.S_IMODE(published_named.st_mode)!=0o600
        or published_named.st_size!=len(raw) or os.listdir(directory_fd)!=[final_name]): raise ValueError
    os.fsync(directory_fd); directory_named=os.lstat(directory)
    if (not stat.S_ISDIR(directory_named.st_mode) or stat.S_ISLNK(directory_named.st_mode)
        or (directory_named.st_dev,directory_named.st_ino)!=(before.st_dev,before.st_ino)
        or directory_named.st_uid!=os.geteuid() or directory_named.st_mode&0o077): raise ValueError
    os.close(output_fd); output_fd=-1
    os.write(1,raw)
except (OSError,ValueError,KeyError,json.JSONDecodeError):
    if directory_fd>=0:
        owned_unlink(temporary_name); owned_unlink(final_name)
        try: os.fsync(directory_fd)
        except OSError: pass
    if published_fd>=0:
        try: os.close(published_fd)
        except OSError: pass
    if output_fd>=0:
        try: os.close(output_fd)
        except OSError: pass
    raise SystemExit(1)
finally:
    if directory_fd>=0:
        try: os.close(directory_fd)
        except OSError: pass
PY
then fail evidence-write-failed 40; fi
