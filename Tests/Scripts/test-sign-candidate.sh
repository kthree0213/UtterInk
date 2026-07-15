#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SIGNER="$ROOT/Scripts/release/sign-candidate.sh"

fail() {
  printf 'sign candidate tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$SIGNER" ]] || fail 'Scripts/release/sign-candidate.sh is missing or not executable'

TMP="$(/usr/bin/mktemp -d /private/tmp/utterink-sign-candidate-tests.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap '/bin/rm -rf "$TMP"' EXIT
BASE="$TMP/base"
LOG="$TMP/tools.log"
STDOUT="$TMP/stdout"
STDERR="$TMP/stderr"
ORDINARY_LOG="$TMP/ordinary.log"
BASH_ENV_CANARY="$TMP/hostile-bash-env"
BASH_ENV_MARKER="$TMP/bash-env-loaded"
IDENTITY='Developer ID Application: Fixture Author (ABCDE12345)'
TEAM_ID='ABCDE12345'

/bin/mkdir -p \
  "$BASE/App/Supporting" \
  "$BASE/Config" \
  "$BASE/FixtureTools" \
  "$BASE/OrdinaryPath" \
  "$BASE/Scripts/release" \
  "$BASE/.release-work"
/bin/cp "$SIGNER" "$BASE/Scripts/release/sign-candidate.sh"
/bin/cp "$ROOT/App/Supporting/UtterInk.entitlements" "$BASE/App/Supporting/UtterInk.entitlements"
/bin/cp "$ROOT/Config/release-entitlements.json" "$BASE/Config/release-entitlements.json"
/bin/cp "$ROOT/Scripts/release/verify-entitlements.py" "$BASE/Scripts/release/verify-entitlements.py"
/bin/cp "$ROOT/Scripts/release/verify-signatures.sh" "$BASE/Scripts/release/verify-signatures.sh"
/bin/chmod 0755 "$BASE/Scripts/release/sign-candidate.sh"
printf 'utterink-offline-signing-fixture-v1\n' > "$BASE/FixtureTools/.utterink-signing-test-fixture"
printf 'printf loaded > %q\n' "$BASH_ENV_MARKER" > "$BASH_ENV_CANARY"

cat > "$BASE/FixtureTools/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'security' >> "${UTTERINK_FIXTURE_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$UTTERINK_FIXTURE_LOG"; done
printf '\n' >> "$UTTERINK_FIXTURE_LOG"
identity='Developer ID Application: Fixture Author (ABCDE12345)'
case "${1-}" in
  find-identity)
    [[ "$*" == 'find-identity -v -p codesigning' ]]
    if [[ -f "$UTTERINK_FIXTURE_LOG.pause-identity" ]]; then
      : > "$UTTERINK_FIXTURE_LOG.signal-ready"
      while [[ ! -f "$UTTERINK_FIXTURE_LOG.signal-continue" ]]; do
        /bin/sleep 0.01
      done
    fi
    if [[ -f "$UTTERINK_FIXTURE_LOG.missing-private-key" ]]; then
      printf '     0 valid identities found\n'
      exit 0
    fi
    printf '  1) 1111111111111111111111111111111111111111 "%s"\n' "$identity"
    if [[ -f "$UTTERINK_FIXTURE_LOG.duplicate-identity" ]]; then
      printf '  2) 2222222222222222222222222222222222222222 "%s"\n' "$identity"
    fi
    printf '     1 valid identities found\n'
    ;;
  find-certificate)
    [[ "${2-}" == '-a' && "${3-}" == '-c' && "${4-}" == "$identity" && "${5-}" == '-p' ]]
    printf '%s\n' \
      '-----BEGIN CERTIFICATE-----' \
      'RklYVFVSRQ==' \
      '-----END CERTIFICATE-----'
    ;;
  verify-cert)
    [[ "${2-}" == '-c' && -f "${3-}" && "${4-}" == '-p' && "${5-}" == codeSign ]]
    [[ ! -f "$UTTERINK_FIXTURE_LOG.untrusted" ]]
    ;;
  *) exit 64 ;;
esac
EOF

cat > "$BASE/FixtureTools/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lipo' >> "${UTTERINK_FIXTURE_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$UTTERINK_FIXTURE_LOG"; done
printf '\n' >> "$UTTERINK_FIXTURE_LOG"
[[ "$#" -eq 2 && "$1" == -archs && -f "$2" ]]
if [[ -f "$UTTERINK_FIXTURE_LOG.universal" && "$2" == */Contents/MacOS/UtterInk ]]; then
  printf 'arm64 x86_64\n'
else
  printf 'arm64\n'
fi
EOF

cat > "$BASE/FixtureTools/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'openssl' >> "${UTTERINK_FIXTURE_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$UTTERINK_FIXTURE_LOG"; done
printf '\n' >> "$UTTERINK_FIXTURE_LOG"
[[ "${1-}" == x509 && "${2-}" == -in && -f "${3-}" ]]
case "$*" in
  *'-fingerprint -sha1'*)
    if [[ -f "$UTTERINK_FIXTURE_LOG.certificate-sha1-mismatch" ]]; then
      printf 'sha1 Fingerprint=22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22\n'
    else
      printf 'sha1 Fingerprint=11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11\n'
    fi
    ;;
  *'-fingerprint -sha256'*)
    printf 'sha256 Fingerprint=BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB\n'
    ;;
  *'-subject -nameopt sep_multiline'*)
    printf '%s\n' \
      'subject=' \
      '    commonName = Developer ID Application: Fixture Author (ABCDE12345)'
    if [[ -f "$UTTERINK_FIXTURE_LOG.ou-mismatch" ]]; then
      printf '    organizationalUnitName = WRONG12345\n'
    else
      printf '    organizationalUnitName = ABCDE12345\n'
    fi
    ;;
  *'-checkend 0 -noout'*)
    [[ ! -f "$UTTERINK_FIXTURE_LOG.expired" ]]
    ;;
  *) exit 64 ;;
esac
EOF

cat > "$BASE/FixtureTools/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'file' >> "${UTTERINK_FIXTURE_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$UTTERINK_FIXTURE_LOG"; done
printf '\n' >> "$UTTERINK_FIXTURE_LOG"
path="${*: -1}"
case "$path" in
  */Contents/MacOS/UtterInk)
    if [[ -f "$UTTERINK_FIXTURE_LOG.non-macho-main" ]]; then
      printf 'ASCII text\n'
    else
      printf 'Mach-O 64-bit executable arm64\n'
    fi
    ;;
  */A.framework/A|*/B.framework/Versions/A/B|*/B.framework/Versions/A/Helpers/BHelper)
    printf 'Mach-O 64-bit executable arm64\n'
    ;;
  *) printf 'ASCII text\n' ;;
esac
EOF

