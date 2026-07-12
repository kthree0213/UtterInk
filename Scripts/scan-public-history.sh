#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ORIGIN=''
if [[ "$#" -eq 0 ]]; then
  :
elif [[ "$#" -eq 2 && "$1" == '--expected-origin' && -n "$2" ]]; then
  EXPECTED_ORIGIN="$2"
else
  printf 'finding category=invalid-arguments file=arguments\n' >&2
  exit 2
fi

for unsafe_name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE GIT_GRAFT_FILE; do
  if [[ -n "${!unsafe_name-}" ]]; then
    printf 'finding category=unsafe-git-environment file=environment\n' >&2
    exit 1
  fi
done

export GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export LC_ALL=C

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'finding category=not-a-repository file=.git\n' >&2
  exit 1
}
cd "$TOP"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/utterink-history-scan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FINDINGS="$TMP/findings"
: > "$FINDINGS"
MAX_SCAN_BYTES=1048576

safe_file_id() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z0-9._:@/+,-]+$ ]]; then
    printf '%s' "$value"
  else
    printf 'path-%s' "$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}')"
  fi
}

emit_file() {
  local category="$1"
  local identifier
  identifier="$(safe_file_id "$2")"
  local line="finding category=$category file=$identifier"
  if ! grep -Fqx -- "$line" "$FINDINGS"; then
    printf '%s\n' "$line" >> "$FINDINGS"
    printf '%s\n' "$line" >&2
  fi
}

emit_object() {
  local category="$1"
  local object="$2"
  case "$object" in
    *[!0-9a-f]*|'') object=unknown ;;
  esac
  local line="finding category=$category object=$object"
  if ! grep -Fqx -- "$line" "$FINDINGS"; then
    printf '%s\n' "$line" >> "$FINDINGS"
    printf '%s\n' "$line" >&2
  fi
}

