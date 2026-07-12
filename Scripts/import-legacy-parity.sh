#!/usr/bin/env bash
set -euo pipefail
LEGACY_ROOT="${1:?legacy root required}"
MANIFEST="${2:?manifest required}"

[[ ! -e LegacyParity ]] || { echo 'LegacyParity already exists' >&2; exit 1; }
mkdir -p LegacyParity

tail -n +2 "$MANIFEST" | while IFS=$'\t' read -r source destination expected _; do
  [[ "$destination" == LegacyParity/* ]] || { echo "bad destination: $destination" >&2; exit 1; }
  actual="$(shasum -a 256 "$LEGACY_ROOT/$source" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "hash mismatch: $source" >&2; exit 1; }
  mkdir -p "$(dirname "$destination")"
  cp -p "$LEGACY_ROOT/$source" "$destination"
done

if find LegacyParity -name .DS_Store -o -name .env -o -name .build -o -name .git | grep -q .; then
  echo 'forbidden import artifact found' >&2
  exit 1
fi
