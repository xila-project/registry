#!/usr/bin/env bash
# Test the registry validation rules against fixtures generated on the fly.
#
# usage: tools/test.sh
# Every key is generated here with `xila-package key generate` and discarded;
# nothing in this script is a real key. The fixtures are a signed Wasm package
# and a signed native package in the reverse-DNS namespace `example.test`, and a
# signed Wasm package with a legacy `xila.<name>` identifier, all from a
# throwaway test developer; each case breaks one rule and expects the
# validation to refuse it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$(bash "$root/tools/xila-package.sh")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
expect_success() {
  local name="$1"; shift
  if "$@" >"$work/output" 2>&1; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s: expected success\n' "$name"; sed 's/^/        /' "$work/output"; failures=$((failures + 1))
  fi
}
expect_failure() {
  local name="$1" pattern="$2"; shift 2
  if "$@" >"$work/output" 2>&1; then
    printf 'FAIL  %s: expected a refusal\n' "$name"; failures=$((failures + 1))
  elif grep -q -- "$pattern" "$work/output"; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s: refused without "%s"\n' "$name" "$pattern"; sed 's/^/        /' "$work/output"; failures=$((failures + 1))
  fi
}

# ---- Fixtures: a signed Wasm package and a signed native package ------------

"$builder" key generate "$work/developer.seed" "$work/developer.pub" >/dev/null
public_key="$(base64 -w0 "$work/developer.pub")"

package() { # <identifier> <target> <entrypoint>
  local source="$work/source-$1"
  "$builder" bundle init "$source" "$1" 1.0.0 "$2" --xila-version 0.1 --standalone >/dev/null
  printf 'test payload %s' "$1" > "$source/$3"
  "$builder" bundle build "$source" "$work/$1.app" --signing-key "$work/developer.seed" >/dev/null
  mkdir -p "$work/archives"
  "$builder" bundle archive "$work/$1.app" "$work/archives/$1-1.0.0-$2.xpk" >/dev/null
}
package example.test.wasm wasm32-wasip1 executables/main.wasm
package example.test.native thumbv7em-none-eabi executables/main.bin
package xila.test wasm32-wasip1 executables/main.wasm

registry="$work/registry"
archives="$work/archives"
key_file="$registry/keys/developers/test-developer.json"
namespace_file="$registry/namespaces/example.test.json"
mkdir -p "$registry/keys/developers" "$registry/namespaces"

write_key() { # <kinds JSON> [<legacy namespaces JSON>]
  jq -n --arg key "$public_key" --argjson kinds "$1" --argjson namespaces "${2:-[\"xila\"]}" \
    '{id: "test-developer", author: "Test Developer", algorithm: "ed25519", public_key: $key}
     + (if $namespaces == null then {} else {namespaces: $namespaces} end)
     + (if $kinds == null then {} else {kinds: $kinds} end)' > "$key_file"
}
write_namespace() { # <developer keys JSON>
  jq -n --argjson keys "$1" \
    '{format_version: 1, namespace: "example.test", owner: {kind: "domain", name: "test.example"},
      developer_keys: $keys}' > "$namespace_file"
}
# A second developer, so that a namespace file can list another key.
"$builder" key generate "$work/other.seed" "$work/other.pub" >/dev/null
jq -n --arg key "$(base64 -w0 "$work/other.pub")" \
  '{id: "other-developer", author: "Other Developer", algorithm: "ed25519", public_key: $key}' \
  > "$registry/keys/developers/other-developer.json"
entry() { # <identifier> <target>
  local name="$1" target="$2"
  mkdir -p "$registry/packages/${name//.//}"
  "$builder" registry entry "$archives/$name-1.0.0-$target.xpk" "$work/developer.pub" test-developer \
    "https://example.com/releases/$name-1.0.0-$target.xpk" \
    "$registry/packages/${name//.//}/1.0.0.json" >/dev/null
}
entry example.test.wasm wasm32-wasip1
entry example.test.native thumbv7em-none-eabi
entry xila.test wasm32-wasip1
check() { "$builder" registry check "$registry" --archives "$archives"; }

