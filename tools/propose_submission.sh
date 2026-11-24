#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks in the printf formats are Markdown.
# Open the pull request of a prepared submission, and merge it when allowed.
#
# usage: tools/propose_submission.sh <submission-directory> <output-file>
#   <submission-directory> holds result.json and files/ from tools/submit.sh.
#   The checkout must be clean and at the commit that tools/submit.sh
#   validated, so that the pull request head has exactly the validated tree.
#   Writes name=value lines to <output-file> (for $GITHUB_OUTPUT):
#     state         opened | merged | merge-failed | pending | dry-run
#     pull-request  URL of the pull request (empty for dry-run)
#
# Environment:
#   GH_TOKEN               token with contents, pull-requests and statuses write
#   GITHUB_REPOSITORY      owner/name of the registry
#   SUBMISSION_ISSUE       issue number to close, or 0
#   SUBMISSION_DRY_RUN     true: commit locally only, push nothing
#   SUBMISSION_RUN_URL     URL of the workflow run (status link)
#
# This job never reads the archive. It accepts only the files that a
# submission may add (the entry, the developer key of the publisher and an
# io.github.<account> namespace file) and refuses anything else.
set -euo pipefail

submission="$(cd "${1:?usage: propose_submission.sh <submission-directory> <output-file>}" && pwd)"
output="${2:?usage: propose_submission.sh <submission-directory> <output-file>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
issue="${SUBMISSION_ISSUE:-0}"
dry_run="${SUBMISSION_DRY_RUN:-true}"
[[ "$issue" =~ ^[0-9]+$ ]] || { echo "invalid issue number" >&2; exit 1; }

result="$submission/result.json"
outcome="$(jq -r '.outcome' "$result")"
identifier="$(jq -r '.identifier' "$result")"
version="$(jq -r '.version' "$result")"
publisher="$(jq -r '.publisher' "$result")"
case "$outcome" in automatic | review) ;; *) echo "nothing to propose for outcome $outcome" >&2; exit 1 ;; esac
[[ "$identifier" =~ ^[a-z0-9_-]+(\.[a-z0-9_-]+)+$ ]] || { echo "invalid identifier" >&2; exit 1; }
[[ "$version" =~ ^[A-Za-z0-9+-]+(\.[A-Za-z0-9+-]+)*$ ]] || { echo "invalid version" >&2; exit 1; }
[[ "$publisher" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "invalid publisher" >&2; exit 1; }
entry="packages/${identifier//.//}/$version.json"
[[ "$(jq -r '.entry' "$result")" == "$entry" ]] || { echo "the entry path does not match the identifier and version" >&2; exit 1; }

# The uploaded files must be exactly the listed files, each an allowed path.
mapfile -t files < <(jq -r '.files[]' "$result" | sort)
mapfile -t present < <(cd "$submission/files" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\n' | sort)
[[ "${files[*]}" == "${present[*]}" ]] || { echo "the uploaded files differ from the listed files" >&2; exit 1; }
[[ " ${files[*]} " == *" $entry "* ]] || { echo "the submission has no entry" >&2; exit 1; }
for file in "${files[@]}"; do
  if [[ "$file" != "$entry" && "$file" != "keys/developers/$publisher.json" \
    && ! "$file" =~ ^namespaces/io\.github\.[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?\.json$ ]]; then
    echo "a submission may not add $file" >&2; exit 1
  fi
  source="$submission/files/$file"
  [[ -f "$source" && ! -L "$source" && "$(stat -c %s "$source")" -le 65536 ]] || { echo "$file is not a small regular file" >&2; exit 1; }
  jq -e . "$source" >/dev/null || { echo "$file is not JSON" >&2; exit 1; }
  [[ ! -e "$file" ]] || { echo "$file already exists" >&2; exit 1; }
done
if [[ "$outcome" == automatic && "${files[*]}" != "$entry" ]]; then
  echo "an automatic submission adds the entry only" >&2; exit 1
fi

[[ "$(git status --porcelain)" == "" ]] || { echo "the checkout has uncommitted changes" >&2; exit 1; }
for file in "${files[@]}"; do
  mkdir -p "$(dirname "$file")"
  cp "$submission/files/$file" "$file"
  git add -- "$file"
done
unexpected="$(git status --porcelain | grep -v '^A  ' || true)"
[[ -z "$unexpected" ]] || { echo "unexpected changes: $unexpected" >&2; exit 1; }

branch="submission/$identifier/$version"
title="feat(packages): add $identifier $version"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
{
  if [[ "$outcome" == automatic ]]; then
    printf 'Adds `%s` %s from a package submission. It meets the conditions for an automatic merge (registry issue #21).\n\n' "$identifier" "$version"
  else
    printf 'Adds `%s` %s from a package submission. A maintainer must review it (registry issue #21):\n\n' "$identifier" "$version"
    printf '```text\n'
    jq -r '.reasons[]' "$result" | tr -d '`' | head -n 20
    printf '```\n\n'
  fi
  printf -- '- Publisher: `%s`\n' "$publisher"
  printf -- '- Archive: `%s`\n' "$(jq -r '.archive.url' "$entry")"
  printf -- '- SHA-256: `%s`\n' "$(jq -r '.archive.sha256' "$entry")"
  printf -- '- Files: %s\n' "$(printf '`%s` ' "${files[@]}")"
  printf '\nThe submission workflow downloaded the archive, verified its signature, generated the entry with `xila-package registry entry` and ran `tools/test.sh` and `tools/validate.sh` on this tree: %s\n' "${SUBMISSION_RUN_URL:-}"
  if [[ "$issue" != 0 ]]; then
    printf '\nCloses #%s\n' "$issue"
  fi
} > "$body"

note="Submitted with the package submission workflow."
if [[ "$issue" != 0 ]]; then
  note="Submitted with the package submission form (#$issue)."
fi
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit --quiet -m "$title" -m "$note"
head="$(git rev-parse HEAD)"

remote_branch="$(git ls-remote --heads origin "refs/heads/$branch")"
if [[ -n "$remote_branch" ]]; then
  pull_request="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state open --json url --jq '.[0].url // ""')"
  printf 'state=pending\npull-request=%s\n' "$pull_request" >> "$output"
  echo "a submission branch already exists for $identifier $version: ${pull_request:-no open pull request}" >&2
  exit 0
fi

if [[ "$dry_run" == true ]]; then
  git show --stat --format='%H %s' HEAD >&2
  cat "$body" >&2
  printf 'state=dry-run\npull-request=\n' >> "$output"
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is not set}"
authorization="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
git -c "http.https://github.com/.extraheader=$authorization" push --quiet origin "HEAD:refs/heads/$branch"
pull_request="$(gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" --title "$title" --body-file "$body")"

# Pull requests opened with GITHUB_TOKEN start no workflow, so "Validate
# package registry" does not run here. This run validated this exact tree;
# record that as the required status (registry issue #21).
gh api --method POST "repos/$GITHUB_REPOSITORY/statuses/$head" \
  -f state=success -f context=required -f target_url="${SUBMISSION_RUN_URL:-}" \
  -f description="Validated by the package submission workflow" >/dev/null

if [[ "$outcome" == automatic ]]; then
  if gh pr merge "$pull_request" --repo "$GITHUB_REPOSITORY" --squash --match-head-commit "$head"; then
    printf 'state=merged\npull-request=%s\n' "$pull_request" >> "$output"
  else
    printf 'state=merge-failed\npull-request=%s\n' "$pull_request" >> "$output"
  fi
  exit 0
fi
printf 'state=opened\npull-request=%s\n' "$pull_request" >> "$output"
