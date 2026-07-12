#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'repository hygiene error: not a Git repository\n' >&2
  exit 1
}
cd "$TOP"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-hygiene.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TRACKED_PATHS="$TMP/tracked-paths"
git ls-files -z --cached > "$TRACKED_PATHS"

is_forbidden_path() {
  local path="$1"
  local remaining="$path"
  local component lower_component is_last

  while :; do
    component="${remaining%%/*}"
    if [[ "$remaining" == */* ]]; then
      remaining="${remaining#*/}"
      is_last=0
    else
      is_last=1
    fi
    lower_component="$(printf '%s' "$component" | tr '[:upper:]' '[:lower:]')"

    case "$lower_component" in
      .git|.build|.swiftpm|dist|.ds_store|deriveddata|xcuserdata|secrets|models)
        return 0
        ;;
      *.dmg|*.caf|*.wav|*.pem|*.p12|*.cer|*.mobileprovision|*.xcarchive|*.xcresult)
        return 0
        ;;
    esac

    if [[ "$lower_component" == .env* ]]; then
      if [[ "$component" != '.env.example' || "$is_last" -ne 1 ]]; then
        return 0
      fi
    fi

    [[ "$is_last" -eq 0 ]] || break
  done

  return 1
}

found=0
while IFS= read -r -d '' path; do
  if is_forbidden_path "$path"; then
    printf 'forbidden tracked path: %q\n' "$path" >&2
    found=1
  fi
done < "$TRACKED_PATHS"

[[ "$found" -eq 0 ]]
