#!/usr/bin/env bash
# Refuse changes to already published registry entries.
#
# usage: tools/check_immutable.sh <base-ref> [repository-directory]
#   Compares HEAD with <base-ref> (the merge base is used, so concurrent
#   additions on the base are not changes). A published version is immutable:
#   its entry, and therefore its archive URL, SHA-256 and size, may not be
#   edited, renamed or deleted. Release a new version instead.
set -euo pipefail

base="${1:?usage: check_immutable.sh <base-ref> [repository-directory]}"
cd "${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

changed="$(git diff --name-only --diff-filter=MDRT "$base"...HEAD -- 'packages/*.json')"
if [[ -z "$changed" ]]; then
  exit 0
fi
while IFS= read -r entry; do
  if git cat-file -e "$base:$entry" 2>/dev/null && [[ -f "$entry" ]]; then
    for field in .archive.url .archive.sha256 .archive.size; do
      before="$(git show "$base:$entry" | jq -c "$field")"
      after="$(jq -c "$field" "$entry")"
      if [[ "$before" != "$after" ]]; then
        printf '%s: published %s changed from %s to %s\n' "$entry" "${field#.}" "$before" "$after" >&2
      fi
    done
  fi
done <<< "$changed"
printf 'published registry entries must not change; release a new version instead:\n%s\n' "$changed" >&2
exit 1
