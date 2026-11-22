#!/usr/bin/env bash
# Test the registry validation rules against fixtures generated on the fly.
#
# usage: tools/test.sh
# Every key is generated here with `xila-package key generate` and discarded;
# nothing in this script is a real key. The fixtures are one signed Wasm
# package and one signed native package from a throwaway test developer, and
# each case breaks one rule and expects the validation to refuse it.
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
package test.wasm wasm32-wasip1 executables/main.wasm
package test.native thumbv7em-none-eabi executables/main.bin

registry="$work/registry"
archives="$work/archives"
key_file="$registry/keys/developers/test-developer.json"
mkdir -p "$registry/keys/developers" "$registry/packages/test/wasm" "$registry/packages/test/native"

write_key() { # <namespaces JSON> [<kinds JSON>]
  jq -n --arg key "$public_key" --argjson namespaces "$1" --argjson kinds "${2:-null}" \
    '{id: "test-developer", author: "Test Developer", algorithm: "ed25519", public_key: $key, namespaces: $namespaces}
     + (if $kinds == null then {} else {kinds: $kinds} end)' > "$key_file"
}
entry() { # <identifier> <target>
  local name="$1" target="$2"
  "$builder" registry entry "$archives/$name-1.0.0-$target.xpk" "$work/developer.pub" test-developer \
    "https://example.com/releases/$name-1.0.0-$target.xpk" \
    "$registry/packages/test/${name#test.}/1.0.0.json" >/dev/null
}
entry test.wasm wasm32-wasip1
entry test.native thumbv7em-none-eabi
check() { "$builder" registry check "$registry" --archives "$archives"; }

# ---- Developer key authorization per namespace and kind ----------------------

write_key '["test"]' '["wasm","native"]'
expect_success "a key authorized for both kinds publishes Wasm and native" check

write_key '["test"]'
expect_failure "a key without kinds may not publish native" "not authorized for native" check
write_key '["test"]' '["wasm"]'
expect_failure "a Wasm-only key may not publish native" "not authorized for native" check
write_key '["test"]' '["native"]'
expect_failure "a native-only key may not publish Wasm" "not authorized for wasm" check
write_key '["other"]' '["wasm","native"]'
expect_failure "a key may only publish its namespaces" "may not publish" check
write_key '["test"]' '["wasm","native"]'

# ---- Immutable archives -------------------------------------------------------

wasm_archive="$archives/test.wasm-1.0.0-wasm32-wasip1.xpk"
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

native_entry="$work/site/packages/test/native/1.0.0.json"
cp "$native_entry" "$work/entry-original.json"
sed -i 's/"size":\([0-9]*\)/"size":1\1/' "$native_entry"
expect_failure "an entry altered after signing is refused" "not listed in the index with this hash" verify
cp "$work/entry-original.json" "$native_entry"
rm "$native_entry.sig"
expect_failure "an unsigned entry is refused" "No such file" verify
cp "$work/site/packages/test/wasm/1.0.0.json.sig" "$native_entry.sig"
expect_failure "an entry carrying another entry's signature is refused" "not made by a trusted key" verify
rm "$native_entry.sig"
cp "$work/site/keys/developers/test-developer.json" "$work/site/packages/test/native/extra.json"
expect_failure "an unlisted file is refused" "not listed in index.json" verify
rm "$work/site/packages/test/native/extra.json"
sign_other=$(mktemp -d)
"$builder" registry sign "$registry" "$work/root.pub" "$work/repository.seed" "$sign_other/site" --expires-in-days 1 >/dev/null
cp "$sign_other/site/packages/test/native/1.0.0.json.sig" "$native_entry.sig"
expect_success "the restored signature verifies again" verify
rm -rf "$sign_other"

# ---- Published entries are immutable -------------------------------------------

repository="$work/repository"
mkdir "$repository"
cp -R "$registry/keys" "$registry/packages" "$repository/"
git -C "$repository" init -q -b main
git -C "$repository" config user.name test
git -C "$repository" config user.email test@example.com
git -C "$repository" add -A
git -C "$repository" commit -q -m "publish"
git -C "$repository" checkout -q -b change
immutable() { bash "$root/tools/check_immutable.sh" main "$repository"; }

published="$repository/packages/test/wasm/1.0.0.json"
expect_success "no change is accepted" immutable

mkdir -p "$repository/packages/test/wasm"
sed 's/"1.0.0"/"1.1.0"/' "$published" > "$repository/packages/test/wasm/1.1.0.json"
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

git -C "$repository" rm -q "packages/test/native/1.0.0.json"
git -C "$repository" commit -q -m "delete a version"
expect_failure "deleting a published version is refused" "must not change" immutable

if [[ $failures -ne 0 ]]; then
  printf '%s validation test(s) failed\n' "$failures" >&2
  exit 1
fi
echo "All validation tests passed"
