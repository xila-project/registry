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
# An entry still published under the publisher `xila-project`, which the
# one-time migration (registry#19) may rename to `xila`. Remove with the migration.
mkdir -p "$repository/packages/xila/migrated"
jq -c '.publisher = "xila-project"' "$registry/packages/example/test/wasm/1.0.0.json" \
  > "$repository/packages/xila/migrated/1.0.0.json"
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

# One-time migration of the publisher `xila-project` to `xila` (registry#19).
# Remove these cases with the migration.
migrated="$repository/packages/xila/migrated/1.0.0.json"
change_migrated() { # <jq filter> <commit message>
  jq -c "$1" "$migrated" > "$work/changed.json" && cp "$work/changed.json" "$migrated"
  git -C "$repository" commit -q -am "$2"
}

change_migrated '.publisher = "xila"' "rename the publisher to xila"
expect_success "migration: xila-project renamed to xila is accepted" immutable
git -C "$repository" reset -q --hard HEAD~1

change_migrated '.publisher = "renamed-developer"' "rename the publisher to another value"
expect_failure "migration: xila-project renamed to another value is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

change_migrated '.publisher = "xila" | .archive.sha256 = ("0" * 64)' "rename the publisher and change the archive hash"
expect_failure "migration: the rename with a changed archive hash is refused" "archive.sha256 changed" immutable
git -C "$repository" reset -q --hard HEAD~1

change_migrated '.publisher = "xila" | .display_name = "Renamed"' "rename the publisher and change the display name"
expect_failure "migration: the rename with another changed field is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

change_migrated '.publisher = "xila" | .extra = true' "rename the publisher and add a field"
expect_failure "migration: the rename with an added field is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

change_migrated '.display_name = "Renamed"' "change the display name only"
expect_failure "migration: a change that is not the publisher is refused" "must not change" immutable
git -C "$repository" reset -q --hard HEAD~1

jq -c '.publisher = "xila"' "$published" > "$work/changed.json" && cp "$work/changed.json" "$published"
git -C "$repository" commit -q -am "rename the publisher of an entry that is not xila-project"
expect_failure "migration: renaming another publisher to xila is refused" "must not change" immutable
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

if [[ $failures -ne 0 ]]; then
  printf '%s validation test(s) failed\n' "$failures" >&2
  exit 1
fi
echo "All validation tests passed"
