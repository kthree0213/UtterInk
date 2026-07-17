#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REGISTER_SOURCE="$ROOT/Scripts/release/register-notary-profile.sh"
VERIFY_SOURCE="$ROOT/Scripts/release/verify-notary-profile-binding.sh"

fail() {
  printf 'notary profile tests failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$REGISTER_SOURCE" ]] || fail 'register-notary-profile.sh is missing or not executable'
[[ -x "$VERIFY_SOURCE" ]] || fail 'verify-notary-profile-binding.sh is missing or not executable'

TMP="$(/usr/bin/mktemp -d /private/tmp/utterink-notary-profile-tests.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap '/bin/rm -rf "$TMP"' EXIT HUP INT TERM
/bin/chmod 0700 "$TMP"

BASE="$TMP/base"
TOOLS="$BASE/FixtureTools"
ORDINARY="$BASE/OrdinaryPath"
LOG="$TMP/tools.log"
STDOUT="$TMP/stdout"
STDERR="$TMP/stderr"
NOW='2026-07-15T12:00:00Z'
IDENTITY='Developer ID Application: Fixture Author (ABCDE12345)'
TEAM_ID='ABCDE12345'
PROFILE='utterink-fixture-profile'

/bin/mkdir -p "$BASE/Scripts/release" "$BASE/.notary-profile-bindings" "$TOOLS" "$ORDINARY"
/bin/chmod 0700 "$BASE" "$BASE/.notary-profile-bindings" "$TOOLS" "$ORDINARY"
/bin/cp "$REGISTER_SOURCE" "$VERIFY_SOURCE" "$BASE/Scripts/release/"
/bin/chmod 0700 "$BASE/Scripts/release/register-notary-profile.sh" "$BASE/Scripts/release/verify-notary-profile-binding.sh"
printf 'utterink-notary-profile-test-repository-v1\n' > "$BASE/.utterink-notary-profile-test-repository"
/bin/chmod 0600 "$BASE/.utterink-notary-profile-test-repository"

/usr/bin/git -C "$BASE" init -q
/usr/bin/git -C "$BASE" config user.name 'UtterInk Notary Profile Test'
/usr/bin/git -C "$BASE" config user.email 'notary-profile-test@example.invalid'
/usr/bin/git -C "$BASE" add .
/usr/bin/git -C "$BASE" commit -q -m 'offline notary profile fixture'

cat > "$TOOLS/security" <<'FAKE_SECURITY'
#!/usr/bin/env bash
set -euo pipefail
log="${UTTERINK_FIXTURE_LOG:?}"
printf 'security' >> "$log"
for argument in "$@"; do printf '\t%s' "$argument" >> "$log"; done
printf '\n' >> "$log"
default_identity='Developer ID Application: Fixture Author (ABCDE12345)'
case "${1-}" in
  find-identity)
    [[ "$#" -eq 4 && "$2" == -v && "$3" == -p && "$4" == codesigning ]] || exit 60
    if [[ -f "$log.missing-private-key" ]]; then
      printf '     0 valid identities found\n'
    elif [[ -f "$log.duplicate-identity" ]]; then
      printf '  1) 1111111111111111111111111111111111111111 "%s"\n' "$default_identity"
      printf '  2) 2222222222222222222222222222222222222222 "%s"\n' "$default_identity"
      printf '     2 valid identities found\n'
    elif [[ -f "$log.wrong-identity" ]]; then
      printf '  1) 1111111111111111111111111111111111111111 "Developer ID Application: Other Author (ABCDE12345)"\n'
      printf '     1 valid identities found\n'
    else
      printf '  1) 1111111111111111111111111111111111111111 "%s"\n' "$default_identity"
      printf '     1 valid identities found\n'
    fi
    ;;
  find-certificate)
    [[ "$#" -eq 5 && "$2" == -a && "$3" == -c && -n "$4" && "$5" == -p ]] || exit 61
    printf '%s\n' \
      '-----BEGIN CERTIFICATE-----' \
      'RklYVFVSRQ==' \
      '-----END CERTIFICATE-----'
    if [[ -f "$log.duplicate-certificate" ]]; then
      printf '%s\n' \
        '-----BEGIN CERTIFICATE-----' \
        'RklYVFVSRVQy' \
        '-----END CERTIFICATE-----'
    fi
    ;;
  verify-cert)
    [[ "$#" -eq 5 && "$2" == -c && -f "$3" && "$4" == -p && "$5" == codeSign ]] || exit 62
    [[ ! -f "$log.untrusted" ]]
    ;;
  *) exit 63 ;;