check_private_path() {
  local path="$1"
  case "$path" in
    .env.example|*/.env.example) return ;;
    .env|*/.env|.env.*|*/.env.*|secrets|secrets/*|*/secrets|*/secrets/*|Models|Models/*|*/Models|*/Models/*|\
    .DS_Store|*/.DS_Store|.build|.build/*|*/.build|*/.build/*|.swiftpm|.swiftpm/*|*/.swiftpm|*/.swiftpm/*|\
    DerivedData|DerivedData/*|*/DerivedData|*/DerivedData/*|dist|dist/*|*/dist|*/dist/*|\
    *.pem|*.p12|*.cer|*.mobileprovision|*.dmg|*.xcarchive|*.xcresult|*.caf|*.wav)
      emit_file private-path "$path"
      ;;
  esac
}

match_category() {
  local sample="$1"
  local category="$2"
  local regex="$3"
  local kind="$4"
  local identifier="$5"
  local status
  if grep -aEq -- "$regex" "$sample" 2>/dev/null; then
    if [[ "$kind" == object ]]; then
      emit_object "$category" "$identifier"
    else
      emit_file "$category" "$identifier"
    fi
  else
    status=$?
    if [[ "$status" -gt 1 ]]; then
      if [[ "$kind" == object ]]; then
        emit_object unscannable-content "$identifier"
      else
        emit_file unscannable-content "$identifier"
      fi
    fi
  fi
}

classify_sample() {
  local sample="$1"
  local kind="$2"
  local identifier="$3"
  local users_prefix='/Users'
  local home_prefix='/home'
  local personal_pattern="(${users_prefix}/[^/[:space:]]+/[^[:space:]]+|${home_prefix}/[^/[:space:]]+/[^[:space:]]+|[A-Za-z]:\\\\Users\\\\[^\\\\[:space:]]+\\\\[^[:space:]]+)"
  local approved_credential_url credential_sample
  approved_credential_url="$(printf '%s%s' 'https://user:' 'pass@example.com/v1')"
  credential_sample="$TMP/credential-sample"

  match_category "$sample" private-key '-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----' "$kind" "$identifier"
  match_category "$sample" common-token '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk_(live|test)_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{30,})' "$kind" "$identifier"
  match_category "$sample" provider-credential '(sk-or-v1-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gsk_[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9_-]{20,})' "$kind" "$identifier"
  match_category "$sample" transcript-canary '(TRANSCRIPT[_ -]?CANARY|PRIVATE[_ -]?TRANSCRIPT)[_ :=-]*[A-Za-z0-9_-]{8,}' "$kind" "$identifier"
  match_category "$sample" personal-path "$personal_pattern" "$kind" "$identifier"
  if APPROVED_CREDENTIAL_URL="$approved_credential_url" perl -0777 -pe '
      BEGIN { binmode STDIN; binmode STDOUT; $placeholder = quotemeta($ENV{"APPROVED_CREDENTIAL_URL"}) }
      s/(?<![A-Za-z0-9])$placeholder(?![-A-Za-z0-9._~:\/?#\[\]\@!\$&()*+,;=%])/[approved-credential-url-placeholder]/g
    ' "$sample" > "$credential_sample" 2>/dev/null; then
    match_category "$credential_sample" common-token 'https?://[^/:[:space:]@]+:[^/@[:space:]]+@' "$kind" "$identifier"
  elif [[ "$kind" == object ]]; then
    emit_object unscannable-content "$identifier"
  else
    emit_file unscannable-content "$identifier"
  fi
}

sample_is_binary() {
  perl -e 'open my $fh, "<", $ARGV[0] or exit 2; binmode $fh; read($fh, my $data, 8192); exit(index($data, "\0") >= 0 ? 0 : 1)' "$1"
}

is_known_text_path() {
  case "$1" in
    *.swift|*.md|*.sh|*.json|*.plist|*.txt|*.tsv|*.csv|*.yaml|*.yml|*.toml|*.xml|*.html|*.css|*.js|*.ts|*.gitignore|*.gitattributes|Package.resolved|Package.swift)
      return 0 ;;
    *) return 1 ;;
  esac
}

scan_file_content() {
  local path="$1"
  local display="$2"
  local size sample status
  if [[ -L "$path" ]]; then
    emit_file unscannable-file "$display"
    return
  fi
  [[ -f "$path" ]] || return
  size="$(wc -c < "$path" 2>/dev/null)" || {
    emit_file unscannable-file "$display"
    return
  }
  sample="$TMP/file-sample"
  if ! head -c "$MAX_SCAN_BYTES" -- "$path" > "$sample" 2>/dev/null; then
    emit_file unscannable-file "$display"
    return
  fi
  classify_sample "$sample" file "$display"
  if [[ "$size" -gt "$MAX_SCAN_BYTES" ]]; then
    if is_known_text_path "$display"; then
      emit_file unscannable-text "$display"
    elif sample_is_binary "$sample"; then
      :
    else
      status=$?
      if [[ "$status" -eq 1 ]]; then
        emit_file unscannable-text "$display"
      else
        emit_file unscannable-file "$display"
      fi
    fi
  fi
}

is_credential_free_url() {
  local url="$1"
  local rest authority userinfo
  case "$url" in
    *[[:space:]]*|*\?*|*\#*) return 1 ;;
    https://*)
      rest="${url#https://}"
      authority="${rest%%/*}"
      [[ -n "$authority" && "$authority" != *'@'* && "$rest" == */* ]]
      ;;
    ssh://*)
      rest="${url#ssh://}"
      authority="${rest%%/*}"
      [[ -n "$authority" && "$rest" == */* ]] || return 1
      if [[ "$authority" == *'@'* ]]; then
        userinfo="${authority%%@*}"
        [[ "$userinfo" == git ]]
      fi
      ;;
    git@*:* ) [[ "$url" != *'@'*'@'* ]] ;;
    *) return 1 ;;
  esac
}

# Reject structural inputs that can hide or replace repository history.
git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || git_dir=.git
common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || common_dir="$git_dir"
case "$common_dir" in
  /*) ;;
  *) common_dir="$(cd "$common_dir" 2>/dev/null && pwd -P)" || common_dir=unknown ;;
esac
if printf '%s\n%s\n' "$git_dir" "$common_dir" | grep -Eqi '(^|[/._-])flowtype([/._-]|$)'; then
  emit_file legacy-git-link .git
fi

alternates_path="$(git rev-parse --git-path objects/info/alternates 2>/dev/null || true)"
http_alternates_path="$(git rev-parse --git-path objects/info/http-alternates 2>/dev/null || true)"
grafts_path="$(git rev-parse --git-path info/grafts 2>/dev/null || true)"
[[ -n "$alternates_path" && -s "$alternates_path" ]] && emit_file git-alternates .git/objects/info/alternates
[[ -n "$http_alternates_path" && -s "$http_alternates_path" ]] && emit_file git-alternates .git/objects/info/http-alternates
[[ -n "$grafts_path" && -s "$grafts_path" ]] && emit_file git-grafts .git/info/grafts

refs_file="$TMP/refs"
if git for-each-ref --format='%(refname)' > "$refs_file" 2>/dev/null; then
  while IFS= read -r ref || [[ -n "$ref" ]]; do
    case "$ref" in refs/replace/*) emit_file git-replace refs/replace ;;
    esac
    if printf '%s' "$ref" | grep -Eqi '(^|[/._-])(flowtype|legacy)([/._-]|$)'; then
      emit_file legacy-ref "$ref"
    fi
  done < "$refs_file"
else
  emit_file unscannable-git-metadata .git/refs
fi

if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || printf true)" != false ]]; then
  emit_file incomplete-history .git/shallow
fi
if git config --local --get extensions.partialclone >/dev/null 2>&1 ||
   git config --local --get-regexp '^remote\..*\.promisor$' >/dev/null 2>&1; then
  emit_file incomplete-history .git/config
fi

remotes_file="$TMP/remotes"
git remote > "$remotes_file" 2>/dev/null || emit_file unscannable-git-metadata .git/config
remote_count="$(awk 'END { print NR + 0 }' "$remotes_file")"
if [[ -z "$EXPECTED_ORIGIN" ]]; then
  [[ "$remote_count" -eq 0 ]] || emit_file unauthorized-remote .git/config
else
  if ! is_credential_free_url "$EXPECTED_ORIGIN"; then
    emit_file unauthorized-remote .git/config
  fi
  if [[ "$remote_count" -ne 1 || "$(sed -n '1p' "$remotes_file")" != origin ]]; then
    emit_file unauthorized-remote .git/config
  fi
  origin_urls="$TMP/origin-urls"
  git config --local --get-all remote.origin.url > "$origin_urls" 2>/dev/null || :
  if [[ "$(awk 'END { print NR + 0 }' "$origin_urls")" -ne 1 || "$(sed -n '1p' "$origin_urls")" != "$EXPECTED_ORIGIN" ]]; then
    emit_file unauthorized-remote .git/config
  fi
  if git config --local --get-all remote.origin.pushurl >/dev/null 2>&1; then
    emit_file unauthorized-remote .git/config
  fi
fi

while IFS= read -r remote || [[ -n "$remote" ]]; do
  [[ -n "$remote" ]] || continue
  urls="$TMP/remote-urls"
  git config --local --get-all "remote.$remote.url" > "$urls" 2>/dev/null || :
  while IFS= read -r url || [[ -n "$url" ]]; do
    if printf '%s' "$remote/$url" | grep -Eqi '(^|[/._-])flowtype([/._-]|$)'; then
      emit_file legacy-git-link .git/config
    fi
  done < "$urls"
done < "$remotes_file"

if git config --local --get-regexp '^(url\..*\.(insteadOf|pushInsteadOf)|http\..*\.extraHeader|remote\..*\.(uploadpack|receivepack))$' >/dev/null 2>&1; then
  emit_file unauthorized-remote .git/config
fi

# Check every worktree path, including ignored paths, then scan tracked and
# ordinary untracked file contents without entering Git administration.
all_worktree_paths="$TMP/all-worktree-paths"
if find . -mindepth 1 \( -path './.git' -o -path './.git/*' \) -prune -o \( -type f -o -type l \) -print0 > "$all_worktree_paths" 2>/dev/null; then
  while IFS= read -r -d '' raw_path; do
    path="${raw_path#./}"
    check_private_path "$path"
  done < "$all_worktree_paths"
else
  emit_file unscannable-worktree .
fi

worktree_files="$TMP/worktree-files"
if git ls-files -z --cached --others --exclude-standard > "$worktree_files" 2>/dev/null; then
  while IFS= read -r -d '' path; do
    check_private_path "$path"
    scan_file_content "$path" "$path"
  done < "$worktree_files"
else
  emit_file unscannable-index .git/index
fi

# Check index paths explicitly. Index blob contents are covered again by the
# complete object database traversal below.
index_entries="$TMP/index-entries"
if git ls-files --stage -z > "$index_entries" 2>/dev/null; then
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    check_private_path "$path"
    [[ "$mode" != 160000 ]] || emit_file legacy-git-link "$path"
  done < "$index_entries"
else
  emit_file unscannable-index .git/index
fi

# The current public manifest is trusted only when tracked and unchanged from
# HEAD through index and worktree.
MANIFEST=docs/provenance/legacy-source-import.tsv
MANIFEST_MAP="$TMP/manifest-map"
: > "$MANIFEST_MAP"
manifest_valid=0
if [[ -e "$MANIFEST" ]] || git ls-files --error-unmatch -- "$MANIFEST" >/dev/null 2>&1; then
  manifest_valid=1
  if [[ ! -f "$MANIFEST" || -L "$MANIFEST" ]] ||
     ! git ls-files --error-unmatch -- "$MANIFEST" >/dev/null 2>&1 ||
     ! git cat-file -e "HEAD:$MANIFEST" 2>/dev/null ||
     ! git diff --quiet -- "$MANIFEST" ||
     ! git diff --cached --quiet -- "$MANIFEST"; then
    manifest_valid=0
  fi
  if [[ "$manifest_valid" -eq 1 ]]; then
    if ! awk -F '\t' '
      NR == 1 {
        expected = "source_path\tdestination_path\tsha256\tpurpose\tcopyright_owner\tlicense_or_authority\treviewer"
        if ($0 != expected) bad = 1
        next
      }
      {
        owner = tolower($5); authority = tolower($6); reviewer = tolower($7)
        if (NF != 7 || $1 == "" || $2 !~ /^LegacyParity\// || length($3) != 64 || $3 !~ /^[0-9a-f]+$/ || $4 == "" ||
            $5 == "" || $6 !~ /Apache-2.0/ || $7 == "" || owner ~ /^(unknown|tbd|todo|placeholder)$/ ||
            reviewer ~ /^(unknown|tbd|todo|placeholder)$/ || authority ~ /(unknown|tbd|todo|placeholder)/ ||
            $1 ~ /^\// || $2 ~ /^\// || $1 ~ /(^|\/)\.\.($|\/)/ || $2 ~ /(^|\/)\.\.($|\/)/ ||
            seen_source[$1]++ || seen_destination[$2]++) bad = 1
        print $2 "\t" $3
      }
      END { if (NR < 2 || bad) exit 1 }
    ' "$MANIFEST" > "$MANIFEST_MAP"; then
      manifest_valid=0
    fi
  fi
  [[ "$manifest_valid" -eq 1 ]] || emit_file provenance-manifest "$MANIFEST"
fi

# Enumerate every loose and packed object, including unreachable objects.
objects_file="$TMP/objects"
if ! git cat-file --batch-all-objects --batch-check=$'%(objectname)\t%(objecttype)\t%(objectsize)' > "$objects_file" 2>/dev/null; then
  emit_file object-integrity .git/objects
  : > "$objects_file"
fi

commits_file="$TMP/commits"
: > "$commits_file"
trees_file="$TMP/trees"
: > "$trees_file"
while IFS=$'\t' read -r oid type size || [[ -n "${oid-}" ]]; do
  [[ -n "${oid-}" ]] || continue
  if [[ ! "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ || ! "$size" =~ ^[0-9]+$ ]]; then
    emit_file object-integrity .git/objects
    continue
  fi
  case "$type" in
    blob|commit|tag)
      sample="$TMP/object-sample"
      set +o pipefail
      git cat-file "$type" "$oid" 2>/dev/null | head -c "$MAX_SCAN_BYTES" > "$sample" 2>/dev/null
      statuses=("${PIPESTATUS[@]}")
      set -o pipefail
      if [[ "${statuses[1]}" -ne 0 || ( "${statuses[0]}" -ne 0 && "${statuses[0]}" -ne 141 ) ]]; then
        emit_object unscannable-object "$oid"
        continue
      fi
      classify_sample "$sample" object "$oid"
      if [[ "$size" -gt "$MAX_SCAN_BYTES" ]]; then
        if [[ "$type" != blob ]]; then
          emit_object unscannable-text "$oid"
        elif sample_is_binary "$sample"; then
          :
        else
          binary_status=$?
          if [[ "$binary_status" -eq 1 ]]; then
            emit_object unscannable-text "$oid"
          else
            emit_object unscannable-object "$oid"
          fi
        fi
      fi
      if [[ "$type" == commit ]]; then
        printf '%s\n' "$oid" >> "$commits_file"
      fi
      ;;
    tree) printf '%s\n' "$oid" >> "$trees_file" ;;
    *) emit_object unscannable-object "$oid" ;;
  esac
done < "$objects_file"

root_count=0
while IFS= read -r commit_oid || [[ -n "$commit_oid" ]]; do
  sample="$TMP/commit-header"
  set +o pipefail
  git cat-file commit "$commit_oid" 2>/dev/null | head -c "$MAX_SCAN_BYTES" > "$sample" 2>/dev/null
  statuses=("${PIPESTATUS[@]}")
  set -o pipefail
  if [[ "${statuses[1]}" -ne 0 || ( "${statuses[0]}" -ne 0 && "${statuses[0]}" -ne 141 ) ]]; then
    emit_object unscannable-object "$commit_oid"
    continue
  fi
  parent_count="$(awk '/^$/ { exit } /^parent [0-9a-f]+$/ { count++ } END { print count + 0 }' "$sample")"
  [[ "$parent_count" -ne 0 ]] || root_count=$((root_count + 1))
done < "$commits_file"
[[ "$root_count" -eq 1 ]] || emit_file history-root-count .git/objects

if ! git fsck --full --no-reflogs --unreachable >/dev/null 2> "$TMP/fsck-errors"; then
  emit_file object-integrity .git/objects
fi

# Parse every unique tree object recursively, including loose/packed unreachable
# trees and trees targeted only by tags. Commit-rooted trees are part of the same
# complete object inventory.
unique_trees_file="$TMP/unique-trees"
sort -u "$trees_file" > "$unique_trees_file"
while IFS= read -r tree_oid || [[ -n "$tree_oid" ]]; do
  [[ -n "$tree_oid" ]] || continue
  tree_entries="$TMP/tree-entries"
  if ! git ls-tree -rz "$tree_oid" > "$tree_entries" 2>/dev/null; then
    emit_object unscannable-object "$tree_oid"
    continue
  fi
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    remainder="${metadata#* }"
    type="${remainder%% *}"
    blob_oid="${remainder##* }"
    check_private_path "$path"
    case "$path" in
      LegacyParity/*)
        if [[ "$manifest_valid" -ne 1 || "$type" != blob || ( "$mode" != 100644 && "$mode" != 100755 ) ]]; then
          emit_object legacy-provenance "$tree_oid"
          continue
        fi
        expected_hash="$(awk -F '\t' -v path="$path" '$1 == path { print $2 }' "$MANIFEST_MAP")"
        if [[ -z "$expected_hash" ]]; then
          emit_object legacy-provenance "$tree_oid"
          continue
        fi
        if ! actual_hash="$(git cat-file blob "$blob_oid" 2>/dev/null | shasum -a 256 | awk '{print $1}')"; then
          emit_object unscannable-object "$blob_oid"
          continue
        fi
        [[ "$actual_hash" == "$expected_hash" ]] || emit_object legacy-provenance "$tree_oid"
        ;;
    esac
  done < "$tree_entries"
done < "$unique_trees_file"

if [[ -s "$FINDINGS" ]]; then
  exit 1
fi

printf 'public history scan passed\n'
