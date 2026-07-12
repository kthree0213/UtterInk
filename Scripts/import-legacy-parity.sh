#!/usr/bin/env bash
set -euo pipefail

LEGACY_ROOT="${1:?legacy root required}"
MANIFEST="${2:?manifest required}"
EXPECTED_HEADER=$'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer'

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

is_normal_relative_path() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 1
  [[ "$candidate" != /* ]] || return 1
  [[ "$candidate" != */ ]] || return 1
  [[ "$candidate" != *//* ]] || return 1
  [[ "$candidate" != . && "$candidate" != .. ]] || return 1
  [[ "$candidate" != ./* && "$candidate" != ../* ]] || return 1
  [[ "$candidate" != */./* && "$candidate" != */. ]] || return 1
  [[ "$candidate" != */../* && "$candidate" != */.. ]] || return 1
}

is_forbidden_path() {
  local candidate="$1"
  local component lower
  local old_ifs="$IFS"
  IFS='/'
  read -r -a components <<< "$candidate"
  IFS="$old_ifs"

  for component in "${components[@]}"; do
    lower="$(printf '%s' "$component" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      .git|.build|.swiftpm|dist|.ds_store|models|model-cache|model_cache|modelcache|model-caches|model_caches|modelcaches|model-weights|model_weights|secret|secrets|credential|credentials|key|keys|private-keys|private_keys)
        return 0
        ;;
      .env*|secret.*|secrets.*|credentials.*|credential.*|id_rsa*|id_ed25519*|api-key*|api_key*|apikey*|access-token*|access_token*|private-key*|private_key*|*.pem|*.key|*.p12|*.pfx|*.dmg)
        return 0
        ;;
    esac
  done
  return 1
}

[[ ! -e LegacyParity ]] || fail 'LegacyParity already exists'
[[ -d "$LEGACY_ROOT" ]] || fail 'legacy root must be a directory'
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fail 'manifest must be a regular file'

LEGACY_REAL="$(cd "$LEGACY_ROOT" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/utterink-legacy-import.XXXXXX")"
STAGING=''
cleanup() {
  rm -rf -- "$WORK"
  if [[ -n "$STAGING" && -e "$STAGING" ]]; then
    rm -rf -- "$STAGING"
  fi
}
trap cleanup EXIT

MANIFEST_SNAPSHOT="$WORK/manifest.tsv"
VALIDATED_ROWS="$WORK/validated.tsv"
SEEN_SOURCES="$WORK/seen-sources"
SEEN_DESTINATIONS="$WORK/seen-destinations"
cp "$MANIFEST" "$MANIFEST_SNAPSHOT"
: > "$VALIDATED_ROWS"
: > "$SEEN_SOURCES"
: > "$SEEN_DESTINATIONS"

IFS= read -r header < "$MANIFEST_SNAPSHOT" || fail 'manifest is empty'
[[ "$header" == "$EXPECTED_HEADER" ]] || fail 'bad manifest header'

awk -F '\t' '
  NR == 1 { next }
  {
    if (NF != 7) {
      printf "manifest row %d must have exactly 7 columns\n", NR > "/dev/stderr"
      exit 1
    }
    for (i = 1; i <= 7; i++) {
      if ($i == "") {
        printf "manifest row %d contains an empty field\n", NR > "/dev/stderr"
        exit 1
      }
    }
    rows++
  }
  END {
    if (rows == 0) {
      print "manifest must contain at least one data row" > "/dev/stderr"
      exit 1
    }
  }
' "$MANIFEST_SNAPSHOT" || exit 1

while IFS=$'\t' read -r source destination expected purpose owner authority reviewer; do
  is_normal_relative_path "$source" || fail "bad source path: $source"
  [[ "$destination" == "LegacyParity/$source" ]] || fail "bad destination: $destination"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "bad sha256: $source"
  is_forbidden_path "$source" && fail "forbidden import path: $source"

  if grep -Fqx -- "$source" "$SEEN_SOURCES"; then
    fail "duplicate source: $source"
  fi
  if grep -Fqx -- "$destination" "$SEEN_DESTINATIONS"; then
    fail "duplicate destination: $destination"
  fi
  printf '%s\n' "$source" >> "$SEEN_SOURCES"
  printf '%s\n' "$destination" >> "$SEEN_DESTINATIONS"

  source_path="$LEGACY_REAL/$source"
  [[ -f "$source_path" && ! -L "$source_path" ]] || fail "source must be a regular non-symlink file: $source"

  current="$LEGACY_REAL"
  old_ifs="$IFS"
  IFS='/'
  read -r -a source_components <<< "$source"
  IFS="$old_ifs"
  for component in "${source_components[@]}"; do
    current="$current/$component"
    [[ ! -L "$current" ]] || fail "symlink source path rejected: $source"
  done

  source_parent="$(cd "$(dirname "$source_path")" && pwd -P)"
  case "$source_parent/$(basename "$source_path")" in
    "$LEGACY_REAL"/*) ;;
    *) fail "source escapes legacy root: $source" ;;
  esac

  actual="$(shasum -a 256 "$source_path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "hash mismatch: $source"
  printf '%s\t%s\t%s\n' "$source" "$destination" "$expected" >> "$VALIDATED_ROWS"
done < <(tail -n +2 "$MANIFEST_SNAPSHOT")

[[ ! -e LegacyParity ]] || fail 'LegacyParity already exists'
STAGING="$(mktemp -d .LegacyParity.import.XXXXXX)"

while IFS=$'\t' read -r source destination expected; do
  relative_destination="${destination#LegacyParity/}"
  mkdir -p "$STAGING/$(dirname "$relative_destination")"
  cp -p "$LEGACY_REAL/$source" "$STAGING/$relative_destination"
  staged_hash="$(shasum -a 256 "$STAGING/$relative_destination" | awk '{print $1}')"
  [[ "$staged_hash" == "$expected" ]] || fail "staged hash mismatch: $source"
done < "$VALIDATED_ROWS"

[[ ! -e LegacyParity ]] || fail 'LegacyParity already exists'
mv "$STAGING" LegacyParity
STAGING=''