esac
FAKE_SECURITY

cat > "$TOOLS/openssl" <<'FAKE_OPENSSL'
#!/usr/bin/env bash
set -euo pipefail
log="${UTTERINK_FIXTURE_LOG:?}"
printf 'openssl' >> "$log"
for argument in "$@"; do printf '\t%s' "$argument" >> "$log"; done
printf '\n' >> "$log"
[[ "${1-}" == x509 && "${2-}" == -in && -f "${3-}" ]]
case "$*" in
  *'-checkend 0 -noout'*)
    [[ ! -f "$log.expired" ]]
    ;;
  *'-subject -nameopt sep_multiline,lname,space_eq'*)
    printf '%s\n' 'subject='
    if [[ -f "$log.wrong-common-name" ]]; then
      printf '    commonName = Developer ID Application: Wrong Author (ABCDE12345)\n'
    else
      printf '    commonName = Developer ID Application: Fixture Author (ABCDE12345)\n'
    fi
    if [[ -f "$log.wrong-ou" ]]; then
      printf '    organizationalUnitName = ZZZZZ99999\n'
    else
      printf '    organizationalUnitName = ABCDE12345\n'
    fi
    ;;
  *'-fingerprint -sha1'*)
    if [[ -f "$log.certificate-sha1-mismatch" ]]; then
      printf 'sha1 Fingerprint=22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22\n'
    else
      printf 'sha1 Fingerprint=11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11\n'
    fi
    ;;
  *'-fingerprint -sha256'*)
    if [[ -f "$log.certificate-sha256-mismatch" ]]; then
      printf 'sha256 Fingerprint=CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC:CC\n'
    else
      printf 'sha256 Fingerprint=BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB\n'
    fi
    ;;
  *) exit 64 ;;
esac
FAKE_OPENSSL

cat > "$TOOLS/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
set -euo pipefail
log="${UTTERINK_FIXTURE_LOG:?}"
printf 'xcrun' >> "$log"
for argument in "$@"; do printf '\t%s' "$argument" >> "$log"; done
printf '\n' >> "$log"
for argument in "$@"; do
  case "$argument" in
    --apple-id|--password|--api-key|--api-key-id|--api-issuer|--issuer) exit 70 ;;
  esac
done
case "${1-}:${2-}" in
  notarytool:--version)
    [[ "$#" -eq 2 ]]
    if [[ -f "$log.version-mismatch" ]]; then
      printf 'notarytool version 9.9.9 (fixture mismatch)\n'
    else
      printf 'notarytool version 2.1.0 (fixture)\n'
    fi
    ;;
  notarytool:store-credentials)
    [[ "$#" -eq 6 && "$3" == utterink-fixture-profile && "$4" == --team-id && "$5" == ABCDE12345 && "$6" == --validate ]] || exit 71
    [[ ! -f "$log.store-failure" ]] || exit 74
    printf 'Credentials validated and saved.\n'
    ;;
  notarytool:history)
    [[ "$#" -eq 6 && "$3" == --keychain-profile && "$4" == utterink-fixture-profile && "$5" == --output-format && "$6" == json ]] || exit 72
    [[ ! -f "$log.history-failure" ]] || exit 75
    if [[ -f "$log.malformed-history" ]]; then
      printf 'not-json\n'
    else
      printf '{"history":[]}\n'
    fi
    ;;
  notarytool:submit|stapler:*|*) exit 73 ;;
