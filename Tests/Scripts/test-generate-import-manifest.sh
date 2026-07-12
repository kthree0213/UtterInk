#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/legacy/Packaging" "$TMP/legacy/Sources/App" "$TMP/legacy/Scripts" "$TMP/config" "$TMP/out"
printf '<plist/>\n' > "$TMP/legacy/Packaging/App.entitlements"
printf 'let value = 1\n' > "$TMP/legacy/Sources/App/Main.swift"
printf '#!/bin/sh\necho package\n' > "$TMP/legacy/Scripts/package.sh"
printf 'secret\n' > "$TMP/legacy/.env"
printf 'Packaging/App.entitlements\nScripts/package.sh\nSources/App/Main.swift\n' > "$TMP/config/allowlist.txt"
printf 'source_path\tcopyright_owner\tlicense_or_authority\treviewer\nPackaging/App.entitlements\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\nScripts/package.sh\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\nSources/App/Main.swift\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\n' > "$TMP/config/rights.tsv"

"$ROOT/Scripts/generate-import-manifest.sh" \
  "$TMP/legacy" "$TMP/config/allowlist.txt" "$TMP/config/rights.tsv" "$TMP/out/manifest.tsv"

grep -F $'Sources/App/Main.swift\tLegacyParity/Sources/App/Main.swift' "$TMP/out/manifest.tsv"
grep -F $'Packaging/App.entitlements\tLegacyParity/Packaging/App.entitlements' "$TMP/out/manifest.tsv" | grep -F $'\tparity-configuration\t'
grep -F $'Scripts/package.sh\tLegacyParity/Scripts/package.sh' "$TMP/out/manifest.tsv"
grep -F $'Scripts/package.sh\tLegacyParity/Scripts/package.sh' "$TMP/out/manifest.tsv" | grep -F $'\tparity-tooling\t'
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

printf 'unsupported\n' > "$TMP/legacy/notes.md"
printf 'notes.md\n' > "$TMP/config/allowlist.txt"
printf 'notes.md\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\n' >> "$TMP/config/rights.tsv"
rm -f "$TMP/out/manifest.tsv"
if "$ROOT/Scripts/generate-import-manifest.sh" \
  "$TMP/legacy" "$TMP/config/allowlist.txt" "$TMP/config/rights.tsv" "$TMP/out/manifest.tsv"; then
  echo 'unsupported extension was accepted' >&2
  exit 1
fi
[[ ! -e "$TMP/out/manifest.tsv" ]] || {
  echo 'unsupported extension published a manifest' >&2
  exit 1
}
