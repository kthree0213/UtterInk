#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CI_LOCAL="$ROOT/Scripts/ci-local.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-ci-matrix.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

write_local_spy() {
  local repository="$1"
  local relative_path="$2"
  mkdir -p "$(dirname "$repository/$relative_path")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "printf '%s\\t%s\\t%s\\n' 'local:$relative_path' \"\$*\" \"\${UTTERINK_NOTICE_SCRATCH_PATH:-}\" >> \"\${UTTERINK_MATRIX_LOG:?}\"" \
    > "$repository/$relative_path"
  chmod +x "$repository/$relative_path"
}

write_path_spy() {
  local bin="$1"
  local command="$2"
  if [[ "$command" == git ]]; then
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      "printf '%s\\t%s\\n' '$command' \"\$*\" >> \"\${UTTERINK_MATRIX_LOG:?}\"" \
      'if [[ "$*" == "rev-parse --verify HEAD" ]]; then' \
      "  printf '%s\\n' '0123456789abcdef0123456789abcdef01234567'" \
      'fi' \
      > "$bin/$command"
  else
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      "printf '%s\\t%s\\n' '$command' \"\$*\" >> \"\${UTTERINK_MATRIX_LOG:?}\"" \
      > "$bin/$command"
  fi
  chmod +x "$bin/$command"
}

new_repository() {
  local name="$1"
  local repository="$TMP/$name"
  local relative_path
  mkdir -p \
    "$repository/Scripts" \
    "$repository/Tests/Scripts" \
    "$repository/App/Supporting" \
    "$repository/Packages/UtterInkKit" \
    "$repository/bin"
  cp "$CI_LOCAL" "$repository/Scripts/ci-local.sh"
  chmod +x "$repository/Scripts/ci-local.sh"

  for relative_path in \
    Scripts/check-parity-replacement.sh \
    Scripts/check-repo-hygiene.sh \
    Scripts/collect-third-party-notices.sh \
    Scripts/package-unsigned-smoke.sh \
    Scripts/scan-public-history.sh \
    Scripts/verify-toolchain.sh \
    Tests/Scripts/test-generate-import-manifest.sh \
    Tests/Scripts/test-scan-public-history.sh \
    Tests/Scripts/test-import-legacy-parity.sh \
    Tests/Scripts/test-check-repo-hygiene.sh \
    Tests/Scripts/test-generate-legacy-defaults-map.sh \
    Tests/Scripts/test-check-parity-replacement.sh \
    Tests/Scripts/test-verify-candidate.sh \
    Tests/Scripts/test-build-candidate.sh \
    Tests/Scripts/test-sign-candidate.sh \
    Tests/Scripts/test-verify-signatures.sh \
    Tests/Scripts/test-register-notary-profile.sh \
    Tests/Scripts/test-notarize-approved.sh \
    Tests/Scripts/test-verify-final-dmg.sh \
    Tests/Scripts/test-create-source-archives.sh \
    Tests/Scripts/test-verify-release-assets.sh \
    Tests/Scripts/test-bootstrap-xcodegen.sh \
    Tests/Scripts/test-clean-distribution-output.sh \
    Tests/Scripts/test-package-unsigned-smoke.sh \
    Tests/Scripts/test-inspect-dmg.sh \
    Tests/Scripts/test-ats-policy.sh \
    Tests/Scripts/test-ui-testing-release-boundary.sh; do
    write_local_spy "$repository" "$relative_path"
  done

  for command in swift xcodegen xcodebuild python3 git; do
    write_path_spy "$repository/bin" "$command"
  done
  printf '%s\n' "$repository"
}

matching_count() {
  local log="$1"
  local command="$2"
  local fragment="$3"
  awk -F '\t' -v command="$command" -v fragment="$fragment" '
    $1 == command && (fragment == "" || index($2, fragment)) { count += 1 }
    END { print count + 0 }
  ' "$log"
}