esac
FAKE_XCRUN

/bin/chmod 0700 "$TOOLS/security" "$TOOLS/openssl" "$TOOLS/xcrun"
printf 'utterink-notary-profile-test-tools-v1\n' > "$TOOLS/.utterink-notary-profile-test-tools"
/bin/chmod 0600 "$TOOLS/.utterink-notary-profile-test-tools"

for tool in security openssl xcrun; do
  cat > "$ORDINARY/$tool" <<EOF
#!/usr/bin/env bash
printf '$tool\n' >> '$TMP/ordinary-tools.log'
exit 97
EOF
  /bin/chmod 0700 "$ORDINARY/$tool"
done

RUN_STATUS=0
run_script() {
  local script="$1"
  local now="$2"
  shift 2
  : > "$LOG"
  /bin/rm -f "$STDOUT" "$STDERR" "$TMP/ordinary-tools.log"
  set +e
  (
    cd "$BASE"
    /usr/bin/env \
      PATH="$ORDINARY:/usr/bin:/bin:/usr/sbin:/sbin" \
      BASH_ENV="$TMP/hostile-bash-env" \
      UTTERINK_RELEASE_TEST_MODE=1 \
      UTTERINK_RELEASE_TEST_TOOL_ROOT="$TOOLS" \
      UTTERINK_RELEASE_TEST_NOW="$now" \
      UTTERINK_FIXTURE_LOG="$LOG" \
      "$script" "$@"
  ) > "$STDOUT" 2> "$STDERR"
  RUN_STATUS=$?
  set -e
  [[ ! -e "$TMP/ordinary-tools.log" ]] || fail 'script consulted ordinary PATH tools'
}

expect_failure() {
  local context="$1"
  [[ "$RUN_STATUS" -ne 0 ]] || fail "$context was accepted"
  [[ ! -s "$STDOUT" ]] || fail "$context emitted unsanitized stdout"
  /usr/bin/grep -Eq '^notary profile (registration|verification) error: [a-z0-9-]+$' "$STDERR" ||
    fail "$context did not emit one sanitized error category"
  if /usr/bin/grep -Fq "$PROFILE" "$STDERR"; then
    fail "$context leaked the profile name"
  fi
}

