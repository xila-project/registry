#!/usr/bin/env bash
# Refuse changes to already published registry entries.
#
# usage: tools/check_immutable.sh <base-ref> [repository-directory]
#   Compares HEAD with <base-ref> (the merge base is used, so concurrent
#   additions on the base are not changes). A published version is immutable:
#   its entry, and therefore its archive URL, SHA-256 and size, may not be
#   edited, renamed or deleted. Release a new version instead.
#
#   One exception, for the move to registry entry format 2: an entry that was
#   still in format 1 (`minimum_xila_abi`) may be deleted. No supported
#   xila-package or device can verify those entries or their archives.
#
#   A second exception, one time only, for the rename of the publisher
#   `xila-project` to `xila` (registry#19): see the one-time migration block
#   below. It is removed by the pull request that follows the migration. Every
#   other change to a format 2 entry is refused.
set -euo pipefail

base="${1:?usage: check_immutable.sh <base-ref> [repository-directory]}"
cd "${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Entries are read at the merge base, the same revision `base...HEAD` compares.
merge_base="$(git merge-base "$base" HEAD)"

# ---- BEGIN one-time migration (registry#19) -----------------------------------
# Remove this whole block, and its call below, right after the pull request that
# renames the publisher `xila-project` to `xila` is merged. Entries are immutable
# again from then on.
#
# An entry that exists at the merge base (so on `main` before the migration) may
# change when the change is exactly `publisher` from `xila-project` to `xila`:
# the entry before and after must be equal as JSON once `publisher` is set to
# `xila` in the entry before. The archive URL, SHA-256 and size stay, so the
# entry still pins the same archive, and the archive check of validate.sh proves
# that the key `xila` signed it.
#
# usage: allow_one_time_publisher_migration <entry-before-JSON> <entry-after-file>
allow_one_time_publisher_migration() {
  local before="$1" after_file="$2"
  [[ "$(jq -r '.format_version' <<< "$before" 2>/dev/null)" == 2 ]] || return 1
  [[ "$(jq -r '.publisher' <<< "$before" 2>/dev/null)" == "xila-project" ]] || return 1
  [[ "$(jq -r '.publisher' "$after_file" 2>/dev/null)" == "xila" ]] || return 1
  [[ "$(jq -cS '.publisher = "xila"' <<< "$before" 2>/dev/null)" == "$(jq -cS '.' "$after_file" 2>/dev/null)" ]]
}
# ---- END one-time migration (registry#19) -------------------------------------

changed=""
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  if [[ ! -e "$entry" ]] \
    && [[ "$(git show "$merge_base:$entry" 2>/dev/null | jq -r '.format_version' 2>/dev/null)" == 1 ]]; then
    printf '%s: removed format 1 entry (no longer verifiable)\n' "$entry"
    continue
  fi
  if [[ -f "$entry" ]] && git cat-file -e "$merge_base:$entry" 2>/dev/null; then
    before="$(git show "$merge_base:$entry")"
    # one-time migration (registry#19): remove with the block above
    if allow_one_time_publisher_migration "$before" "$entry"; then
      printf '%s: publisher renamed from xila-project to xila (one-time migration, same archive)\n' "$entry"
      continue
    fi
  fi
  changed+="$entry"$'\n'
done < <(git diff --name-only --no-renames --diff-filter=MDT "$base"...HEAD -- 'packages/*.json')

changed="${changed%$'\n'}"
if [[ -z "$changed" ]]; then
  exit 0
fi
while IFS= read -r entry; do
  if git cat-file -e "$merge_base:$entry" 2>/dev/null && [[ -f "$entry" ]]; then
    for field in .archive.url .archive.sha256 .archive.size; do
      before="$(git show "$merge_base:$entry" | jq -c "$field")"
      after="$(jq -c "$field" "$entry")"
      if [[ "$before" != "$after" ]]; then
        printf '%s: published %s changed from %s to %s\n' "$entry" "${field#.}" "$before" "$after" >&2
      fi
    done
  fi
done <<< "$changed"
printf 'published registry entries must not change; release a new version instead:\n%s\n' "$changed" >&2
exit 1
