#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/legacy/Sources" "$TMP/repo/docs/provenance"
printf 'let parity = true\n' > "$TMP/legacy/Sources/Main.swift"
sha="$(shasum -a 256 "$TMP/legacy/Sources/Main.swift" | awk '{print $1}')"
printf 'source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer\nSources/Main.swift\tLegacyParity/Sources/Main.swift\t%s\tparity-source\tExample Owner\tAuthorized for Apache-2.0\tTest Reviewer\n' "$sha" > "$TMP/repo/docs/provenance/legacy-source-import.tsv"
(cd "$TMP/repo" && "$ROOT/Scripts/import-legacy-parity.sh" "$TMP/legacy" docs/provenance/legacy-source-import.tsv)
cmp "$TMP/legacy/Sources/Main.swift" "$TMP/repo/LegacyParity/Sources/Main.swift"