file_sha256() {
  /usr/bin/python3 -I - "$1" <<'PY'
from pathlib import Path
import hashlib
import sys

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

validate_receipt() {
  /usr/bin/python3 -I - "$1" "$PROFILE" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import sys

path = Path(sys.argv[1])
profile = sys.argv[2]
metadata = os.lstat(path)
if (
    not stat.S_ISREG(metadata.st_mode)
    or stat.S_ISLNK(metadata.st_mode)
    or stat.S_IMODE(metadata.st_mode) != 0o600
    or metadata.st_uid != os.geteuid()
    or metadata.st_nlink != 1
):
    raise SystemExit(1)
data = path.read_bytes()

def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result

receipt = json.loads(data.decode("utf-8"), object_pairs_hook=unique)
expected_keys = {
    "schemaVersion", "bindingNonce", "appleTeamID", "signingCertificateSHA256",
    "profileNameSalt", "profileNameHashSHA256", "notarytoolVersion",
    "validatedAt", "expiresAt", "selfSHA256",
}
if type(receipt) is not dict or set(receipt) != expected_keys:
    raise SystemExit(1)
if type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1:
    raise SystemExit(1)
for key in ("bindingNonce", "profileNameSalt", "profileNameHashSHA256", "signingCertificateSHA256", "selfSHA256"):
    if type(receipt[key]) is not str or re.fullmatch(r"[0-9a-f]{64}", receipt[key]) is None:
        raise SystemExit(1)
if receipt["appleTeamID"] != "ABCDE12345" or receipt["signingCertificateSHA256"] != "b" * 64:
    raise SystemExit(1)
if receipt["notarytoolVersion"] != "notarytool version 2.1.0 (fixture)":
    raise SystemExit(1)
if receipt["validatedAt"] != "2026-07-15T12:00:00Z" or receipt["expiresAt"] != "2026-07-16T12:00:00Z":
    raise SystemExit(1)
validated = datetime.strptime(receipt["validatedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
expires = datetime.strptime(receipt["expiresAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
if int((expires - validated).total_seconds()) != 86400:
    raise SystemExit(1)
salt = bytes.fromhex(receipt["profileNameSalt"])
expected_profile_hash = hashlib.sha256(
    b"UtterInk-notary-profile-v1\0" + salt + profile.encode("utf-8", errors="strict")
).hexdigest()
if receipt["profileNameHashSHA256"] != expected_profile_hash:
    raise SystemExit(1)
without_self = dict(receipt)
actual_self = without_self.pop("selfSHA256")
canonical_without_self = (
    json.dumps(without_self, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
).encode("utf-8")
if actual_self != hashlib.sha256(canonical_without_self).hexdigest():
    raise SystemExit(1)
canonical = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
if data != canonical:
    raise SystemExit(1)
lowered = data.lower()
for forbidden in (b"appleid", b"apple id", b"password", b"api key", b"private key", b"begin certificate", profile.encode().lower()):
    if forbidden in lowered:
        raise SystemExit(1)
PY
}

rewrite_receipt() {
  local source="$1"
  local destination="$2"
  local key="$3"
  local value="$4"
  /usr/bin/python3 -I - "$source" "$destination" "$key" "$value" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import sys

source, destination = Path(sys.argv[1]), Path(sys.argv[2])
receipt = json.loads(source.read_text(encoding="utf-8"))
receipt[sys.argv[3]] = sys.argv[4]
receipt.pop("selfSHA256", None)
canonical = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
receipt["selfSHA256"] = hashlib.sha256(canonical).hexdigest()
encoded = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    os.write(descriptor, encoded)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

REGISTER="$BASE/Scripts/release/register-notary-profile.sh"
VERIFY="$BASE/Scripts/release/verify-notary-profile-binding.sh"
VALID_RECEIPT="$BASE/.notary-profile-bindings/valid.json"

LONG_PROFILE="$(printf 'a%.0s' {1..129})"
NON_ASCII_PROFILE=$'utterink-\303\251'
INVALID_PROFILES=('utterink local' "$LONG_PROFILE" "$NON_ASCII_PROFILE")
INVALID_PROFILE_LABELS=(space 129-bytes non-ascii)
for profile_index in "${!INVALID_PROFILES[@]}"; do
  invalid_profile="${INVALID_PROFILES[$profile_index]}"
  invalid_label="${INVALID_PROFILE_LABELS[$profile_index]}"
  invalid_receipt="$BASE/.notary-profile-bindings/invalid-profile-$invalid_label.json"
  run_script "$REGISTER" "$NOW" \
    --identity "$IDENTITY" --team-id "$TEAM_ID" --keychain-profile "$invalid_profile" --receipt "$invalid_receipt"
  expect_failure "registration profile with $invalid_label"
  /usr/bin/grep -Fxq 'notary profile registration error: invalid-profile-name' "$STDERR" ||
    fail "registration profile with $invalid_label was not rejected at the shared profile boundary"
  [[ ! -e "$invalid_receipt" && ! -s "$LOG" ]] ||
    fail "registration profile with $invalid_label reached an Apple tool or created a receipt"
done

run_script "$REGISTER" "$NOW" \
  --identity "$IDENTITY" --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT"
[[ "$RUN_STATUS" -eq 0 ]] || fail "valid registration failed: $(/bin/cat "$STDERR")"
[[ ! -s "$STDOUT" && ! -s "$STDERR" ]] || fail 'valid registration was not silent'
validate_receipt "$VALID_RECEIPT" || fail 'valid registration receipt was not exact and canonical'
VALID_DIGEST="$(file_sha256 "$VALID_RECEIPT")"
[[ "$VALID_DIGEST" =~ ^[0-9a-f]{64}$ ]]
/usr/bin/grep -Fxq $'xcrun\tnotarytool\tstore-credentials\tutterink-fixture-profile\t--team-id\tABCDE12345\t--validate' "$LOG" ||
  fail 'registration did not use exact interactive store-credentials argv'
/usr/bin/grep -Fxq $'xcrun\tnotarytool\thistory\t--keychain-profile\tutterink-fixture-profile\t--output-format\tjson' "$LOG" ||
  fail 'registration did not validate notarytool history'
[[ "$(/usr/bin/grep -c '^xcrun' "$LOG")" -eq 3 ]] || fail 'registration invoked unexpected Apple commands'
if /usr/bin/grep -Eqi -- '--apple-id|--password|--api-key|--issuer|submit|stapler' "$LOG"; then
  fail 'registration argv contained credentials or an upload command'
fi

for profile_index in "${!INVALID_PROFILES[@]}"; do
  invalid_profile="${INVALID_PROFILES[$profile_index]}"
  invalid_label="${INVALID_PROFILE_LABELS[$profile_index]}"
  run_script "$VERIFY" "$NOW" \
    --team-id "$TEAM_ID" --keychain-profile "$invalid_profile" --receipt "$VALID_RECEIPT" \
    --expected-receipt-sha256 "$VALID_DIGEST"
  expect_failure "verification profile with $invalid_label"
  /usr/bin/grep -Fxq 'notary profile verification error: invalid-profile-name' "$STDERR" ||
    fail "verification profile with $invalid_label was not rejected at the shared profile boundary"
  [[ ! -s "$LOG" ]] || fail "verification profile with $invalid_label reached an Apple tool"
done

SECOND_RECEIPT="$BASE/.notary-profile-bindings/second.json"
run_script "$REGISTER" "$NOW" \
  --identity "$IDENTITY" --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$SECOND_RECEIPT"
[[ "$RUN_STATUS" -eq 0 ]] || fail 'second valid registration failed'
/usr/bin/python3 -I - "$VALID_RECEIPT" "$SECOND_RECEIPT" <<'PY' || fail 'nonce or salt was reused'
from pathlib import Path
import json
import sys

first, second = (json.loads(Path(path).read_text(encoding="utf-8")) for path in sys.argv[1:])
if first["bindingNonce"] == second["bindingNonce"] or first["profileNameSalt"] == second["profileNameSalt"]:
    raise SystemExit(1)
PY

run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
[[ "$RUN_STATUS" -eq 0 ]] || fail "valid binding verification failed: $(/bin/cat "$STDERR")"
[[ ! -s "$STDOUT" && ! -s "$STDERR" ]] || fail 'valid binding verification was not silent'
[[ "$(/usr/bin/grep -c '^xcrun' "$LOG")" -eq 2 ]] || fail 'binding verification invoked unexpected Apple commands'
if /usr/bin/grep -q 'store-credentials\|submit\|stapler' "$LOG"; then
  fail 'binding verification changed credentials or uploaded data'
fi

for invalid_team in ABCDE1234 ABCDE123456 abcde12345 'ABCDE-2345'; do
  receipt="$BASE/.notary-profile-bindings/invalid-team-${invalid_team//[^A-Za-z0-9]/x}.json"
  run_script "$REGISTER" "$NOW" \
    --identity "$IDENTITY" --team-id "$invalid_team" --keychain-profile "$PROFILE" --receipt "$receipt"
  expect_failure "invalid Team ID $invalid_team"
  [[ ! -e "$receipt" ]] || fail 'invalid Team ID created a receipt'
  [[ ! -s "$LOG" ]] || fail 'invalid Team ID reached an Apple tool'
done

run_script "$REGISTER" "$NOW" \
  --identity 'Developer ID Application: Other Author (ABCDE12345)' --team-id "$TEAM_ID" \
  --keychain-profile "$PROFILE" --receipt "$BASE/.notary-profile-bindings/wrong-identity.json"
expect_failure 'certificate identity mismatch'
[[ ! -e "$BASE/.notary-profile-bindings/wrong-identity.json" ]] || fail 'identity mismatch created a receipt'

failure_index=0
for failure_marker in \
  wrong-ou wrong-common-name untrusted expired missing-private-key duplicate-identity \
  duplicate-certificate certificate-sha1-mismatch store-failure history-failure malformed-history; do
  failure_index=$((failure_index + 1))
  receipt="$BASE/.notary-profile-bindings/register-failure-$failure_index.json"
  printf 'fixture\n' > "$LOG.$failure_marker"
  run_script "$REGISTER" "$NOW" \
    --identity "$IDENTITY" --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$receipt"
  expect_failure "registration $failure_marker"
  [[ ! -e "$receipt" ]] || fail "registration $failure_marker created a receipt"
  /bin/rm "$LOG.$failure_marker"
done

run_script "$REGISTER" "$NOW" \
  --identity "$IDENTITY" --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$BASE/outside.json"
expect_failure 'receipt outside canonical binding directory'
[[ ! -e "$BASE/outside.json" ]] || fail 'outside receipt was created'

printf 'preserve\n' > "$BASE/.notary-profile-bindings/preexisting.json"
/bin/chmod 0600 "$BASE/.notary-profile-bindings/preexisting.json"
run_script "$REGISTER" "$NOW" \
  --identity "$IDENTITY" --team-id "$TEAM_ID" --keychain-profile "$PROFILE" \
  --receipt "$BASE/.notary-profile-bindings/preexisting.json"
expect_failure 'preexisting receipt'
[[ "$(/bin/cat "$BASE/.notary-profile-bindings/preexisting.json")" == preserve ]] || fail 'preexisting receipt changed'

run_script "$VERIFY" "$NOW" \
  --team-id ZZZZZ99999 --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
expect_failure 'verification Team ID mismatch'
[[ ! -s "$LOG" ]] || fail 'Team mismatch reached an Apple tool'

run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile wrong-profile --receipt "$VALID_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
expect_failure 'verification profile mismatch'
[[ ! -s "$LOG" ]] || fail 'profile mismatch reached an Apple tool'

run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT" \
  --expected-receipt-sha256 "$(printf '0%.0s' {1..64})"
expect_failure 'expected receipt digest mismatch'
[[ ! -s "$LOG" ]] || fail 'receipt digest mismatch reached an Apple tool'

CERT_MISMATCH="$BASE/.notary-profile-bindings/cert-mismatch.json"
rewrite_receipt "$VALID_RECEIPT" "$CERT_MISMATCH" signingCertificateSHA256 "$(printf 'c%.0s' {1..64})"
run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$CERT_MISMATCH" \
  --expected-receipt-sha256 "$(file_sha256 "$CERT_MISMATCH")"
expect_failure 'receipt certificate digest mismatch'
if /usr/bin/grep -q '^xcrun.*history' "$LOG"; then fail 'certificate mismatch reached profile history'; fi

LONG_FRESHNESS="$BASE/.notary-profile-bindings/long-freshness.json"
rewrite_receipt "$VALID_RECEIPT" "$LONG_FRESHNESS" expiresAt '2026-07-16T13:00:00Z'
run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$LONG_FRESHNESS" \
  --expected-receipt-sha256 "$(file_sha256 "$LONG_FRESHNESS")"
expect_failure 'overlong receipt freshness'
[[ ! -s "$LOG" ]] || fail 'overlong freshness reached an Apple tool'

run_script "$VERIFY" '2026-07-16T12:00:00Z' \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
expect_failure 'expired receipt'
[[ ! -s "$LOG" ]] || fail 'expired receipt reached an Apple tool'

run_script "$VERIFY" '2026-07-15T11:59:59Z' \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
expect_failure 'future receipt'
[[ ! -s "$LOG" ]] || fail 'future receipt reached an Apple tool'

for verify_marker in \
  wrong-identity wrong-ou wrong-common-name untrusted expired missing-private-key \
  duplicate-identity duplicate-certificate certificate-sha1-mismatch \
  certificate-sha256-mismatch version-mismatch history-failure malformed-history; do
  printf 'fixture\n' > "$LOG.$verify_marker"
  run_script "$VERIFY" "$NOW" \
    --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$VALID_RECEIPT" \
    --expected-receipt-sha256 "$VALID_DIGEST"
  expect_failure "verification $verify_marker"
  /bin/rm "$LOG.$verify_marker"
done

TAMPERED="$BASE/.notary-profile-bindings/tampered.json"
/bin/cp "$VALID_RECEIPT" "$TAMPERED"
/usr/bin/python3 -I - "$TAMPERED" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
path.write_bytes(data.replace(b'"appleTeamID":"ABCDE12345"', b'"appleTeamID":"ZZZZZ99999"'))
PY
/bin/chmod 0600 "$TAMPERED"
run_script "$VERIFY" "$NOW" \
  --team-id ZZZZZ99999 --keychain-profile "$PROFILE" --receipt "$TAMPERED" \
  --expected-receipt-sha256 "$(file_sha256 "$TAMPERED")"
expect_failure 'tampered self hash'
[[ ! -s "$LOG" ]] || fail 'tampered receipt reached an Apple tool'

NONCANONICAL="$BASE/.notary-profile-bindings/noncanonical.json"
/usr/bin/python3 -I - "$VALID_RECEIPT" "$NONCANONICAL" <<'PY'
from pathlib import Path
import json
import os
import sys

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
descriptor = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    os.write(descriptor, (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
finally:
    os.close(descriptor)
PY
run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$NONCANONICAL" \
  --expected-receipt-sha256 "$(file_sha256 "$NONCANONICAL")"
expect_failure 'noncanonical receipt'

READABLE="$BASE/.notary-profile-bindings/readable.json"
/bin/cp "$VALID_RECEIPT" "$READABLE"
/bin/chmod 0644 "$READABLE"
run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$READABLE" \
  --expected-receipt-sha256 "$(file_sha256 "$READABLE")"
expect_failure 'group/world-readable receipt'

SYMLINK_RECEIPT="$BASE/.notary-profile-bindings/symlink.json"
/bin/ln -s valid.json "$SYMLINK_RECEIPT"
run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$SYMLINK_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
expect_failure 'symlink receipt'

HARDLINK_RECEIPT="$BASE/.notary-profile-bindings/hardlink.json"
/bin/ln "$VALID_RECEIPT" "$HARDLINK_RECEIPT"
run_script "$VERIFY" "$NOW" \
  --team-id "$TEAM_ID" --keychain-profile "$PROFILE" --receipt "$HARDLINK_RECEIPT" \
  --expected-receipt-sha256 "$VALID_DIGEST"
expect_failure 'hard-linked receipt'
/bin/rm "$HARDLINK_RECEIPT"

/usr/bin/grep -Fq 'XCRUN=/usr/bin/xcrun' "$REGISTER_SOURCE" || fail 'register production xcrun path was not absolute'
/usr/bin/grep -Fq 'SECURITY=/usr/bin/security' "$REGISTER_SOURCE" || fail 'register production security path was not absolute'
/usr/bin/grep -Fq 'OPENSSL=/usr/bin/openssl' "$REGISTER_SOURCE" || fail 'register production openssl path was not absolute'
/usr/bin/grep -Fq 'XCRUN=/usr/bin/xcrun' "$VERIFY_SOURCE" || fail 'verify production xcrun path was not absolute'
/usr/bin/grep -Fq 'SECURITY=/usr/bin/security' "$VERIFY_SOURCE" || fail 'verify production security path was not absolute'
/usr/bin/grep -Fq 'OPENSSL=/usr/bin/openssl' "$VERIFY_SOURCE" || fail 'verify production openssl path was not absolute'

printf 'notary profile tests passed\n'