# ---- Developer key authorization per namespace and kind ----------------------

write_namespace '["test-developer"]'
write_key '["wasm","native"]'
expect_success "a key authorized for both kinds publishes Wasm and native" check

write_key null
expect_failure "a key without kinds may not publish native" "not authorized for native" check
write_key '["wasm"]'
expect_failure "a Wasm-only key may not publish native" "not authorized for native" check
write_key '["native"]'
expect_failure "a native-only key may not publish Wasm" "not authorized for wasm" check
write_key '["wasm","native"]'

write_namespace '["other-developer"]'
expect_failure "a key may only publish in namespaces that list it" "not listed in namespace example.test" check
rm "$namespace_file"
expect_failure "a reverse-DNS identifier needs a namespace file" "no namespace file covers" check
write_namespace '["test-developer"]'
write_key '["wasm","native"]' null
expect_failure "a legacy xila.<name> identifier needs the key's legacy grant" "legacy namespace not granted" check
write_key '["wasm","native"]'
expect_success "the restored key and namespace are accepted again" check

# ---- Immutable archives -------------------------------------------------------

wasm_archive="$archives/example.test.wasm-1.0.0-wasm32-wasip1.xpk"
cp "$wasm_archive" "$work/wasm-original.xpk"
size="$(stat -c %s "$wasm_archive")"
head -c $((size - 1024)) "$work/wasm-original.xpk" > "$wasm_archive"
expect_failure "a truncated archive is refused" "size or SHA-256 differs" check
cp "$work/wasm-original.xpk" "$wasm_archive"
printf '\x01' | dd of="$wasm_archive" bs=1 seek=$((size - 600)) conv=notrunc status=none
expect_failure "an altered archive of the same size is refused" "size or SHA-256 differs" check
cp "$work/wasm-original.xpk" "$wasm_archive"
expect_success "the restored archive is accepted again" check

# ---- Signed metadata ----------------------------------------------------------

expect_success "every entry and key signs and verifies from a root key" \
  bash "$root/tools/rehearse_signing.sh" "$registry"

"$builder" key generate "$work/root.seed" "$work/root.pub" >/dev/null
"$builder" key generate "$work/repository.seed" "$work/repository.pub" >/dev/null
"$builder" key generate "$work/rogue.seed" "$work/rogue.pub" >/dev/null
"$builder" registry root "$work/root.seed" test-root "$work/repository.pub" test-repository 1 \
  "$registry/root.json" >/dev/null
sign() { "$builder" registry sign "$registry" "$work/root.pub" "$1" "$2" --expires-in-days 1; }
expect_failure "signing needs a repository key listed in root.json" "not a repository key" sign "$work/rogue.seed" "$work/site-rogue"
expect_success "signing with the listed repository key" sign "$work/repository.seed" "$work/site"
verify() { "$builder" registry verify-signed "$work/site" "$work/root.pub"; }
expect_success "the signed registry verifies" verify

native_entry="$work/site/packages/example/test/native/1.0.0.json"
cp "$native_entry" "$work/entry-original.json"
sed -i 's/"size":\([0-9]*\)/"size":1\1/' "$native_entry"
expect_failure "an entry altered after signing is refused" "not listed in the index with this hash" verify
cp "$work/entry-original.json" "$native_entry"
rm "$native_entry.sig"
expect_failure "an unsigned entry is refused" "No such file" verify
cp "$work/site/packages/example/test/wasm/1.0.0.json.sig" "$native_entry.sig"
expect_failure "an entry carrying another entry's signature is refused" "not made by a trusted key" verify
rm "$native_entry.sig"
cp "$work/site/keys/developers/test-developer.json" "$work/site/packages/example/test/native/extra.json"
expect_failure "an unlisted file is refused" "not listed in index.json" verify
rm "$work/site/packages/example/test/native/extra.json"
sign_other=$(mktemp -d)
"$builder" registry sign "$registry" "$work/root.pub" "$work/repository.seed" "$sign_other/site" --expires-in-days 1 >/dev/null
cp "$sign_other/site/packages/example/test/native/1.0.0.json.sig" "$native_entry.sig"
expect_success "the restored signature verifies again" verify
rm -rf "$sign_other"

