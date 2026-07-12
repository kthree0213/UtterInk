#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$ROOT/Scripts/check-repo-hygiene.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-hygiene-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

make_repo() {
  local name="$1"
  local repo="$TMP/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q --object-format=sha1
  printf '%s\n' "$repo"
}

add_tracked_file() {
  local repo="$1"
  local path="$2"
  mkdir -p "$(dirname "$repo/$path")"
  printf 'fixture\n' > "$repo/$path"
  git -C "$repo" add -f -- "$path"
}

allowed_repo="$(make_repo allowed)"
allowed_paths=(
  'README.md'
  '.env.example'
  '.gitignore'
  'Sources/WhisperModelCacheInspector.swift'
  'Sources/Models.swift'
  'Sources/Secrets.swift'
  'Docs/DerivedDataNotes.md'
  'Tools/distiller.swift'
  'Artifacts/release.dmg.notes'
)
for path in "${allowed_paths[@]}"; do
  add_tracked_file "$allowed_repo" "$path"
done

# Hygiene deliberately inspects tracked paths only. Untracked local output is
# handled by the full public-history scanner run by ci-local.sh.
mkdir -p "$allowed_repo/.build"
printf 'untracked\n' > "$allowed_repo/.build/object.o"
(cd "$allowed_repo" && "$CHECKER")

forbidden_cases=(
  'git-administration:.git'
  'swift-build:.BuIlD/object.o'
  'swiftpm-state:Nested/.SwIfTpM/configuration'
  'distribution-output:Artifacts/DiSt/bundle'
  'finder-metadata:Assets/.dS_sToRe'
  'environment-file:Config/.ENV.local'
  'environment-prefix:Config/.envrc'
  'disk-image:Artifacts/UtterInk.DmG'
  'core-audio:Audio/capture.CaF'
  'wave-audio:Audio/capture.WaV'
  'derived-data:Xcode/dErIvEdDaTa/Build.db'
  'xcode-archive:Artifacts/UtterInk.XcArChIvE/Info.plist'
  'xcode-result:Artifacts/Tests.XcReSuLt/Info.plist'
  'private-key:Credentials/release.PeM'
  'pkcs12:Credentials/release.P12'
  'certificate:Credentials/release.CeR'
  'provisioning-profile:Credentials/app.MoBiLePrOvIsIoN'
  'secrets-directory:Config/SeCrEtS/token.txt'
  'models-directory:Cache/MoDeLs/weights.bin'
  'xcode-user-data:Project/XcUsErDaTa/UserInterfaceState.xcuserstate'
)

for fixture in "${forbidden_cases[@]}"; do
  category="${fixture%%:*}"
  path="${fixture#*:}"
  repo="$(make_repo "$category")"

  if [[ "$path" == '.git' ]]; then
    # Git refuses to add its administration path through the porcelain. Start
    # with a real git-add entry, then rewrite only that equal-length index path
    # and checksum so git-ls-files can exercise the checker's reserved-name rule.
    add_tracked_file "$repo" 'xgit'
    FIXTURE_REPO="$repo" python3 -c '
import hashlib
import os
from pathlib import Path

index = Path(os.environ["FIXTURE_REPO"]) / ".git" / "index"
contents = index.read_bytes()
old = b"xgit" + bytes([0])
new = b".git" + bytes([0])
if old not in contents[:-20]:
    raise SystemExit("fixture index path not found")
body = contents[:-20].replace(old, new, 1)
index.write_bytes(body + hashlib.sha1(body).digest())
'
  else
    add_tracked_file "$repo" "$path"
  fi

  if output="$(cd "$repo" && "$CHECKER" 2>&1)"; then
    printf 'forbidden category was accepted: %s (%s)\n' "$category" "$path" >&2
    exit 1
  fi
  case "$output" in
    *'forbidden tracked path:'*) ;;
    *)
      printf 'missing checker diagnostic for %s: %s\n' "$category" "$output" >&2
      exit 1
      ;;
  esac
done

printf 'repository hygiene checker tests passed\n'
