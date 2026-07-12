#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/legacy/Sources/App" "$TMP/config" "$TMP/out"
printf 'let value = 1\n' > "$TMP/legacy/Sources/App/Main.swift"
printf 'secret\n' > "$TMP/legacy/.env"
printf 'Sources/App/Main.swift\n' > "$TMP/config/allowlist.txt"
printf 'source_path\tcopyright_owner\tlicense_or_authority\treviewer\nSources/App/Main.swift\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\n' > "$TMP/config/rights.tsv"

"$ROOT/Scripts/generate-import-manifest.sh" \
  "$TMP/legacy" "$TMP/config/allowlist.txt" "$TMP/config/rights.tsv" "$TMP/out/manifest.tsv"

grep -F $'Sources/App/Main.swift\tLegacyParity/Sources/App/Main.swift' "$TMP/out/manifest.tsv"
grep -F 'Example Owner' "$TMP/out/manifest.tsv"
if grep -F '.env' "$TMP/out/manifest.tsv"; then
  echo 'forbidden file entered manifest' >&2
  exit 1
fi

printf 'Sources/App/Main.swift\n.build/object.o\n' > "$TMP/config/allowlist.txt"
if "$ROOT/Scripts/generate-import-manifest.sh" \
  "$TMP/legacy" "$TMP/config/allowlist.txt" "$TMP/config/rights.tsv" "$TMP/out/manifest.tsv"; then
  echo 'forbidden allowlist entry was accepted' >&2
  exit 1
fi