# ---- Published entries are immutable -------------------------------------------

repository="$work/repository"
mkdir "$repository"
cp -R "$registry/keys" "$registry/packages" "$repository/"
# A format 1 entry from before the move to format 2 (fields abridged).
mkdir -p "$repository/packages/xila/legacy"
printf '{"format_version":1,"name":"xila.legacy","version":"0.1.0","minimum_xila_abi":1}' \
  > "$repository/packages/xila/legacy/0.1.0.json"
git -C "$repository" init -q -b main
git -C "$repository" config user.name test
git -C "$repository" config user.email test@example.com
git -C "$repository" add -A
git -C "$repository" commit -q -m "publish"
git -C "$repository" checkout -q -b change
immutable() { bash "$root/tools/check_immutable.sh" main "$repository"; }

published="$repository/packages/example/test/wasm/1.0.0.json"
expect_success "no change is accepted" immutable

sed 's/"1.0.0"/"1.1.0"/' "$published" > "$repository/packages/example/test/wasm/1.1.0.json"
git -C "$repository" add -A; git -C "$repository" commit -q -m "add a version"
expect_success "a new version is accepted" immutable

jq -c '.archive.sha256 = ("0" * 64)' "$published" > "$work/changed.json" && cp "$work/changed.json" "$published"
git -C "$repository" commit -q -am "change the archive hash"
expect_failure "changing a published archive hash is refused" "archive.sha256 changed" immutable
git -C "$repository" reset -q --hard HEAD~1

jq -c '.archive.size += 1' "$published" > "$work/changed.json" && cp "$work/changed.json" "$published"
git -C "$repository" commit -q -am "change the archive size"
expect_failure "changing a published archive size is refused" "archive.size changed" immutable
git -C "$repository" reset -q --hard HEAD~1

jq -c '.publisher = "renamed-developer"' "$published" > "$work/changed.json" && cp "$work/changed.json" "$published"
git -C "$repository" commit -q -am "rename the publisher"
expect_failure "changing only the publisher is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

printf '{"format_version":1,"name":"xila.legacy","version":"0.1.0","minimum_xila_abi":1,"publisher":"renamed-developer"}' \
  > "$repository/packages/xila/legacy/0.1.0.json"
git -C "$repository" commit -q -am "rename the publisher of a format 1 entry"
expect_failure "changing the publisher of a format 1 entry is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

git -C "$repository" rm -q "packages/example/test/native/1.0.0.json"
git -C "$repository" commit -q -m "delete a version"
expect_failure "deleting a published version is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

printf '{"format_version":1,"name":"xila.legacy","version":"0.1.0","minimum_xila_abi":2}' \
  > "$repository/packages/xila/legacy/0.1.0.json"
git -C "$repository" commit -q -am "edit a format 1 entry"
expect_failure "editing a format 1 entry is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

git -C "$repository" rm -q "packages/xila/legacy/0.1.0.json"
git -C "$repository" commit -q -m "remove a format 1 entry"
expect_success "removing a format 1 entry is accepted" immutable
git -C "$repository" rm -q "packages/example/test/wasm/1.0.0.json"
git -C "$repository" commit -q -m "remove a format 1 entry and a format 2 entry"
expect_failure "removing a format 2 entry alongside is still refused" "packages/example/test/wasm/1.0.0.json" immutable

# ---- Package submission (tools/submit.sh, tools/propose_submission.sh) -------

