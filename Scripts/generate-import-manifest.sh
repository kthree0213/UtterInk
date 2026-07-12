#!/usr/bin/env bash
set -euo pipefail

LEGACY_ROOT="${1:?legacy root required}"
ALLOWLIST="${2:?allowlist required}"
RIGHTS="${3:?rights TSV required}"
OUTPUT="${4:?output TSV required}"

for required in "$LEGACY_ROOT" "$ALLOWLIST" "$RIGHTS"; do
  [[ -e "$required" ]] || { echo "missing: $required" >&2; exit 1; }
done

awk 'NF && seen[$0]++ { exit 1 }' "$ALLOWLIST" || { echo "duplicate allowlist entry" >&2; exit 1; }
awk -F '\t' 'NR > 1 && seen[$1]++ { exit 1 }' "$RIGHTS" || { echo "duplicate rights row" >&2; exit 1; }
legacy_real="$(cd "$LEGACY_ROOT" && pwd -P)"

tmp="${OUTPUT}.tmp.$$"
trap 'rm -f "$tmp"' EXIT
mkdir -p "$(dirname "$OUTPUT")"
printf 'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer\n' > "$tmp"

purpose_for() {
  case "$1" in
    Package.*) echo package-metadata ;;
    Tests/*) echo parity-test ;;
    *.png|*.json|*.txt) echo parity-resource ;;
    *.plist) echo parity-configuration ;;
    *.swift) echo parity-source ;;
    *) echo unsupported >&2; return 1 ;;
  esac
}

while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -n "$path" ]] || continue
  case "$path" in
    /*|*..*|.git/*|.build/*|.swiftpm/*|dist/*|*.dmg|.DS_Store|*/.DS_Store|.env|.env.*)
      echo "forbidden allowlist entry: $path" >&2
      exit 1
      ;;
  esac
  source="$LEGACY_ROOT/$path"
  [[ -f "$source" && ! -L "$source" ]] || { echo "missing or symlink source: $path" >&2; exit 1; }
  source_real="$(cd "$(dirname "$source")" && pwd -P)/$(basename "$source")"
  case "$source_real" in "$legacy_real"/*) ;; *) echo "source escaped legacy root: $path" >&2; exit 1 ;; esac
  rights_line="$(awk -F '\t' -v key="$path" 'NR > 1 && $1 == key { print $2 "\t" $3 "\t" $4 }' "$RIGHTS")"
  [[ -n "$rights_line" ]] || { echo "missing rights row: $path" >&2; exit 1; }
  owner="${rights_line%%$'\t'*}"
  remainder="${rights_line#*$'\t'}"
  authority="${remainder%%$'\t'*}"
  reviewer="${remainder#*$'\t'}"
  [[ -n "$owner" && -n "$authority" && -n "$reviewer" ]] || { echo "incomplete rights row: $path" >&2; exit 1; }
  sha="$(shasum -a 256 "$source" | awk '{print $1}')"
  printf '%s\tLegacyParity/%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$path" "$sha" "$(purpose_for "$path")" "$owner" "$authority" "$reviewer" >> "$tmp"
done < "$ALLOWLIST"

mv "$tmp" "$OUTPUT"
trap - EXIT