cat > "$BASE/FixtureTools/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign' >> "${UTTERINK_FIXTURE_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$UTTERINK_FIXTURE_LOG"; done
printf '\n' >> "$UTTERINK_FIXTURE_LOG"
identity=''
target="${*: -1}"
has_runtime=0
has_timestamp=0
has_entitlements=0
previous=''
for argument in "$@"; do
  [[ "$argument" != --deep ]] || exit 91
  if [[ "$previous" == --sign ]]; then identity="$argument"; fi
  if [[ "$previous" == --options && "$argument" == runtime ]]; then has_runtime=1; fi
  if [[ "$previous" == --entitlements ]]; then
    has_entitlements=1
    case "$argument" in
      /private/tmp/utterink-sign-candidate.*/reviewed-root/App/Supporting/UtterInk.entitlements) ;;
      *) exit 92 ;;
    esac
    [[ -f "$argument" && ! -L "$argument" ]] || exit 93
  fi
  [[ "$argument" != --timestamp ]] || has_timestamp=1
  previous="$argument"
done
[[ "$identity" == '1111111111111111111111111111111111111111' ]]
[[ "$identity" != - && "$has_runtime" -eq 1 && "$has_timestamp" -eq 1 ]]
case "$target" in
  */UtterInk.app) [[ "$has_entitlements" -eq 1 ]] ;;
  *) [[ "$has_entitlements" -eq 0 ]] ;;
esac
call_index=0
if [[ -f "$UTTERINK_FIXTURE_LOG.codesign-count" ]]; then
  call_index="$(/bin/cat "$UTTERINK_FIXTURE_LOG.codesign-count")"
fi
[[ "$call_index" =~ ^[0-9]+$ ]]
printf '%s\n' "$((call_index + 1))" > "$UTTERINK_FIXTURE_LOG.codesign-count"

# Model codesign's legitimate synchronous delta at every boundary: embedded
# Mach-O signature bytes for files, plus the exact resource envelope and legacy
# CodeResources link for framework/app bundles.
component_kind=file
signed_code="$target"
signature_bases=()
case "$target" in
  */UtterInk.app)
    component_kind=app
    signed_code="$target/Contents/MacOS/UtterInk"
    signature_bases+=("$target/Contents")
    ;;
  *.framework)
    component_kind=bundle
    framework_name="${target##*/}"
    framework_name="${framework_name%.framework}"
    if [[ -f "$target/$framework_name" && ! -L "$target/$framework_name" ]]; then
      signed_code="$target/$framework_name"
    elif [[ -f "$target/Versions/A/$framework_name" && ! -L "$target/Versions/A/$framework_name" ]]; then
      signed_code="$target/Versions/A/$framework_name"
    else
      exit 94
    fi
    signature_bases+=("$target")
    code_parent="${signed_code%/*}"
    if [[ "$code_parent" != "$target" ]]; then
      signature_bases+=("$code_parent")
    fi
    ;;