# A registry checkout with the submission tools. Its validate.sh checks the
# local archives instead of downloading every entry's archive.
submission="$work/submission"
mkdir -p "$submission/tools"
cp -R "$registry/keys" "$registry/namespaces" "$registry/packages" "$submission/"
cp "$root/tools/submit.sh" "$root/tools/propose_submission.sh" "$root/tools/report_submission.sh" "$submission/tools/"
# shellcheck disable=SC2016 # Written to a script, expanded when it runs.
printf '#!/usr/bin/env bash\nset -euo pipefail\ncd "$(dirname "${BASH_SOURCE[0]}")/.."\n"$XILA_PACKAGE" registry check . --archives "$SUBMISSION_TEST_ARCHIVES"\n' \
  > "$submission/tools/validate.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "$XILA_PACKAGE"\n' > "$submission/tools/xila-package.sh"
git init -q --bare "$work/submission-origin.git"
git -C "$submission" init -q -b main
git -C "$submission" config user.name test
git -C "$submission" config user.email test@example.com
git -C "$submission" remote add origin "$work/submission-origin.git"
git -C "$submission" add -A
git -C "$submission" commit -q -m "registry"
git -C "$submission" push -q origin main

# A release of example.test.release whose signed manifest names its source
# repository, as a GitHub release would publish it.
release_source="$work/source-release"
"$builder" bundle init "$release_source" example.test.release 2.0.0 wasm32-wasip1 --xila-version 0.1 --standalone >/dev/null
printf 'test payload release' > "$release_source/executables/main.wasm"
jq '.metadata = {summary: "Test release.", license: "MIT", source: "https://github.com/Example/Release"}' \
  "$release_source/xila-package.json" > "$work/release-manifest.json"
