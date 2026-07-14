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
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "printf '%s\\t%s\\n' '$command' \"\$*\" >> \"\${UTTERINK_MATRIX_LOG:?}\"" \
    > "$bin/$command"
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
    Scripts/scan-public-history.sh \
    Tests/Scripts/test-generate-import-manifest.sh \
    Tests/Scripts/test-scan-public-history.sh \
    Tests/Scripts/test-import-legacy-parity.sh \
    Tests/Scripts/test-check-repo-hygiene.sh \
    Tests/Scripts/test-generate-legacy-defaults-map.sh \
    Tests/Scripts/test-check-parity-replacement.sh \
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
if [[ "$(matching_count "$github_log" local:Scripts/scan-public-history.sh '--expected-origin https://github.example/owner/repo.git')" -ne 2 ]]; then
  printf 'GitHub origin was not propagated to both history scans\n' >&2
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