esac
[[ -f "$signed_code" && ! -L "$signed_code" ]]
printf '\nsigned-mach-o:%s:%s\n' "$call_index" "$component_kind" >> "$signed_code"
if ((${#signature_bases[@]})); then
  for signature_base in "${signature_bases[@]}"; do
    [[ -d "$signature_base" && ! -L "$signature_base" ]]
    [[ ! -e "$signature_base/_CodeSignature" && ! -L "$signature_base/_CodeSignature" ]]
    [[ ! -e "$signature_base/CodeResources" && ! -L "$signature_base/CodeResources" ]]
    /bin/mkdir "$signature_base/_CodeSignature"
    printf 'fixture CodeResources call %s\n' "$call_index" > "$signature_base/_CodeSignature/CodeResources"
    /bin/ln -s '_CodeSignature/CodeResources' "$signature_base/CodeResources"
  done
fi

app="${target%%/Contents/*}"
[[ "$app" == *.app ]] || app="$target"
resource="$app/Contents/Resources/readme.txt"
if [[ -f "$UTTERINK_FIXTURE_LOG.codesign-resource-add-call-$call_index" ]]; then
  printf 'injected during codesign\n' > "$app/Contents/Resources/codesign-injected-$call_index.txt"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.codesign-resource-delete-call-$call_index" ]]; then
  /bin/rm "$resource"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.codesign-resource-replace-call-$call_index" ]]; then
  replacement="$resource.codesign-replacement"
  printf 'replaced during codesign\n' > "$replacement"
  /bin/mv -f "$replacement" "$resource"
fi
EOF

cat > "$BASE/FixtureTools/mutation-hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 && "$1" == before-sign && "$2" =~ ^[0-9]+$ ]]
printf 'mutation-hook\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "${UTTERINK_FIXTURE_LOG:?}"
marker="$UTTERINK_FIXTURE_LOG.mutate-index-$2"
if [[ -f "$marker" ]]; then
  if [[ -d "$3" && ! -L "$3" ]]; then
    /bin/mv "$3" "$3.fixture-original"
    /bin/mkdir "$3"
  else
    replacement="$3.fixture-replacement"
    printf 'replacement object\n' > "$replacement"
    /bin/chmod 0755 "$replacement"
    /bin/mv -f "$replacement" "$3"
  fi
fi
entitlements_marker="$UTTERINK_FIXTURE_LOG.mutate-entitlements-index-$2"
if [[ -f "$entitlements_marker" ]]; then
  entitlements_replacement="$4.fixture-replacement"
  printf 'replacement entitlements\n' > "$entitlements_replacement"
  /bin/chmod 0400 "$entitlements_replacement"
  /bin/mv -f "$entitlements_replacement" "$4"
fi
app="${3%%/Contents/*}"
[[ "$app" == *.app ]] || app="$3"
resource="$app/Contents/Resources/readme.txt"
if [[ -f "$UTTERINK_FIXTURE_LOG.mutate-resource-replace-index-$2" || -f "$UTTERINK_FIXTURE_LOG.mutate-resource-index-$2" ]]; then
  replacement="$resource.fixture-replacement"
  printf 'mutated resource\n' > "$replacement"
  /bin/chmod 0644 "$replacement"
  /bin/mv -f "$replacement" "$resource"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.mutate-resource-add-index-$2" ]]; then
  printf 'injected resource\n' > "$app/Contents/Resources/injected-$2.txt"
fi
if [[ -f "$UTTERINK_FIXTURE_LOG.mutate-resource-delete-index-$2" ]]; then
  /bin/rm "$resource"
fi
if [[ "$2" == 0 && ( -f "$UTTERINK_FIXTURE_LOG.replace-control" || -f "$UTTERINK_FIXTURE_LOG.replace-control-outside" ) ]]; then
  control="${4%%/reviewed-root/*}"
  if [[ -f "$UTTERINK_FIXTURE_LOG.replace-control-outside" ]]; then
    relocated="${UTTERINK_FIXTURE_LOG%/*}/control-outside-$$"
  else
    relocated="$control.relocated"
  fi
  /bin/mv "$control" "$relocated"
  /bin/mkdir -m 0700 "$control"
  printf 'replacement-canary\n' > "$control/replacement-canary"
  printf '%s\n' "$control" > "$UTTERINK_FIXTURE_LOG.control-replacement"
  printf '%s\n' "$relocated" > "$UTTERINK_FIXTURE_LOG.control-relocated"
fi
EOF

cat > "$BASE/FixtureTools/verify-signatures.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify-signatures' >> "${UTTERINK_FIXTURE_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$UTTERINK_FIXTURE_LOG"; done
printf '\n' >> "$UTTERINK_FIXTURE_LOG"
[[ "$#" -eq 10 && "$1" == --candidate && -d "$2" && "$3" == --identity ]]
[[ "$4" == 'Developer ID Application: Fixture Author (ABCDE12345)' ]]
[[ "$5" == --team-id && "$6" == ABCDE12345 && "$7" == --expected-certificate-sha256 ]]
[[ "$8" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && "$9" == --output ]]
case "${10}" in "$2"/signature-verification.json) ;; *) exit 64 ;; esac
/usr/bin/python3 -I - "$2" "${10}" "$8" "$UTTERINK_FIXTURE_LOG" "$0" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys


candidate = Path(sys.argv[1])
output = Path(sys.argv[2])
certificate_hash = sys.argv[3]
log = Path(sys.argv[4])
executed_verifier = Path(sys.argv[5])


def checked_target(relative: str, target: str) -> str:
    value = PurePosixPath(target)
    if not target or value.is_absolute() or ".." in value.parts:
        raise ValueError
    joined = PurePosixPath(relative).parent.joinpath(value)
    if joined.is_absolute() or ".." in joined.parts:
        raise ValueError
    return target


def logical_tree(root: Path) -> str:
    records = []
    pending = [root]
    while pending:
        directory = pending.pop()
        for path in directory.iterdir():
            metadata = os.lstat(path)
            relative = path.relative_to(root).as_posix()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                kind, payload = "directory", ""
                pending.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                kind, payload = "file", hashlib.sha256(path.read_bytes()).hexdigest()
            elif stat.S_ISLNK(metadata.st_mode):
                kind, payload = "symlink", checked_target(relative, os.readlink(path))
            else:
                raise ValueError
            records.append((relative.encode("utf-8"), [relative, kind, mode, payload]))
    digest = hashlib.sha256()
    for _, record in sorted(records, key=lambda item: item[0]):
        digest.update((json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
    return digest.hexdigest()


if Path(f"{log}.bad-verifier-ok").exists():
    evidence = {"ok": True, "teamID": "ABCDE12345"}
else:
    candidate_bytes = (candidate / "candidate.json").read_bytes()
    unsigned_bytes = (candidate / "unsigned-build-evidence.json").read_bytes()
    commit = json.loads(candidate_bytes.decode("utf-8"))["source"]["commit"]
    records = [
        ("bundle", "UtterInk.app", "dev.utterink.UtterInk"),
        ("bundle", "UtterInk.app/Contents/Frameworks/A.framework", "dev.utterink.A"),
        ("mach-o", "UtterInk.app/Contents/Frameworks/A.framework/A", "dev.utterink.A"),
        ("bundle", "UtterInk.app/Contents/Frameworks/B.framework", "dev.utterink.B"),
        ("mach-o", "UtterInk.app/Contents/Frameworks/B.framework/Versions/A/B", "dev.utterink.B"),
        ("mach-o", "UtterInk.app/Contents/Frameworks/B.framework/Versions/A/Helpers/BHelper", "dev.utterink.BHelper"),
        ("mach-o", "UtterInk.app/Contents/MacOS/UtterInk", "dev.utterink.UtterInk"),
    ]
    components = []
    for kind, path, identifier in sorted(records, key=lambda item: item[1].encode("utf-8")):
        app_role = path in {"UtterInk.app", "UtterInk.app/Contents/MacOS/UtterInk"}
        components.append({
            "architecture": "arm64" if kind == "mach-o" else None,
            "designatedRequirement": "valid",
            "entitlements": {"com.apple.security.device.audio-input": True} if app_role else {},
            "identifier": identifier,
            "kind": kind,
            "path": path,
            "runtime": "hardened",
            "secureTimestamp": "present",
            "sha256": hashlib.sha256(path.encode("utf-8")).hexdigest(),
            "teamID": "ABCDE12345",
            "trust": "valid",
        })
    evidence = {
        "candidateCommit": commit,
        "candidateJSONSHA256": hashlib.sha256(candidate_bytes).hexdigest(),
        "certificate": {
            "notAfter": "Jul 15 12:00:00 2030 GMT",
            "notBefore": "Jul 15 12:00:00 2026 GMT",
            "sha256": certificate_hash,
            "trust": "valid",
        },
        "components": components,
        "evidenceType": "signature-verification",
        "product": "UtterInk",
        "schemaVersion": 1,
        "signedAppTreeSHA256": logical_tree(candidate / "UtterInk.app"),
        "status": "valid",
        "teamID": "ABCDE12345",
        "treeAlgorithm": "utterink-logical-tree-v1",
        "unsignedBuildEvidenceSHA256": hashlib.sha256(unsigned_bytes).hexdigest(),
    }
    if Path(f"{log}.bad-verifier-team").exists():
        evidence["teamID"] = "ZZZZZ99999"
    if Path(f"{log}.bad-verifier-identifier").exists():
        evidence["components"][0]["identifier"] = "dev.utterink.Wrong"
    if Path(f"{log}.bad-verifier-hash").exists():
        evidence["unsignedBuildEvidenceSHA256"] = "0" * 64
    if Path(f"{log}.bad-verifier-commit").exists():
        evidence["candidateCommit"] = "f" * 40
    if Path(f"{log}.bad-verifier-candidate-hash").exists():
        evidence["candidateJSONSHA256"] = "0" * 64
    if Path(f"{log}.bad-verifier-certificate").exists():
        evidence["certificate"]["sha256"] = "c" * 64
    if Path(f"{log}.bad-verifier-tree").exists():
        evidence["signedAppTreeSHA256"] = "0" * 64
    if Path(f"{log}.bad-verifier-component-team").exists():
        evidence["components"][0]["teamID"] = "ZZZZZ99999"
    if Path(f"{log}.bad-verifier-extra").exists():
        evidence["unexpected"] = True
encoded = json.dumps(evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
output.write_text(encoded, encoding="utf-8")
os.chmod(output, 0o600)
if Path(f"{log}.swap-verifier-during-exec").exists():
    replacement = executed_verifier.with_name(executed_verifier.name + ".fixture-replacement")
    replacement.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    os.chmod(replacement, 0o755)
    os.replace(replacement, executed_verifier)
PY
EOF

/bin/chmod 0755 "$BASE/FixtureTools/"{security,openssl,file,lipo,codesign,verify-signatures.sh,mutation-hook}

for tool in security openssl file lipo codesign verify-signatures.sh; do
  cat > "$BASE/OrdinaryPath/$tool" <<EOF
#!/usr/bin/env bash
printf '$tool\n' >> '$ORDINARY_LOG'
exit 97
EOF
  /bin/chmod 0755 "$BASE/OrdinaryPath/$tool"
done

/usr/bin/git -C "$BASE" init -q
/usr/bin/git -C "$BASE" config user.name 'UtterInk Signing Test'
/usr/bin/git -C "$BASE" config user.email 'signing-test@example.invalid'
/usr/bin/git -C "$BASE" add .
/usr/bin/git -C "$BASE" commit -q -m 'offline signing fixture'
BASE_COMMIT="$(/usr/bin/git -C "$BASE" rev-parse --verify HEAD)"
BASE_TREE="$(/usr/bin/git -C "$BASE" rev-parse --verify 'HEAD^{tree}')"
BASE_POLICY_SHA256="$(/usr/bin/shasum -a 256 "$BASE/Config/release-entitlements.json" | /usr/bin/awk '{print $1}')"
readonly BASE_COMMIT BASE_TREE BASE_POLICY_SHA256

refresh_unsigned_evidence() {
  /usr/bin/python3 -I - "$1" "$BASE_COMMIT" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys


candidate = Path(sys.argv[1])
app = candidate / "UtterInk.app"


def target(relative: str, raw: str) -> str:
    value = PurePosixPath(raw)
    joined = PurePosixPath(relative).parent.joinpath(value)
    if not raw or value.is_absolute() or ".." in value.parts or joined.is_absolute() or ".." in joined.parts:
        raise ValueError
    return raw


records = []
pending = [app]
while pending:
    directory = pending.pop()
    for path in directory.iterdir():
        metadata = os.lstat(path)
        relative = path.relative_to(app).as_posix()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            kind, payload = "directory", ""
            pending.append(path)
        elif stat.S_ISREG(metadata.st_mode):
            kind, payload = "file", hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISLNK(metadata.st_mode):
            kind, payload = "symlink", target(relative, os.readlink(path))
        else:
            raise ValueError
        records.append((relative.encode("utf-8"), [relative, kind, mode, payload]))
tree = hashlib.sha256()
for _, record in sorted(records, key=lambda item: item[0]):
    tree.update((json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
candidate_bytes = (candidate / "candidate.json").read_bytes()
evidence = {
    "appTreeSHA256": tree.hexdigest(),
    "archiveTreeSHA256": "f" * 64,
    "candidateCommit": sys.argv[2],
    "candidateJSONSHA256": hashlib.sha256(candidate_bytes).hexdigest(),
    "evidenceType": "unsigned-build",
    "product": "UtterInk",
    "schemaVersion": 1,
    "status": "valid",
    "treeAlgorithm": "utterink-logical-tree-v1",
}
(candidate / "unsigned-build-evidence.json").write_text(
    json.dumps(evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

make_candidate() {
  local name="$1"
  local candidate="$BASE/.release-work/$name"
  local app="$candidate/UtterInk.app"
  /bin/mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/Resources" \
    "$app/Contents/Frameworks/A.framework" \
    "$app/Contents/Frameworks/B.framework/Versions/A/Helpers"
  printf 'main\n' > "$app/Contents/MacOS/UtterInk"
  printf 'framework A\n' > "$app/Contents/Frameworks/A.framework/A"
  printf 'framework B\n' > "$app/Contents/Frameworks/B.framework/Versions/A/B"
  printf 'helper\n' > "$app/Contents/Frameworks/B.framework/Versions/A/Helpers/BHelper"
  printf 'resource\n' > "$app/Contents/Resources/readme.txt"
  /usr/bin/printf '%s\n' \
    "{\"checks\":{\"entitlements\":true,\"generatedProjectClean\":true,\"history\":true,\"infoPolicy\":true,\"metadata\":true,\"packageResolution\":true},\"evidenceType\":\"release-candidate-test\",\"packageResolution\":{\"path\":\"Packages/UtterInkKit/Package.resolved\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"policies\":{\"ciToolchainSHA256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"releaseEntitlementsSHA256\":\"$BASE_POLICY_SHA256\",\"releaseInfoPolicySHA256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"releaseMetadataSHA256\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"},\"product\":\"UtterInk\",\"release\":{\"architecture\":\"arm64\",\"buildNumber\":\"1\",\"bundleIdentifier\":\"dev.utterink.UtterInk\",\"configuration\":\"Release\",\"deploymentTarget\":\"14.0\",\"dmgFilename\":\"UtterInk-0.1.0-arm64.dmg\",\"marketingVersion\":\"0.1.0\"},\"schemaVersion\":1,\"source\":{\"clean\":true,\"commit\":\"$BASE_COMMIT\",\"releaseTag\":\"v0.1.0\",\"tree\":\"$BASE_TREE\"},\"toolchain\":{\"lockSHA256\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"sdkBuild\":\"25A1\",\"sdkVersion\":\"26.4\",\"swiftVersion\":\"Apple Swift version 6.3 (swiftlang-6.3.0 clang-1700.0.0.0)\",\"xcodeBuild\":\"17E202\",\"xcodeVersion\":\"26.4.1\",\"xcodegenBinarySHA256\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"xcodegenVersion\":\"2.45.4\"}}" \
    > "$candidate/candidate.json"
  /bin/chmod 0755 \
    "$app/Contents/MacOS/UtterInk" \
    "$app/Contents/Frameworks/A.framework/A" \
    "$app/Contents/Frameworks/B.framework/Versions/A/B" \
    "$app/Contents/Frameworks/B.framework/Versions/A/Helpers/BHelper"
  refresh_unsigned_evidence "$candidate"
  printf '%s\n' "$candidate"
}

SIGN_STATUS=0
run_sign() {
  local candidate="$1"
  shift
  : > "$LOG"
  /bin/rm -f "$STDOUT" "$STDERR" "$ORDINARY_LOG" "$BASH_ENV_MARKER" "$LOG.codesign-count"
  set +e
  (
    cd "$BASE"
    /usr/bin/env \
      PATH="$BASE/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$BASH_ENV_CANARY" \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$BASE/FixtureTools" \
      UTTERINK_FIXTURE_LOG="$LOG" \
      ./Scripts/release/sign-candidate.sh --candidate "$candidate" "$@"
  ) > "$STDOUT" 2> "$STDERR"
  SIGN_STATUS=$?
  set -e
}

assert_no_signing() {
  if /usr/bin/grep -Eq '^(codesign|verify-signatures)([[:space:]]|$)' "$LOG"; then
    fail "$1 reached signing or verification"
  fi
}

assert_no_pinned_verifier() {
  local context="$1"
  if ! /usr/bin/python3 -I - "$BASE/Scripts" "$BASE/Scripts/release" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

for parent in map(Path, sys.argv[1:]):
    if any(item.name.startswith(".utterink-verifier-pinned.") for item in parent.iterdir()):
        raise SystemExit(1)
PY
  then
    fail "$context left a pinned verifier directory"
  fi
}

replace_candidate_text() {
  /usr/bin/python3 -I - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
value = path.read_text(encoding="utf-8")
if value.count(old) != 1:
    raise SystemExit(1)
path.write_text(value.replace(old, new), encoding="utf-8")
PY
}

SUCCESS_CANDIDATE="$(make_candidate success)"
run_sign "$SUCCESS_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -eq 0 ]] ||
  fail "valid fixture failed after $(/usr/bin/grep -c '^codesign' "$LOG" || true) codesign calls: $(/bin/cat "$STDERR")"
assert_no_pinned_verifier 'valid signing cleanup'
[[ ! -s "$STDOUT" && ! -s "$STDERR" ]] || fail 'valid signing emitted unsanitized output'
[[ -f "$SUCCESS_CANDIDATE/signature-verification.json" && ! -L "$SUCCESS_CANDIDATE/signature-verification.json" ]] ||
  fail 'fixture verifier did not emit signing evidence'
/usr/bin/python3 -I - "$SUCCESS_CANDIDATE/UtterInk.app" <<'PY' || fail 'valid codesign delta was not modeled or accepted exactly'
from pathlib import Path
import os
import stat
import sys

app = Path(sys.argv[1])
expected_markers = {
    "Contents/Frameworks/B.framework/Versions/A/Helpers/BHelper": ["signed-mach-o:0:file"],
    "Contents/Frameworks/B.framework/Versions/A/B": ["signed-mach-o:1:file", "signed-mach-o:4:bundle"],
    "Contents/Frameworks/A.framework/A": ["signed-mach-o:2:file", "signed-mach-o:3:bundle"],
    "Contents/MacOS/UtterInk": ["signed-mach-o:5:app"],
}
for relative, markers in expected_markers.items():
    value = (app / relative).read_text(encoding="utf-8")
    if any(marker not in value for marker in markers):
        raise SystemExit(1)

signature_bases = [
    "Contents/Frameworks/A.framework",
    "Contents/Frameworks/B.framework",
    "Contents/Frameworks/B.framework/Versions/A",
    "Contents",
]
for relative in signature_bases:
    base = app / relative
    envelope = base / "_CodeSignature"
    resources = envelope / "CodeResources"
    legacy = base / "CodeResources"
    envelope_metadata = os.lstat(envelope)
    resources_metadata = os.lstat(resources)
    legacy_metadata = os.lstat(legacy)
    if (
        not stat.S_ISDIR(envelope_metadata.st_mode)
        or stat.S_ISLNK(envelope_metadata.st_mode)
        or not stat.S_ISREG(resources_metadata.st_mode)
        or stat.S_ISLNK(resources_metadata.st_mode)
        or not stat.S_ISLNK(legacy_metadata.st_mode)
        or os.readlink(legacy) != "_CodeSignature/CodeResources"
    ):
        raise SystemExit(1)
PY
/usr/bin/python3 -I - "$SUCCESS_CANDIDATE" <<'PY' || fail 'successful candidate top-level inventory was not exact'
from pathlib import Path
import sys

if sorted(item.name for item in Path(sys.argv[1]).iterdir()) != [
    "UtterInk.app", "candidate.json", "signature-verification.json",
    "unsigned-build-evidence.json"
]:
    raise SystemExit(1)
PY
[[ ! -e "$ORDINARY_LOG" && ! -e "$BASH_ENV_MARKER" ]] || fail 'signer consulted ordinary PATH or hostile BASH_ENV'

/usr/bin/awk -F '\t' '$1 == "codesign" { print $NF }' "$LOG" > "$TMP/sign-order"
cat > "$TMP/expected-sign-order" <<EOF
$SUCCESS_CANDIDATE/UtterInk.app/Contents/Frameworks/B.framework/Versions/A/Helpers/BHelper
$SUCCESS_CANDIDATE/UtterInk.app/Contents/Frameworks/B.framework/Versions/A/B
$SUCCESS_CANDIDATE/UtterInk.app/Contents/Frameworks/A.framework/A
$SUCCESS_CANDIDATE/UtterInk.app/Contents/Frameworks/A.framework
$SUCCESS_CANDIDATE/UtterInk.app/Contents/Frameworks/B.framework
$SUCCESS_CANDIDATE/UtterInk.app
EOF
/usr/bin/cmp -s "$TMP/expected-sign-order" "$TMP/sign-order" ||
  fail "signing order was not deterministic inside-out: $(/bin/cat "$TMP/sign-order")"
if /usr/bin/grep -Fq -- '--deep' "$LOG"; then fail 'signer used forbidden --deep'; fi
if /usr/bin/awk -F '\t' '$1 == "codesign" { for (i = 1; i <= NF; i++) if ($i == "--sign" && $(i + 1) != "1111111111111111111111111111111111111111") exit 1 }' "$LOG"; then
  :
else
  fail 'codesign was not pinned to the unique find-identity SHA-1'
fi
FIRST_CODESIGN="$(/usr/bin/grep -n '^codesign' "$LOG" | /usr/bin/awk -F: 'NR == 1 { print $1 }')"
LAST_PREFLIGHT="$(/usr/bin/grep -n -E '^(security|openssl)' "$LOG" | /usr/bin/awk -F: 'END { print $1 }')"
LAST_LIPO="$(/usr/bin/grep -n '^lipo' "$LOG" | /usr/bin/awk -F: 'END { print $1 }')"
VERIFY_LINE="$(/usr/bin/grep -n '^verify-signatures' "$LOG" | /usr/bin/awk -F: 'NR == 1 { print $1 }')"
LAST_CODESIGN="$(/usr/bin/grep -n '^codesign' "$LOG" | /usr/bin/awk -F: 'END { print $1 }')"
LIPO_COUNT="$(/usr/bin/grep -c '^lipo' "$LOG")"
[[ "$LIPO_COUNT" -eq 4 && "$LAST_LIPO" -lt "$FIRST_CODESIGN" ]] ||
  fail 'arm64-only lipo inventory did not complete before signing'
[[ "$LAST_PREFLIGHT" -lt "$FIRST_CODESIGN" && "$VERIFY_LINE" -gt "$LAST_CODESIGN" ]] ||
  fail 'identity preflight/signing/verification order was incorrect'

ROTATION_CANDIDATE="$(make_candidate same-name-certificate-rotation)"
printf 'fixture\n' > "$LOG.same-name-rotation"
run_sign "$ROTATION_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -eq 0 ]] || fail 'same-CN identity rotation defeated SHA-1-pinned signing'
/usr/bin/grep -Fq $'codesign\t--force\t--sign\t1111111111111111111111111111111111111111' "$LOG" ||
  fail 'rotation fixture did not receive the pinned identity hash'
/bin/rm "$LOG.same-name-rotation"

PREEXISTING_OUTPUT_CANDIDATE="$(make_candidate preexisting-signature-verification)"
printf 'preserve-existing-output\n' > "$PREEXISTING_OUTPUT_CANDIDATE/signature-verification.json"
run_sign "$PREEXISTING_OUTPUT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'preexisting signature-verification output was overwritten'
assert_no_signing 'preexisting signature-verification output'
[[ "$(/bin/cat "$PREEXISTING_OUTPUT_CANDIDATE/signature-verification.json")" == preserve-existing-output ]] ||
  fail 'preexisting signature-verification output changed'

SYMLINK_OUTPUT_CANDIDATE="$(make_candidate symlink-signature-verification)"
printf 'preserve-symlink-target\n' > "$TMP/signature-verification-target"
/bin/ln -s "$TMP/signature-verification-target" "$SYMLINK_OUTPUT_CANDIDATE/signature-verification.json"
run_sign "$SYMLINK_OUTPUT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'symlink signature-verification output was followed'
assert_no_signing 'symlink signature-verification output'
[[ "$(/bin/cat "$TMP/signature-verification-target")" == preserve-symlink-target ]] ||
  fail 'signature-verification symlink target changed'

MISSING_UNSIGNED_EVIDENCE_CANDIDATE="$(make_candidate missing-unsigned-build-evidence)"
/bin/rm "$MISSING_UNSIGNED_EVIDENCE_CANDIDATE/unsigned-build-evidence.json"
run_sign "$MISSING_UNSIGNED_EVIDENCE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'candidate without unsigned build evidence was accepted'
assert_no_signing 'missing unsigned build evidence'

FORGED_UNSIGNED_TREE_CANDIDATE="$(make_candidate forged-unsigned-app-tree)"
/usr/bin/python3 -I - "$FORGED_UNSIGNED_TREE_CANDIDATE/unsigned-build-evidence.json" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["appTreeSHA256"] = "0" * 64
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
run_sign "$FORGED_UNSIGNED_TREE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'forged unsigned app tree hash was accepted'
assert_no_signing 'forged unsigned app tree hash'

EXTRA_UNSIGNED_FIELD_CANDIDATE="$(make_candidate extra-unsigned-evidence-field)"
/usr/bin/python3 -I - "$EXTRA_UNSIGNED_FIELD_CANDIDATE/unsigned-build-evidence.json" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["unexpected"] = True
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
run_sign "$EXTRA_UNSIGNED_FIELD_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'unsigned evidence with an extra field was accepted'
assert_no_signing 'extra unsigned evidence field'

FALSE_CHECK_CANDIDATE="$(make_candidate false-check)"
replace_candidate_text "$FALSE_CHECK_CANDIDATE/candidate.json" '"entitlements":true' '"entitlements":false'
run_sign "$FALSE_CHECK_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'candidate with a false reviewed check was accepted'
assert_no_signing 'false candidate check'

FORGED_POLICY_EVIDENCE_CANDIDATE="$(make_candidate forged-policy-evidence)"
replace_candidate_text \
  "$FORGED_POLICY_EVIDENCE_CANDIDATE/candidate.json" \
  "$BASE_POLICY_SHA256" \
  '0000000000000000000000000000000000000000000000000000000000000000'
run_sign "$FORGED_POLICY_EVIDENCE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'forged entitlement-policy evidence was accepted'
assert_no_signing 'forged entitlement-policy evidence'

COMMIT_MISMATCH_CANDIDATE="$(make_candidate commit-mismatch)"
replace_candidate_text \
  "$COMMIT_MISMATCH_CANDIDATE/candidate.json" \
  "$BASE_COMMIT" \
  'ffffffffffffffffffffffffffffffffffffffff'
run_sign "$COMMIT_MISMATCH_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'candidate bound to a different commit was accepted'
assert_no_signing 'candidate commit mismatch'

TREE_MISMATCH_CANDIDATE="$(make_candidate source-tree-mismatch)"
replace_candidate_text \
  "$TREE_MISMATCH_CANDIDATE/candidate.json" \
  "$BASE_TREE" \
  'ffffffffffffffffffffffffffffffffffffffff'
refresh_unsigned_evidence "$TREE_MISMATCH_CANDIDATE"
run_sign "$TREE_MISMATCH_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'candidate source.tree inconsistent with commit was accepted'
assert_no_signing 'candidate source tree mismatch'

/bin/cp "$BASE/Config/release-entitlements.json" "$TMP/release-entitlements.backup"
MUTATED_POLICY_CANDIDATE="$(make_candidate mutated-policy)"
printf ' \n' >> "$BASE/Config/release-entitlements.json"
run_sign "$MUTATED_POLICY_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'worktree policy mutation was accepted'
assert_no_signing 'worktree policy mutation'
/bin/cp "$TMP/release-entitlements.backup" "$BASE/Config/release-entitlements.json"

/bin/cp "$BASE/App/Supporting/UtterInk.entitlements" "$TMP/UtterInk.entitlements.backup"
MUTATED_SOURCE_CANDIDATE="$(make_candidate mutated-source-entitlements)"
printf ' \n' >> "$BASE/App/Supporting/UtterInk.entitlements"
run_sign "$MUTATED_SOURCE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'worktree entitlement mutation was accepted'
assert_no_signing 'worktree entitlement mutation'
/bin/cp "$TMP/UtterInk.entitlements.backup" "$BASE/App/Supporting/UtterInk.entitlements"

/bin/cp "$BASE/Scripts/release/verify-signatures.sh" "$TMP/verify-signatures.sh.backup"
MUTATED_VERIFIER_CANDIDATE="$(make_candidate mutated-signature-verifier)"
printf ' \n' >> "$BASE/Scripts/release/verify-signatures.sh"
run_sign "$MUTATED_VERIFIER_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'worktree signature verifier mutation was accepted'
assert_no_signing 'worktree signature verifier mutation'
/bin/cp "$TMP/verify-signatures.sh.backup" "$BASE/Scripts/release/verify-signatures.sh"

UNIVERSAL_CANDIDATE="$(make_candidate universal-main)"
printf 'fixture\n' > "$LOG.universal"
run_sign "$UNIVERSAL_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'universal Mach-O was accepted as arm64-only'
assert_no_signing 'universal Mach-O'
/bin/rm "$LOG.universal"

FIRST_REPLACEMENT_CANDIDATE="$(make_candidate replace-before-first-sign)"
printf 'fixture\n' > "$LOG.mutate-index-0"
run_sign "$FIRST_REPLACEMENT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'first signable inode replacement was accepted'
assert_no_signing 'first signable inode replacement'
[[ ! -e "$FIRST_REPLACEMENT_CANDIDATE/signature-verification.json" ]] ||
  fail 'first signable inode replacement emitted evidence'
/bin/rm "$LOG.mutate-index-0"

MID_REPLACEMENT_CANDIDATE="$(make_candidate replace-before-second-sign)"
printf 'fixture\n' > "$LOG.mutate-index-1"
run_sign "$MID_REPLACEMENT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'mid-signing inode replacement was accepted'
[[ "$(/usr/bin/grep -c '^codesign' "$LOG")" -eq 1 ]] ||
  fail 'mid-signing replacement was not rejected immediately before the second codesign'
if /usr/bin/grep -q '^verify-signatures' "$LOG"; then
  fail 'mid-signing replacement reached signature verification'
fi
[[ ! -e "$MID_REPLACEMENT_CANDIDATE/signature-verification.json" ]] ||
  fail 'mid-signing inode replacement emitted evidence'
/bin/rm "$LOG.mutate-index-1"

FRAMEWORK_REPLACEMENT_CANDIDATE="$(make_candidate replace-framework-before-sign)"
printf 'fixture\n' > "$LOG.mutate-index-3"
run_sign "$FRAMEWORK_REPLACEMENT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'framework inode replacement was accepted'
[[ "$(/usr/bin/grep -c '^codesign' "$LOG")" -eq 3 ]] ||
  fail 'framework replacement was not rejected before framework codesign'
if /usr/bin/grep -q '^verify-signatures' "$LOG"; then
  fail 'framework replacement reached signature verification'
fi
/bin/rm "$LOG.mutate-index-3"

OUTER_APP_REPLACEMENT_CANDIDATE="$(make_candidate replace-outer-app-before-sign)"
printf 'fixture\n' > "$LOG.mutate-index-5"
run_sign "$OUTER_APP_REPLACEMENT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'outer app inode replacement was accepted'
[[ "$(/usr/bin/grep -c '^codesign' "$LOG")" -eq 5 ]] ||
  fail 'outer app replacement was not rejected before app codesign'
if /usr/bin/grep -q '^verify-signatures' "$LOG"; then
  fail 'outer app replacement reached signature verification'
fi
/bin/rm "$LOG.mutate-index-5"

SNAPSHOT_REPLACEMENT_CANDIDATE="$(make_candidate replace-entitlements-snapshot)"
printf 'fixture\n' > "$LOG.mutate-entitlements-index-5"
run_sign "$SNAPSHOT_REPLACEMENT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'private entitlement snapshot replacement was accepted'
[[ "$(/usr/bin/grep -c '^codesign' "$LOG")" -eq 5 ]] ||
  fail 'entitlement snapshot replacement was not rejected before app codesign'
if /usr/bin/grep -q '^verify-signatures' "$LOG"; then
  fail 'entitlement snapshot replacement reached signature verification'
fi
/bin/rm "$LOG.mutate-entitlements-index-5"

for resource_operation in add delete replace; do
  for resource_boundary in 0 1 2 3 4 5; do
    RESOURCE_MUTATION_CANDIDATE="$(make_candidate "codesign-resource-$resource_operation-call-$resource_boundary")"
    marker="$LOG.codesign-resource-$resource_operation-call-$resource_boundary"
    printf 'fixture\n' > "$marker"
    run_sign "$RESOURCE_MUTATION_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
    [[ "$SIGN_STATUS" -ne 0 ]] ||
      fail "codesign $resource_operation non-Mach-O resource at call $resource_boundary was accepted"
    observed_codesigns="$(/usr/bin/grep -c '^codesign' "$LOG" || true)"
    [[ "$observed_codesigns" -eq "$((resource_boundary + 1))" ]] ||
      fail "codesign $resource_operation mutation was not rejected immediately after call $resource_boundary"
    if /usr/bin/grep -q '^verify-signatures' "$LOG"; then
      fail "codesign $resource_operation mutation at call $resource_boundary reached verification"
    fi
    [[ ! -e "$RESOURCE_MUTATION_CANDIDATE/signature-verification.json" ]] ||
      fail "codesign $resource_operation mutation emitted evidence"
    /bin/rm "$marker"
  done
done

CONTROL_REPLACEMENT_CANDIDATE="$(make_candidate replace-control-path)"
/bin/rm -f "$LOG.control-replacement" "$LOG.control-relocated"
printf 'fixture\n' > "$LOG.replace-control"
run_sign "$CONTROL_REPLACEMENT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'CONTROL pathname replacement was reported as success'
assert_no_signing 'CONTROL pathname replacement'
CONTROL_REPLACEMENT="$(/bin/cat "$LOG.control-replacement")"
CONTROL_RELOCATED="$(/bin/cat "$LOG.control-relocated")"
[[ -f "$CONTROL_REPLACEMENT/replacement-canary" ]] || fail 'cleanup followed and deleted replacement CONTROL path'
[[ ! -e "$CONTROL_RELOCATED" ]] || fail 'fd-relative cleanup did not remove the original CONTROL inode'
[[ ! -e "$CONTROL_REPLACEMENT/certificate.pem" && ! -e "$CONTROL_REPLACEMENT/reviewed-root" ]] ||
  fail 'CONTROL replacement retained certificate material'
/bin/rm -rf "$CONTROL_REPLACEMENT"
/bin/rm -f "$LOG.replace-control" "$LOG.control-replacement" "$LOG.control-relocated"

CONTROL_CLEANUP_FAILURE_CANDIDATE="$(make_candidate control-cleanup-failure)"
/bin/rm -f "$LOG.control-replacement" "$LOG.control-relocated"
printf 'fixture\n' > "$LOG.replace-control-outside"
run_sign "$CONTROL_CLEANUP_FAILURE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -eq 40 ]] || fail 'CONTROL cleanup failure did not override success/failure with status 40'
CONTROL_REPLACEMENT="$(/bin/cat "$LOG.control-replacement")"
CONTROL_RELOCATED="$(/bin/cat "$LOG.control-relocated")"
[[ -d "$CONTROL_RELOCATED" ]] || fail 'cleanup-failure fixture did not retain the relocated directory'
[[ -z "$(/bin/ls -A "$CONTROL_RELOCATED")" ]] || fail 'cleanup failure left certificate or other sensitive CONTROL contents'
[[ -f "$CONTROL_REPLACEMENT/replacement-canary" ]] || fail 'cleanup failure deleted replacement CONTROL path'
/bin/rm -rf "$CONTROL_REPLACEMENT" "$CONTROL_RELOCATED"
/bin/rm -f "$LOG.replace-control-outside" "$LOG.control-replacement" "$LOG.control-relocated"

run_signal_test() {
  local signal_name="$1"
  local expected_status="$2"
  local candidate
  local status
  candidate="$(make_candidate "signal-$signal_name")"
  : > "$LOG"
  printf 'fixture\n' > "$LOG.pause-identity"
  /bin/rm -f "$LOG.signal-ready" "$LOG.signal-continue"
  set +e
  /usr/bin/python3 -I - \
    "$BASE" "$candidate" "$IDENTITY" "$TEAM_ID" "$LOG" "$BASH_ENV_CANARY" \
    "$TMP/signal-${signal_name}.stdout" "$TMP/signal-${signal_name}.stderr" \
    "$signal_name" "$expected_status" <<'PY'
from pathlib import Path
import os
import signal
import subprocess
import sys
import time

base = Path(sys.argv[1])
candidate = sys.argv[2]
identity = sys.argv[3]
team_id = sys.argv[4]
log = Path(sys.argv[5])
environment = {
    "PATH": f"{base}/OrdinaryPath:/usr/bin:/bin:/usr/sbin:/sbin",
    "BASH_ENV": sys.argv[6],
    "UTTERINK_RELEASE_TEST_MODE": "1",
    "UTTERINK_RELEASE_TEST_TOOL_ROOT": str(base / "FixtureTools"),
    "UTTERINK_FIXTURE_LOG": str(log),
}
stdout_path = Path(sys.argv[7])
stderr_path = Path(sys.argv[8])
signal_number = getattr(signal, f"SIG{sys.argv[9]}")
expected_status = int(sys.argv[10])
with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
    process = subprocess.Popen(
        [
            str(base / "Scripts/release/sign-candidate.sh"),
            "--candidate", candidate,
            "--identity", identity,
            "--team-id", team_id,
        ],
        cwd=base,
        env=environment,
        stdout=stdout,
        stderr=stderr,
    )
    deadline = time.monotonic() + 10
    ready = Path(f"{log}.signal-ready")
    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    if not ready.exists():
        process.terminate()
        process.wait(timeout=5)
        raise SystemExit(2)
    os.kill(process.pid, signal_number)
    Path(f"{log}.signal-continue").touch()
    return_code = process.wait(timeout=10)
if return_code != expected_status:
    print(f"observed signal status {return_code}, expected {expected_status}", file=sys.stderr)
    raise SystemExit(3)
PY
  status=$?
  set -e
  /bin/rm -f \
    "$LOG.pause-identity" "$LOG.signal-ready" "$LOG.signal-continue"
  [[ "$status" -eq 0 ]] || fail "$signal_name did not preserve exit status $expected_status"
  assert_no_signing "$signal_name signal"
  [[ ! -e "$candidate/signature-verification.json" ]] || fail "$signal_name signal emitted evidence"
}

run_signal_test HUP 129
run_signal_test INT 130
run_signal_test TERM 143

for verifier_failure in \
  bad-verifier-ok bad-verifier-team bad-verifier-identifier bad-verifier-hash \
  bad-verifier-commit bad-verifier-candidate-hash bad-verifier-certificate \
  bad-verifier-tree bad-verifier-component-team bad-verifier-extra; do
  candidate="$(make_candidate "$verifier_failure")"
  printf 'fixture\n' > "$LOG.$verifier_failure"
  run_sign "$candidate" --identity "$IDENTITY" --team-id "$TEAM_ID"
  [[ "$SIGN_STATUS" -ne 0 ]] || fail "$verifier_failure output was accepted"
  /usr/bin/grep -q '^verify-signatures' "$LOG" || fail "$verifier_failure did not reach the verifier fixture"
  [[ ! -e "$candidate/signature-verification.json" ]] || fail "$verifier_failure left untrusted evidence"
  /bin/rm "$LOG.$verifier_failure"
done

SWAPPED_VERIFIER_CANDIDATE="$(make_candidate verifier-path-swap-during-exec)"
printf 'fixture\n' > "$LOG.swap-verifier-during-exec"
run_sign "$SWAPPED_VERIFIER_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
assert_no_pinned_verifier 'verifier path swap failure cleanup'
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'verifier path swap during execution was accepted'
/usr/bin/grep -q '^verify-signatures' "$LOG" || fail 'verifier path swap fixture did not execute'
[[ ! -e "$SWAPPED_VERIFIER_CANDIDATE/signature-verification.json" ]] ||
  fail 'verifier path swap retained untrusted evidence'
/bin/cp "$TMP/verify-signatures.sh.backup" "$BASE/Scripts/release/verify-signatures.sh"
/bin/rm "$LOG.swap-verifier-during-exec"

INVALID_IDENTITY_CANDIDATE="$(make_candidate invalid-identity)"
run_sign "$INVALID_IDENTITY_CANDIDATE" --identity - --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'ad-hoc identity was accepted'
assert_no_signing 'ad-hoc identity'

NON_DEVELOPER_CANDIDATE="$(make_candidate non-developer)"
run_sign "$NON_DEVELOPER_CANDIDATE" --identity 'Apple Development: Fixture (ABCDE12345)' --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'non-Developer-ID identity was accepted'
assert_no_signing 'non-Developer-ID identity'

MALFORMED_TEAM_CANDIDATE="$(make_candidate malformed-team)"
run_sign "$MALFORMED_TEAM_CANDIDATE" --identity "$IDENTITY" --team-id 'short'
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'malformed Team ID was accepted'
assert_no_signing 'malformed Team ID'

MISSING_TEAM_CANDIDATE="$(make_candidate missing-team)"
run_sign "$MISSING_TEAM_CANDIDATE" --identity "$IDENTITY"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'missing Team ID was accepted'
assert_no_signing 'missing Team ID'

TEAM_MISMATCH_CANDIDATE="$(make_candidate team-mismatch)"
run_sign "$TEAM_MISMATCH_CANDIDATE" --identity "$IDENTITY" --team-id 'ZZZZZ99999'
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'identity/Team ID mismatch was accepted'
assert_no_signing 'identity/Team ID mismatch'

for failure_mode in ou-mismatch duplicate-identity missing-private-key untrusted expired certificate-sha1-mismatch; do
  candidate="$(make_candidate "$failure_mode")"
  printf 'fixture\n' > "$LOG.$failure_mode"
  run_sign "$candidate" --identity "$IDENTITY" --team-id "$TEAM_ID"
  [[ "$SIGN_STATUS" -ne 0 ]] || fail "$failure_mode identity preflight was accepted"
  assert_no_signing "$failure_mode identity preflight"
  [[ ! -e "$candidate/signature-verification.json" ]] || fail "$failure_mode emitted signing evidence"
  /bin/rm "$LOG.$failure_mode"
done

SYMLINK_CANDIDATE="$(make_candidate symlink)"
/bin/ln -s "$TMP" "$SYMLINK_CANDIDATE/UtterInk.app/Contents/Resources/outside"
run_sign "$SYMLINK_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'candidate symlink was accepted'
assert_no_signing 'candidate symlink'

for rejected_suffix in xpc component service prefPane qlgenerator mystery; do
  UNKNOWN_BUNDLE_CANDIDATE="$(make_candidate "unknown-bundle-$rejected_suffix")"
  /bin/mkdir -p "$UNKNOWN_BUNDLE_CANDIDATE/UtterInk.app/Contents/Resources/Unknown.$rejected_suffix"
  refresh_unsigned_evidence "$UNKNOWN_BUNDLE_CANDIDATE"
  run_sign "$UNKNOWN_BUNDLE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
  [[ "$SIGN_STATUS" -ne 0 ]] || fail "unknown .$rejected_suffix bundle container was accepted"
  assert_no_signing "unknown .$rejected_suffix bundle container"
done

WRONG_LAYOUT_CANDIDATE="$(make_candidate wrong-plain-directory-layout)"
/bin/mkdir -p "$WRONG_LAYOUT_CANDIDATE/UtterInk.app/Resources"
refresh_unsigned_evidence "$WRONG_LAYOUT_CANDIDATE"
run_sign "$WRONG_LAYOUT_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'allowlisted plain directory name in an unknown layout was accepted'
assert_no_signing 'wrong plain directory layout'

NON_MACHO_CANDIDATE="$(make_candidate non-macho-main)"
printf 'fixture\n' > "$LOG.non-macho-main"
run_sign "$NON_MACHO_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'non-Mach-O main executable was accepted'
assert_no_signing 'non-Mach-O main executable'
/bin/rm "$LOG.non-macho-main"

AMBIGUOUS_CANDIDATE="$(make_candidate ambiguous-framework)"
printf 'duplicate framework binary\n' > "$AMBIGUOUS_CANDIDATE/UtterInk.app/Contents/Frameworks/B.framework/B"
/bin/chmod 0755 "$AMBIGUOUS_CANDIDATE/UtterInk.app/Contents/Frameworks/B.framework/B"
refresh_unsigned_evidence "$AMBIGUOUS_CANDIDATE"
run_sign "$AMBIGUOUS_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'ambiguous framework executable was accepted'
assert_no_signing 'ambiguous framework executable'

NON_MACHO_EXECUTABLE_CANDIDATE="$(make_candidate executable-text)"
/bin/mkdir -p "$NON_MACHO_EXECUTABLE_CANDIDATE/UtterInk.app/Contents/Helpers"
printf '#!/bin/sh\n' > "$NON_MACHO_EXECUTABLE_CANDIDATE/UtterInk.app/Contents/Helpers/ScriptHelper"
/bin/chmod 0755 "$NON_MACHO_EXECUTABLE_CANDIDATE/UtterInk.app/Contents/Helpers/ScriptHelper"
refresh_unsigned_evidence "$NON_MACHO_EXECUTABLE_CANDIDATE"
run_sign "$NON_MACHO_EXECUTABLE_CANDIDATE" --identity "$IDENTITY" --team-id "$TEAM_ID"
[[ "$SIGN_STATUS" -ne 0 ]] || fail 'executable non-Mach-O helper was accepted'
assert_no_signing 'executable non-Mach-O helper'

printf 'sign candidate tests passed\n'
