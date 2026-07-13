#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-ats-policy.XXXXXX")"
FIXTURE_PID=""
SOURCE_PACKAGES=""

cleanup_generated_repository_caches() {
  local package_root
  for package_root in "$ROOT/LegacyParity" "$ROOT/Packages/UtterInkKit"; do
    rmdir -- "$package_root/.swiftpm/xcode" 2>/dev/null || :
    rmdir -- "$package_root/.swiftpm/configuration" 2>/dev/null || :
    rmdir -- "$package_root/.swiftpm" 2>/dev/null || :
  done
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" 2>/dev/null || :
    wait "$FIXTURE_PID" 2>/dev/null || :
  fi
  cleanup_generated_repository_caches
  rm -rf -- "$TMP"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TMP="$(cd "$TMP" && pwd -P)"
case "$TMP" in
  "$ROOT"|"$ROOT"/*)
    printf 'ATS probe temporary root must be outside the repository\n' >&2
    exit 1
    ;;
esac

canonical_destination() {
  local candidate="$1"
  local parent
  local base
  if [[ -L "$candidate" && ! -e "$candidate" ]]; then
    return 1
  fi
  if [[ -e "$candidate" ]]; then
    [[ -d "$candidate" ]] || return 1
    (cd "$candidate" && pwd -P)
    return
  fi
  parent="$(dirname "$candidate")"
  base="$(basename "$candidate")"
  [[ -d "$parent" ]] || return 1
  parent="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent" "$base"
}

if ! SOURCE_PACKAGES="$(canonical_destination "${UTTERINK_CLONED_SOURCE_PACKAGES_DIR:-$TMP/SourcePackages}")"; then
  printf 'cloned source packages path cannot be resolved safely\n' >&2
  exit 1
fi
if [[ "$SOURCE_PACKAGES" == "$ROOT" || "$SOURCE_PACKAGES" == "$ROOT"/* ]]; then
  printf 'cloned source packages must be outside the repository\n' >&2
  exit 1
fi

PORT_FILE="$TMP/fixture-port"
python3 - "$PORT_FILE" >"$TMP/fixture.stdout" 2>"$TMP/fixture.stderr" <<'PY' &
import http.server
import json
import pathlib
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/v1/models" or self.headers.get("Authorization") is not None:
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.dumps(
            {"data": [{"id": "ats-probe-model"}]},
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
PY
FIXTURE_PID=$!

for _ in {1..200}; do
  [[ -s "$PORT_FILE" ]] && break
  if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then
    printf 'ATS fixture failed to start\n' >&2
    exit 1
  fi
  sleep 0.05
done
if [[ ! -s "$PORT_FILE" ]]; then
  printf 'ATS fixture did not publish a port\n' >&2
  exit 1
fi
PORT="$(<"$PORT_FILE")"

xcodegen generate
xcodebuild \
  -project UtterInk.xcodeproj \
  -scheme ATSPolicyProbe \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TMP/DerivedData" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build

APP="$TMP/DerivedData/Build/Products/Debug/ATSPolicyProbe.app"
BUILT_PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/ATSPolicyProbe"
codesign --verify --strict "$APP"
if ! codesign -d --entitlements :- "$APP" \
  >"$TMP/probe-entitlements.plist" \
  2>"$TMP/codesign-entitlements.stderr"; then
  printf 'signed ATS probe entitlement extraction failed\n' >&2
  exit 1
fi

python3 - \
  App/Supporting/Info.plist \
  Tests/ATSPolicyProbe/Info.plist \
  "$BUILT_PLIST" \
  "$TMP/probe-entitlements.plist" <<'PY'
import plistlib
import sys

values = []
for path in sys.argv[1:4]:
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    if "NSLocalNetworkUsageDescription" in plist:
        raise SystemExit(f"local-network usage description is forbidden in {path}")
    ats = plist.get("NSAppTransportSecurity")
    is_allowed = ats is None or (
        type(ats) is dict
        and set(ats) == {"NSAllowsLocalNetworking"}
        and type(ats["NSAllowsLocalNetworking"]) is bool
        and ats["NSAllowsLocalNetworking"] is True
    )
    if not is_allowed:
        raise SystemExit(f"disallowed ATS policy shape in {path}")
    values.append(ats)

if values[1:] != values[:-1]:
    raise SystemExit("ATS policies differ between app, probe, and built product")

with open(sys.argv[4], "rb") as handle:
    entitlements = plistlib.load(handle)
for key in (
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
):
    if key in entitlements:
        raise SystemExit("signed ATS probe contains a forbidden entitlement")
PY

printf 'ATS_LOOPBACK_PASS\n' >"$TMP/expected.stdout"
set +e
"$EXECUTABLE" "http://127.0.0.1:$PORT/v1" \
  >"$TMP/probe.stdout" \
  2>"$TMP/probe.stderr"
PROBE_STATUS=$?
set -e
if [[ "$PROBE_STATUS" -ne 0 ]] || ! cmp -s "$TMP/expected.stdout" "$TMP/probe.stdout"; then
  if grep -Eq -- '(-1022|NSURLErrorAppTransportSecurityRequiresSecureConnection|AppTransportSecurityRequiresSecureConnection)' "$TMP/probe.stderr"; then
    printf 'signed ATS loopback probe blocked by ATS -1022\n' >&2
  else
    printf 'signed ATS loopback probe failed\n' >&2
  fi
  exit 1
fi

printf 'signed ATS loopback policy probe passed\n'
