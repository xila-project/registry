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
#   Every other change to a format 2 entry is refused.
set -euo pipefail

base="${1:?usage: check_immutable.sh <base-ref> [repository-directory]}"
cd "${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Entries are read at the merge base, the same revision `base...HEAD` compares.
merge_base="$(git merge-base "$base" HEAD)"

changed=""
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  if [[ ! -e "$entry" ]] \
    && [[ "$(git show "$merge_base:$entry" 2>/dev/null | jq -r '.format_version' 2>/dev/null)" == 1 ]]; then
    printf '%s: removed format 1 entry (no longer verifiable)\n' "$entry"
    continue
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