assert_once() {
  local log="$1"
  local command="$2"
  local fragment="$3"
  local description="$4"
  local actual
  actual="$(matching_count "$log" "$command" "$fragment")"
  if [[ "$actual" -ne 1 ]]; then
    printf '%s executed %s times, expected exactly once\n' "$description" "$actual" >&2
    sed 's/^/  /' "$log" >&2
    exit 1
  fi
}

assert_twice() {
  local log="$1"
  local command="$2"
  local fragment="$3"
  local description="$4"
  local actual
  actual="$(matching_count "$log" "$command" "$fragment")"
  if [[ "$actual" -ne 2 ]]; then
    printf '%s executed %s times, expected exactly twice\n' "$description" "$actual" >&2
    sed 's/^/  /' "$log" >&2
    exit 1
  fi
}

assert_zero() {
  local log="$1"
  local command="$2"
  local fragment="$3"
  local description="$4"
  local actual
  actual="$(matching_count "$log" "$command" "$fragment")"
  if [[ "$actual" -ne 0 ]]; then
    printf '%s executed %s times, expected zero\n' "$description" "$actual" >&2
    sed 's/^/  /' "$log" >&2
    exit 1
  fi
}

first_matching_line() {
  local log="$1"
  local command="$2"
  local fragment="$3"
  awk -F '\t' -v command="$command" -v fragment="$fragment" '
    $1 == command && (fragment == "" || index($2, fragment)) { print NR; exit }
  ' "$log"
}

assert_after() {
  local log="$1"
  local earlier_command="$2"
  local earlier_fragment="$3"
  local later_command="$4"
  local later_fragment="$5"
  local description="$6"
  local earlier_line
  local later_line
  earlier_line="$(first_matching_line "$log" "$earlier_command" "$earlier_fragment")"
  later_line="$(first_matching_line "$log" "$later_command" "$later_fragment")"
  if [[ -z "$earlier_line" || -z "$later_line" || "$later_line" -le "$earlier_line" ]]; then
    printf '%s did not execute in the required order\n' "$description" >&2
    sed 's/^/  /' "$log" >&2
    exit 1
  fi
}