cp "$work/release-manifest.json" "$release_source/xila-package.json"
"$builder" bundle build "$release_source" "$work/release.app" --signing-key "$work/developer.seed" >/dev/null
release_name="example.test.release-2.0.0-wasm32-wasip1.xpk"
mkdir -p "$work/submission-archives"
"$builder" bundle archive "$work/release.app" "$work/submission-archives/$release_name" >/dev/null
cp "$archives"/*.xpk "$work/submission-archives/"
release_archive="$work/submission-archives/$release_name"
release_url="https://github.com/example/release/releases/download/v2.0.0/$release_name"

submit() { # <archive URL> <publisher> [<archive>] [NAME=value ...]
  local url="$1" publisher="$2" archive="${3:-$release_archive}"
  shift 3 || shift $#
  git -C "$submission" reset -q --hard
  git -C "$submission" clean -q -fd
  env XILA_PACKAGE="$builder" SUBMISSION_TEST_ARCHIVES="$work/submission-archives" \
    SUBMISSION_ARCHIVE_URL="$url" SUBMISSION_PUBLISHER="$publisher" SUBMISSION_ARCHIVE_SHA256= \
    SUBMISSION_PUBLIC_KEY= SUBMISSION_AUTHOR= SUBMISSION_SUBMITTER=submitter "$@" \
    bash "$submission/tools/submit.sh" "$work/submission-work" --archive "$archive"
}
outcome() { # <expected outcome> <command...>: the command writes result.json
  local expected="$1"; shift
  "$@" || true
  [[ "$(jq -r '.outcome' "$work/submission-work/result.json")" == "$expected" ]] \
    || { jq . "$work/submission-work/result.json"; return 1; }
}

expect_success "a new version of a registered publisher from its source repository is automatic" \
  outcome automatic submit "$release_url" test-developer
expect_success "the automatic submission adds the entry only" \
  test "$(jq -c '.files' "$work/submission-work/result.json")" = '["packages/example/test/release/2.0.0.json"]'
mkdir -p "$work/propose"
propose() {
  : > "$work/propose/output"
  (cd "$submission" && env GITHUB_REPOSITORY=example/registry SUBMISSION_DRY_RUN=true \
    XILA_PACKAGE="$builder" \
    bash tools/propose_submission.sh "$work/submission-work" "$work/propose/output")
}
propose_prepared() {
  git -C "$submission" reset -q --hard && git -C "$submission" clean -q -fd && propose \
    && grep -q "^state=dry-run" "$work/propose/output"
}
expect_success "the prepared submission commits on a dry run" propose_prepared
expect_success "the dry-run commit adds the entry only" \
  test "$(git -C "$submission" show --name-status --format= HEAD)" = "A	packages/example/test/release/2.0.0.json"
git -C "$submission" reset -q --hard HEAD~1
mkdir -p "$work/submission-work/files/keys/developers"
printf '{}' > "$work/submission-work/files/keys/developers/extra.json"
expect_failure "a submission with an unlisted file is not proposed" "differ from the listed files" propose
rm "$work/submission-work/files/keys/developers/extra.json"
jq '.files += ["keys/developers/extra.json"]' "$work/submission-work/result.json" > "$work/result.json"
cp "$work/result.json" "$work/submission-work/result.json"
printf '{}' > "$work/submission-work/files/keys/developers/extra.json"
expect_failure "a submission may only add its entry, key and namespace" "may not add keys/developers/extra.json" propose

# The pinned xila-package binary is verified against its committed digest
# before it runs (issue #24).
expect_failure "a binary that is not the pinned one is refused" "digest mismatch" \
  bash "$root/tools/xila-package.sh" --verify /bin/true
ln -s /bin/true "$work/link"
expect_failure "a symlink is not accepted as the binary" "not an executable regular file" \
  bash "$root/tools/xila-package.sh" --verify "$work/link"
expect_success "a local XILA_PACKAGE override is printed without verification" \
  test "$(XILA_PACKAGE="$builder" bash "$root/tools/xila-package.sh")" = "$builder"

# The propose job validates the final tree offline (issue #24): an entry that
# does not sit at its own path is refused after the commit, before anything is
# pushed, recorded or merged.
outcome automatic submit "$release_url" test-developer
tampered="$work/submission-work/files/packages/example/test/release/2.0.0.json"
jq -c '.version = "9.9.9"' "$tampered" > "$work/changed.json" && cp "$work/changed.json" "$tampered"
git -C "$submission" reset -q --hard && git -C "$submission" clean -q -fd
expect_failure "the final tree is checked offline before it is proposed" 'must be at\|not canonical' propose
git -C "$submission" reset -q --hard origin/main

# A stub gh for the supersede tests (issue #25): it logs every call and answers
# an open pull request on the submission branch, with the head commit read
# from the local origin. GH_STUB_MODE=fork answers a cross-repository pull
# request and GH_STUB_MODE=mismatch a pull request whose head moved; neither
# must be superseded.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_STUB_LOG:?GH_STUB_LOG is not set}"
case "$*" in
  *"pr list"*)
    branch=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--head" ]]; then branch="$argument"; fi
      previous="$argument"
    done
    branch_sha="$(git ls-remote --heads origin "refs/heads/$branch" | cut -f1)"
    cross=false login="app/github-actions" is_bot=true head_oid="$branch_sha"
    case "${GH_STUB_MODE:-review}" in
      fork) cross=true login="someone" is_bot=false head_oid="0000" ;;
      mismatch) head_oid="deadbeef" ;;
    esac
    printf '[{"url":"https://example.test/pr/1","body":"<!-- package-submission-outcome: review -->\\nA maintainer must review it","isCrossRepository":%s,"author":{"login":"%s","is_bot":%s},"headRefOid":"%s"}]\n' \
      "$cross" "$login" "$is_bot" "$head_oid"
    ;;
  *"pr view"*) printf 'OPEN\n' ;;
  *) printf 'https://example.test/pr/2\n' ;;
esac
STUB
chmod +x "$work/bin/gh"
# A logging git wrapper, so the tests can assert on the pushes (the branch
# delete uses --force-with-lease, not gh).
cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "${GH_STUB_LOG:?GH_STUB_LOG is not set}"
exec /usr/bin/git "$@"
STUB
chmod +x "$work/bin/git"
propose_full() { # A real (non-dry) run against the local origin, with the stub gh.
  : > "$work/propose/output"
  : > "$work/gh.log"
  (cd "$submission" && env GITHUB_REPOSITORY=example/registry SUBMISSION_DRY_RUN=false GH_TOKEN=dummy \
    XILA_PACKAGE="$builder" PATH="$work/bin:$PATH" GH_STUB_LOG="$work/gh.log" GH_STUB_MODE="${GH_STUB_MODE:-review}" \
    bash tools/propose_submission.sh "$work/submission-work" "$work/propose/output")
}
absent() { # <pattern> <file>: succeeds when the pattern is not in the file
  ! grep -q -- "$1" "$2"
}

# An automatic submission finds the open review pull request on its branch,
# closes it with a comment, deletes the branch and continues to the merge.
# The branch first points at a diverging commit, so the delete must use the
# lease on the commit that was read, and the push must replace the branch.
outcome automatic submit "$release_url" test-developer
empty_tree="$(git -C "$submission" hash-object -t tree /dev/null)"
diverging="$(git -C "$submission" commit-tree "$empty_tree" -m diverging)"
git -C "$submission" push -q --force origin "$diverging:refs/heads/submission/example.test.release/2.0.0"
git -C "$submission" reset -q --hard origin/main && git -C "$submission" clean -q -fd
expect_success "an automatic submission supersedes the review pull request and merges" propose_full
expect_success "the superseded pull request is commented" \
  grep -q "pr comment https://example.test/pr/1" "$work/gh.log"
expect_success "the superseded pull request is closed" \
  grep -q "pr close https://example.test/pr/1" "$work/gh.log"
expect_success "the branch is deleted with a lease on the commit that was read" \
  grep -q -- "--force-with-lease=refs/heads/submission/example.test.release/2.0.0:$diverging" "$work/gh.log"
expect_success "the diverging branch head is replaced by the new submission" \
  test "$(git -C "$submission" ls-remote --heads origin refs/heads/submission/example.test.release/2.0.0 | cut -f1)" = "$(git -C "$submission" rev-parse HEAD)"
expect_success "the automatic submission merges after the supersede" \
  grep -q '^state=merged' "$work/propose/output"
git -C "$submission" push -q origin --delete refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main

# A pull request from a fork on the same branch name is not superseded.
outcome automatic submit "$release_url" test-developer
git -C "$submission" push -q origin main:refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main && git -C "$submission" clean -q -fd
GH_STUB_MODE=fork expect_success "an automatic submission does not supersede a fork pull request" propose_full
expect_success "a fork pull request keeps the submission pending" \
  grep -q '^state=pending' "$work/propose/output"
expect_success "a fork pull request is not closed" absent "pr close" "$work/gh.log"
git -C "$submission" push -q origin --delete refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main

# A pull request whose head no longer matches the branch commit is not
# superseded either.
outcome automatic submit "$release_url" test-developer
git -C "$submission" push -q origin main:refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main && git -C "$submission" clean -q -fd
GH_STUB_MODE=mismatch expect_success "an automatic submission does not supersede a moved pull request head" propose_full
expect_success "a moved head keeps the submission pending" \
  grep -q '^state=pending' "$work/propose/output"
expect_success "a moved head is not closed" absent "pr close" "$work/gh.log"
expect_success "a moved head does not delete the branch" absent -- "--force-with-lease" "$work/gh.log"
git -C "$submission" push -q origin --delete refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main

# A submission for review never closes or deletes anything: it stays pending.
outcome review submit "https://example.com/releases/$release_name" test-developer
git -C "$submission" push -q origin main:refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main && git -C "$submission" clean -q -fd
expect_success "a review submission stays pending on an existing branch" propose_full
expect_success "the pending state is reported" grep -q '^state=pending' "$work/propose/output"
expect_success "a review submission does not close the pull request" absent "pr close" "$work/gh.log"
expect_success "a review submission does not delete the branch" absent -- "--force-with-lease" "$work/gh.log"
expect_success "a review submission does not push a branch deletion" absent -- ":refs/heads/" "$work/gh.log"
git -C "$submission" push -q origin --delete refs/heads/submission/example.test.release/2.0.0
git -C "$submission" reset -q --hard origin/main

expect_success "an archive outside the source repository waits for a review" \
  outcome review submit "https://example.com/releases/$release_name" test-developer
expect_success "the review names the reason" \
  grep -q "not a GitHub release asset" "$work/submission-work/result.json"
expect_success "a release of another repository waits for a review" \
  outcome review submit "https://github.com/someone/else/releases/download/v2.0.0/$release_name" test-developer
expect_success "a matching SHA-256 is accepted" \
  outcome automatic submit "$release_url" test-developer "$release_archive" \
  SUBMISSION_ARCHIVE_SHA256="$(sha256sum "$release_archive" | cut -d ' ' -f 1 | tr a-f A-F)"
expect_success "a different SHA-256 is refused" \
  outcome invalid submit "$release_url" test-developer "$release_archive" SUBMISSION_ARCHIVE_SHA256="$(printf '0%.0s' {1..64})"
expect_success "a published version is a duplicate" \
  outcome duplicate submit "https://example.com/releases/example.test.wasm-1.0.0-wasm32-wasip1.xpk" test-developer \
  "$archives/example.test.wasm-1.0.0-wasm32-wasip1.xpk"
expect_success "an archive that the publisher did not sign is refused" \
  outcome invalid submit "$release_url" other-developer
expect_success "a different key for a registered publisher is refused" \
  outcome invalid submit "$release_url" test-developer "$release_archive" SUBMISSION_PUBLIC_KEY="$(base64 -w0 "$work/other.pub")"
expect_success "an unknown publisher without a key is refused" \
  outcome invalid submit "$release_url" new-developer
expect_success "a registered key under a new publisher identifier is refused" \
  outcome invalid submit "$release_url" new-developer "$release_archive" SUBMISSION_PUBLIC_KEY="$public_key" SUBMISSION_AUTHOR=New

# A new publisher in io.github.<account>, submitted by that account.
"$builder" key generate "$work/new.seed" "$work/new.pub" >/dev/null
new_source="$work/source-new"
"$builder" bundle init "$new_source" io.github.submitter.tool 1.0.0 wasm32-wasip1 --xila-version 0.1 --standalone >/dev/null
printf 'test payload new' > "$new_source/executables/main.wasm"
"$builder" bundle build "$new_source" "$work/new.app" --signing-key "$work/new.seed" >/dev/null
new_name="io.github.submitter.tool-1.0.0-wasm32-wasip1.xpk"
"$builder" bundle archive "$work/new.app" "$work/submission-archives/$new_name" >/dev/null
new_url="https://github.com/submitter/tool/releases/download/v1.0.0/$new_name"
expect_success "a new publisher waits for a review" \
  outcome review submit "$new_url" new-developer "$work/submission-archives/$new_name" \
  SUBMISSION_PUBLIC_KEY="$(base64 -w0 "$work/new.pub")" SUBMISSION_AUTHOR="New Developer"
expect_success "a new publisher adds a Wasm-only key and its io.github namespace" \
  test "$(jq -c '[.files, (input | .kinds), (input | .owner)]' "$work/submission-work/result.json" \
    "$submission/keys/developers/new-developer.json" "$submission/namespaces/io.github.submitter.json")" \
  = '[["keys/developers/new-developer.json","packages/io/github/submitter/tool/1.0.0.json","namespaces/io.github.submitter.json"],["wasm"],{"kind":"github","name":"submitter"}]'
expect_success "an io.github namespace of another account is refused" \
  outcome invalid submit "$new_url" new-developer "$work/submission-archives/$new_name" \
  SUBMISSION_PUBLIC_KEY="$(base64 -w0 "$work/new.pub")" SUBMISSION_AUTHOR="New Developer" SUBMISSION_SUBMITTER=someone-else

refused() { # <pattern> <NAME=value ...>: refused before any download
  local pattern="$1"; shift
  outcome invalid submit "$release_url" test-developer "$release_archive" "$@" \
    && grep -q -- "$pattern" "$work/submission-work/result.json"
}
for url in "http://github.com/a/b/releases/download/v1/a.xpk" "https://127.0.0.1/a.xpk" "https://localhost/a.xpk" \
  "https://0x7f.1/a.xpk" "https://0xa9.0xfe.0xa9.0xfe/a.xpk" "https://0251.254.169.254/a.xpk" "https://metadata.internal/a.xpk" \
  "https://example.com:8443/a.xpk" "https://user@example.com/a.xpk" "https://example.com/a.xpk?x=1" \
  "https://example.com/a/../b.xpk" "https://example.com/a.zip" "https://example.com/a.xpk
https://example.com/b.xpk" "https://example.com/\$(id).xpk"; do
  expect_success "the archive URL $(printf '%q' "$url") is refused" \
    refused "archive URL must be" SUBMISSION_ARCHIVE_URL="$url"
done
expect_success "an invalid publisher identifier is refused" outcome invalid submit "$release_url" Bad_Publisher
expect_success "an invalid SHA-256 is refused" refused "SHA-256 must be" SUBMISSION_ARCHIVE_SHA256=1234
# shellcheck disable=SC2016 # A literal command substitution, as untrusted input.
expect_success "an invalid public key is refused" refused "public key must be" SUBMISSION_PUBLIC_KEY='$(id)'
for codepoint in 00ad 200b 200c 200d 200e 200f 2028 2029 202e 2060 2066 feff; do
  # shellcheck disable=SC2059 # The format is a fixed \u escape plus a hexadecimal codepoint from the list above.
  author="a$(printf "\\u$codepoint")b"
  expect_success "an author name with U+$codepoint is refused" \
    refused "author name must" SUBMISSION_AUTHOR="$author"
done
# U+0085 (NEL) is a control character (category Cc) that the [[:cntrl:]] shell
# test misses under LC_ALL=C, where its bytes are not ASCII control bytes: the
# jq test must refuse it in every locale. Its UTF-8 bytes are written directly
# because printf \u output depends on the locale.
expect_success "an author name with U+0085 is refused under LC_ALL=C" \
  refused "author name must" LC_ALL=C SUBMISSION_AUTHOR="$(printf 'a\xc2\x85b')"
# Non-BMP tag characters (category Cf, the usual hidden-text vector): printf \u
# cannot produce them, so their UTF-8 bytes are written directly (U+E0001 is
# f3 a0 80 81 and U+E0020 is f3 a0 80 a0).
expect_success "an author name with U+E0001 is refused" \
  refused "author name must" SUBMISSION_AUTHOR="$(printf 'a\xf3\xa0\x80\x81b')"
expect_success "an author name with U+E0020 is refused" \
  refused "author name must" SUBMISSION_AUTHOR="$(printf 'a\xf3\xa0\x80\xa0b')"
expect_success "an author name with accented letters is accepted" \
  outcome review submit "$new_url" new-developer "$work/submission-archives/$new_name" \
  SUBMISSION_PUBLIC_KEY="$(base64 -w0 "$work/new.pub")" SUBMISSION_AUTHOR="Zoë Müller"
expect_success "an author name with an apostrophe is accepted" \
  outcome review submit "$new_url" new-developer "$work/submission-archives/$new_name" \
  SUBMISSION_PUBLIC_KEY="$(base64 -w0 "$work/new.pub")" SUBMISSION_AUTHOR="O'Brien"
expect_success "an author name with a hyphen is accepted" \
  outcome review submit "$new_url" new-developer "$work/submission-archives/$new_name" \
  SUBMISSION_PUBLIC_KEY="$(base64 -w0 "$work/new.pub")" SUBMISSION_AUTHOR="Jean-Luc"
expect_success "an author name with a backtick is refused" refused "author name must" SUBMISSION_AUTHOR='a`b'

report_refused() {
  local status=0
  bash "$submission/tools/report_submission.sh" "$work/submission-work" "$work/report.md" >/dev/null || status=$?
  [[ $status -eq 1 ]] && grep -q "was refused" "$work/report.md" && ! grep -q 'a`b' "$work/report.md"
}
expect_success "a refused submission is reported without backticks from the input" report_refused

if [[ $failures -ne 0 ]]; then
  printf '%s validation test(s) failed\n' "$failures" >&2
  exit 1
fi
echo "All validation tests passed"