assert_required_gates() {
  local log="$1"
  local notice_scratch
  local repository="${log%/commands.log}"
  assert_zero "$log" swift 'test --package-path LegacyParity ' 'LegacyParity package tests'
  assert_once "$log" local:Tests/Scripts/test-generate-legacy-defaults-map.sh '' 'legacy defaults generator tests'
  assert_once "$log" local:Tests/Scripts/test-check-parity-replacement.sh '' 'parity replacement checker tests'
  assert_once "$log" python3 'Tests/Scripts/test-check-public-docs.py' 'public document validator tests'
  assert_once "$log" python3 'Tests/Scripts/test-release-metadata.py' 'release metadata tests'
  assert_once "$log" python3 'Tests/Scripts/test-release-entitlements.py' 'release entitlement tests'
  assert_once "$log" python3 'Tests/Scripts/test-release-info-policy.py' 'release Info policy tests'
  assert_once "$log" local:Tests/Scripts/test-verify-candidate.sh '' 'release candidate verifier tests'
  assert_once "$log" local:Tests/Scripts/test-build-candidate.sh '' 'release candidate builder tests'
  assert_once "$log" local:Tests/Scripts/test-sign-candidate.sh '' 'release candidate signing tests'
  assert_once "$log" local:Tests/Scripts/test-verify-signatures.sh '' 'release signature verifier tests'
  assert_once "$log" python3 'Tests/Scripts/test-notarization-gate.py' 'notarization approval gate tests'
  assert_once "$log" local:Tests/Scripts/test-register-notary-profile.sh '' 'notary profile binding tests'
  assert_once "$log" local:Tests/Scripts/test-notarize-approved.sh '' 'approved notarization wrapper tests'
  assert_once "$log" local:Tests/Scripts/test-verify-final-dmg.sh '' 'final DMG verifier tests'
  assert_once "$log" python3 'Tests/Scripts/test-collect-evidence.py' 'release evidence collector tests'
  assert_once "$log" local:Tests/Scripts/test-create-source-archives.sh '' 'deterministic source archive tests'
  assert_once "$log" local:Tests/Scripts/test-verify-release-assets.sh '' 'release asset verifier tests'
  assert_once "$log" python3 'Tests/Scripts/test-prepare-incomplete-evidence.py' 'incomplete release evidence tests'
  assert_once "$log" python3 'Tests/Scripts/test-verify-workflow.py' 'workflow policy tests'
  assert_once "$log" local:Tests/Scripts/test-bootstrap-xcodegen.sh '' 'locked XcodeGen bootstrap tests'
  assert_once "$log" local:Tests/Scripts/test-clean-distribution-output.sh '' 'distribution cleanup tests'
  assert_once "$log" local:Tests/Scripts/test-package-unsigned-smoke.sh '' 'unsigned packaging tests'
  assert_once "$log" local:Tests/Scripts/test-inspect-dmg.sh '' 'DMG inspection tests'
  assert_once "$log" python3 'Scripts/release/read-metadata.py --json' 'release metadata validator'
  assert_once "$log" python3 'Scripts/release/verify-entitlements.py' 'release entitlement validator'
  assert_once "$log" python3 'Scripts/release/verify-info-policy.py' 'release Info policy validator'
  assert_once "$log" python3 'Scripts/verify-workflow.py' 'workflow policy validator'
  assert_once "$log" swift 'Scripts/generate-legacy-defaults-map.swift --check ' 'legacy defaults generated-source check'
  assert_once "$log" local:Scripts/check-parity-replacement.sh '' 'parity replacement evidence checker'
  assert_once "$log" swift 'test --package-path Packages/UtterInkKit ' 'UtterInkKit package tests'
  assert_once "$log" python3 'Scripts/check-public-docs.py' 'public document validator'
  assert_once "$log" local:Scripts/collect-third-party-notices.sh '--check' 'third-party notice validator'
  assert_once "$log" swift 'UtterInkIdentityExporter --check --lock Brand/identity-lock.json --asset-catalog App/Resources/Assets.xcassets' 'identity lock validator'
  assert_twice "$log" local:Scripts/scan-public-history.sh '' 'public history scan'
  assert_once "$log" xcodebuild 'CODE_SIGNING_ALLOWED=NO test -only-testing:UtterInkAppTests' 'App unit tests'
  assert_once "$log" xcodebuild 'CODE_SIGNING_ALLOWED=NO test -only-testing:UtterInkUITests/' 'UI smoke tests'
  assert_once "$log" xcodebuild '-only-testing:UtterInkUITests/LaunchAndNavigationTests/testIdleScenarioShowsReadyStartActionAndSettingsRoutes' 'idle Settings UI smoke test'
  assert_once "$log" xcodebuild '-only-testing:UtterInkUITests/PipelineStateTests/testRecordingScenarioShowsStopAndCancelActions' 'recording UI smoke test'
  assert_once "$log" local:Tests/Scripts/test-ats-policy.sh '' 'signed ATS probe'
  assert_once "$log" local:Tests/Scripts/test-ui-testing-release-boundary.sh '' 'Release UI-test boundary'

  assert_after \
    "$log" \
    local:Tests/Scripts/test-verify-candidate.sh '' \
    local:Tests/Scripts/test-build-candidate.sh '' \
    'candidate builder tests after candidate verifier tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-build-candidate.sh '' \
    local:Tests/Scripts/test-sign-candidate.sh '' \
    'candidate signing tests after candidate builder tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-sign-candidate.sh '' \
    local:Tests/Scripts/test-verify-signatures.sh '' \
    'signature verifier tests after candidate signing tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-verify-signatures.sh '' \
    python3 'Tests/Scripts/test-notarization-gate.py' \
    'notarization gate tests after signature verifier tests'
  assert_after \
    "$log" \
    python3 'Tests/Scripts/test-notarization-gate.py' \
    local:Tests/Scripts/test-register-notary-profile.sh '' \
    'notary profile tests after notarization gate tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-register-notary-profile.sh '' \
    local:Tests/Scripts/test-notarize-approved.sh '' \
    'approved notarization tests after notary profile tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-notarize-approved.sh '' \
    local:Tests/Scripts/test-verify-final-dmg.sh '' \
    'final DMG tests after approved notarization tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-verify-final-dmg.sh '' \
    python3 'Tests/Scripts/test-collect-evidence.py' \
    'evidence collector tests after final DMG tests'
  assert_after \
    "$log" \
    python3 'Tests/Scripts/test-collect-evidence.py' \
    local:Tests/Scripts/test-create-source-archives.sh '' \
    'source archive tests after evidence collector tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-create-source-archives.sh '' \
    local:Tests/Scripts/test-verify-release-assets.sh '' \
    'release asset tests after source archive tests'
  assert_after \
    "$log" \
    local:Tests/Scripts/test-verify-release-assets.sh '' \
    python3 'Tests/Scripts/test-prepare-incomplete-evidence.py' \
    'incomplete evidence tests after release asset tests'
  assert_after \
    "$log" \
    python3 'Tests/Scripts/test-prepare-incomplete-evidence.py' \
    python3 'Tests/Scripts/test-verify-workflow.py' \
    'workflow tests after incomplete evidence tests'

  notice_scratch="$(awk -F '\t' '
    $1 == "local:Scripts/collect-third-party-notices.sh" { print $3 }
  ' "$log")"
  if [[ "$notice_scratch" != /* ]]; then
    printf 'third-party notice validator did not receive an absolute scratch path\n' >&2
    sed 's/^/  /' "$log" >&2
    exit 1
  fi
  case "$notice_scratch" in
    */UtterInkKit-build) ;;
    *)
      printf 'third-party notice validator did not receive the canonical UtterInkKit scratch path\n' >&2
      sed 's/^/  /' "$log" >&2
      exit 1
      ;;
  esac
  case "$notice_scratch" in
    "$repository"|"$repository"/*)
      printf 'third-party notice validator received a repository-local scratch path\n' >&2
      sed 's/^/  /' "$log" >&2
      exit 1
      ;;
  esac
  if ! awk -F '\t' -v scratch="$notice_scratch" '
      $1 == "swift" && index($2, "test --package-path Packages/UtterInkKit ") \
        && index($2, "--scratch-path " scratch) { found = 1 }
      END { exit !found }
    ' "$log"; then
    printf 'third-party notice validator did not reuse the UtterInkKit scratch path\n' >&2
    sed 's/^/  /' "$log" >&2
    exit 1
  fi

  assert_after \
    "$log" \
    xcodebuild '-resolvePackageDependencies' \
    python3 'Scripts/check-package-resolution.py' \
    'package lock validation after Xcode package resolution'
  assert_after \
    "$log" \
    python3 'Scripts/check-package-resolution.py' \
    python3 'Scripts/check-public-docs.py' \
    'public document validation after package lock validation'
  assert_after \
    "$log" \
    python3 'Scripts/check-package-resolution.py' \
    local:Scripts/collect-third-party-notices.sh '--check' \
    'third-party notice validation after package lock validation'
  assert_after \
    "$log" \
    python3 'Scripts/check-package-resolution.py' \
    swift 'UtterInkIdentityExporter --check --lock Brand/identity-lock.json' \
    'identity lock validation after package lock validation'

  if grep -F $'xcodebuild\t' "$log" \
      | grep -F -- '-only-testing:' \
      | grep -Fv -- '-parallel-testing-enabled NO' >/dev/null; then
    printf 'an App/UI test invocation enabled or omitted serialized execution\n' >&2
    exit 1
  fi
}

run_case() {
  local name="$1"
  shift
  local repository
  local log
  repository="$(new_repository "$name")"
  log="$repository/commands.log"
  : > "$log"
  (
    cd "$repository"
    env \
      PATH="$repository/bin:/usr/bin:/bin" \
      UTTERINK_MATRIX_LOG="$log" \
      "$@" \
      ./Scripts/ci-local.sh \
      >"$repository/ci.stdout" \
      2>"$repository/ci.stderr"
  )
  assert_required_gates "$log"
  printf '%s\n' "$repository"
}

default_repository="$(run_case default)"
default_log="$default_repository/commands.log"
if grep -F $'local:Scripts/scan-public-history.sh\t--expected-origin' "$default_log" >/dev/null; then
  printf 'default local run unexpectedly invented an origin\n' >&2
  exit 1
fi

explicit_repository="$(run_case explicit-origin UTTERINK_EXPECTED_ORIGIN=https://example.invalid/owner/repo.git)"
explicit_log="$explicit_repository/commands.log"
if [[ "$(matching_count "$explicit_log" local:Scripts/scan-public-history.sh '--expected-origin https://example.invalid/owner/repo.git')" -ne 2 ]]; then
  printf 'explicit local origin was not propagated to both history scans\n' >&2
  exit 1
fi

github_repository="$(run_case github-origin GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/repo)"
github_log="$github_repository/commands.log"
if grep -F $'local:Scripts/scan-public-history.sh\t--expected-origin' "$github_log" >/dev/null; then
  printf 'local mode inferred an origin from ambient GitHub variables\n' >&2
  exit 1
fi

ci_repository="$(new_repository ci-mode)"
ci_log="$ci_repository/commands.log"
: > "$ci_log"
write_local_spy "$ci_repository" Tools/bin/xcodegen
(
  cd "$ci_repository"
  PATH="$ci_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$ci_log" \
  GITHUB_SERVER_URL=https://github.example \
  GITHUB_REPOSITORY=owner/repo \
    ./Scripts/ci-local.sh --ci \
    >"$ci_repository/ci.stdout" \
    2>"$ci_repository/ci.stderr"
)
assert_required_gates "$ci_log"
assert_once "$ci_log" local:Scripts/verify-toolchain.sh '--context ci' 'locked CI toolchain verification'
assert_once "$ci_log" local:Tools/bin/xcodegen 'generate' 'repository-local XcodeGen'
assert_zero "$ci_log" xcodegen '' 'ordinary PATH XcodeGen in CI mode'
if [[ "$(matching_count "$ci_log" local:Scripts/scan-public-history.sh '--expected-origin https://github.example/owner/repo.git')" -ne 2 ]]; then
  printf 'CI mode did not propagate its derived origin to both history scans\n' >&2
  exit 1
fi

local_package_repository="$(new_repository local-unsigned-package)"
local_package_log="$local_package_repository/commands.log"
: > "$local_package_log"
write_local_spy "$local_package_repository" Tools/bin/xcodegen
(
  cd "$local_package_repository"
  PATH="$local_package_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$local_package_log" \
  UTTERINK_EXPECTED_ORIGIN=https://example.invalid/owner/repo.git \
    ./Scripts/ci-local.sh --unsigned-package-smoke \
    >"$local_package_repository/ci.stdout" \
    2>"$local_package_repository/ci.stderr"
)
assert_required_gates "$local_package_log"
assert_once "$local_package_log" local:Scripts/verify-toolchain.sh '--context local' 'locked local toolchain verification'
assert_once "$local_package_log" local:Tools/bin/xcodegen 'generate' 'repository-local XcodeGen in local packaging mode'
assert_zero "$local_package_log" xcodegen '' 'ordinary PATH XcodeGen in local packaging mode'
assert_once \
  "$local_package_log" \
  local:Scripts/package-unsigned-smoke.sh \
  '--commit 0123456789abcdef0123456789abcdef01234567 --output dist/unsigned-smoke --expected-origin https://example.invalid/owner/repo.git' \
  'local unsigned package smoke'
if [[ "$(matching_count "$local_package_log" local:Scripts/scan-public-history.sh '--expected-origin https://example.invalid/owner/repo.git')" -ne 2 ]]; then
  printf 'local packaging mode did not propagate its explicit origin to both history scans\n' >&2
  exit 1
fi

ci_package_repository="$(new_repository ci-unsigned-package)"
ci_package_log="$ci_package_repository/commands.log"
: > "$ci_package_log"
write_local_spy "$ci_package_repository" Tools/bin/xcodegen
(
  cd "$ci_package_repository"
  PATH="$ci_package_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$ci_package_log" \
  GITHUB_SERVER_URL=https://github.example \
  GITHUB_REPOSITORY=owner/repo \
  UTTERINK_EXPECTED_ORIGIN=https://must-not-be-used.invalid/other.git \
    ./Scripts/ci-local.sh --ci --unsigned-package-smoke \
    >"$ci_package_repository/ci.stdout" \
    2>"$ci_package_repository/ci.stderr"
)
assert_required_gates "$ci_package_log"
assert_once "$ci_package_log" local:Scripts/verify-toolchain.sh '--context ci' 'locked CI package toolchain verification'
assert_once \
  "$ci_package_log" \
  local:Scripts/package-unsigned-smoke.sh \
  '--commit 0123456789abcdef0123456789abcdef01234567 --output dist/unsigned-smoke --expected-origin https://github.example/owner/repo.git' \
  'CI unsigned package smoke'
assert_zero \
  "$ci_package_log" \
  local:Scripts/package-unsigned-smoke.sh \
  'must-not-be-used.invalid' \
  'ambient local origin in CI package mode'
if [[ "$(matching_count "$ci_package_log" local:Scripts/scan-public-history.sh '--expected-origin https://github.example/owner/repo.git')" -ne 2 ]]; then
  printf 'CI packaging mode did not propagate its derived origin to both history scans\n' >&2
  exit 1
fi

missing_ci_origin_repository="$(new_repository ci-mode-missing-origin)"
missing_ci_origin_log="$missing_ci_origin_repository/commands.log"
: > "$missing_ci_origin_log"
if (
  cd "$missing_ci_origin_repository"
  PATH="$missing_ci_origin_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$missing_ci_origin_log" \
    ./Scripts/ci-local.sh --ci \
    >"$missing_ci_origin_repository/ci.stdout" \
    2>"$missing_ci_origin_repository/ci.stderr"
); then
  printf 'CI mode accepted missing repository-origin variables\n' >&2
  exit 1
fi
if [[ -s "$missing_ci_origin_log" ]]; then
  printf 'CI mode executed commands before rejecting missing origin variables\n' >&2
  exit 1
fi
if ! grep -F 'CI mode requires GITHUB_SERVER_URL and GITHUB_REPOSITORY' \
    "$missing_ci_origin_repository/ci.stderr" >/dev/null; then
  printf 'missing CI origin failure did not explain the required variables\n' >&2
  exit 1
fi

missing_locked_repository="$(new_repository ci-mode-missing-locked-xcodegen)"
missing_locked_log="$missing_locked_repository/commands.log"
: > "$missing_locked_log"
if (
  cd "$missing_locked_repository"
  PATH="$missing_locked_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$missing_locked_log" \
  GITHUB_SERVER_URL=https://github.example \
  GITHUB_REPOSITORY=owner/repo \
    ./Scripts/ci-local.sh --ci \
    >"$missing_locked_repository/ci.stdout" \
    2>"$missing_locked_repository/ci.stderr"
); then
  printf 'CI mode accepted a missing locked XcodeGen binary\n' >&2
  exit 1
fi
if [[ -s "$missing_locked_log" ]]; then
  printf 'CI mode consulted commands before rejecting missing locked XcodeGen\n' >&2
  exit 1
fi
if ! grep -F 'locked XcodeGen is unavailable; run ./Scripts/bootstrap-xcodegen.sh first' \
    "$missing_locked_repository/ci.stderr" >/dev/null; then
  printf 'missing locked XcodeGen failure did not explain bootstrap recovery\n' >&2
  exit 1
fi

duplicate_repository="$(new_repository duplicate-ci-argument)"
duplicate_log="$duplicate_repository/commands.log"
: > "$duplicate_log"
if (
  cd "$duplicate_repository"
  PATH="$duplicate_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$duplicate_log" \
    ./Scripts/ci-local.sh --ci --ci \
    >"$duplicate_repository/ci.stdout" \
    2>"$duplicate_repository/ci.stderr"
); then
  printf 'duplicate ci-local argument was accepted\n' >&2
  exit 1
fi
if [[ -s "$duplicate_log" ]]; then
  printf 'duplicate CI argument executed commands before failing\n' >&2
  exit 1
fi
if ! grep -F 'duplicate ci-local argument: --ci' "$duplicate_repository/ci.stderr" >/dev/null; then
  printf 'duplicate CI argument failure did not explain the rejected argument\n' >&2
  exit 1
fi

duplicate_package_repository="$(new_repository duplicate-package-argument)"
duplicate_package_log="$duplicate_package_repository/commands.log"
: > "$duplicate_package_log"
if (
  cd "$duplicate_package_repository"
  PATH="$duplicate_package_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$duplicate_package_log" \
    ./Scripts/ci-local.sh --unsigned-package-smoke --unsigned-package-smoke \
    >"$duplicate_package_repository/ci.stdout" \
    2>"$duplicate_package_repository/ci.stderr"
); then
  printf 'duplicate unsigned-package argument was accepted\n' >&2
  exit 1
fi
if [[ -s "$duplicate_package_log" ]]; then
  printf 'duplicate unsigned-package argument executed commands before failing\n' >&2
  exit 1
fi
if ! grep -F 'duplicate ci-local argument: --unsigned-package-smoke' \
    "$duplicate_package_repository/ci.stderr" >/dev/null; then
  printf 'duplicate unsigned-package failure did not explain the rejected argument\n' >&2
  exit 1
fi

unknown_repository="$(new_repository unknown-argument)"
unknown_log="$unknown_repository/commands.log"
: > "$unknown_log"
if (
  cd "$unknown_repository"
  PATH="$unknown_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$unknown_log" \
    ./Scripts/ci-local.sh --skip-ui \
    >"$unknown_repository/ci.stdout" \
    2>"$unknown_repository/ci.stderr"
); then
  printf 'unknown ci-local argument was accepted\n' >&2
  exit 1
fi
if [[ -s "$unknown_log" ]]; then
  printf 'unknown argument executed CI commands before failing\n' >&2
  exit 1
fi
if ! grep -F 'unknown ci-local argument: --skip-ui' "$unknown_repository/ci.stderr" >/dev/null; then
  printf 'unknown argument failure did not explain the rejected argument\n' >&2
  exit 1
fi

legacy_repository="$(new_repository retired-snapshot-reintroduced)"
legacy_log="$legacy_repository/commands.log"
: > "$legacy_log"
mkdir -p "$legacy_repository/LegacyParity"
if (
  cd "$legacy_repository"
  PATH="$legacy_repository/bin:/usr/bin:/bin" \
  UTTERINK_MATRIX_LOG="$legacy_log" \
    ./Scripts/ci-local.sh \
    >"$legacy_repository/ci.stdout" \
    2>"$legacy_repository/ci.stderr"
); then
  printf 'reintroduced LegacyParity snapshot was accepted\n' >&2
  exit 1
fi
if [[ -s "$legacy_log" ]]; then
  printf 'reintroduced LegacyParity snapshot executed CI commands before failing\n' >&2
  exit 1
fi
if ! grep -F 'retired LegacyParity snapshot must remain absent' "$legacy_repository/ci.stderr" >/dev/null; then
  printf 'reintroduced LegacyParity failure did not explain the retired boundary\n' >&2
  exit 1
fi

printf 'ci-local command matrix passed\n'
