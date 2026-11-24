#!/usr/bin/env bash
# Read the fields of a "Submit a package" issue form.
#
# usage: tools/parse_submission_issue.sh <issue-event.json>
#   Prints archive-url, archive-sha256, publisher, public-key and author as
#   name=value lines (for $GITHUB_OUTPUT). The issue body is untrusted: each
#   value is the text under its form heading, with white space collapsed to
#   single spaces (so it holds no line break), at most 1024 characters.
#   "_No response_" (an optional field left empty) gives an empty value.
#   tools/submit.sh then checks every value against its rules.
set -euo pipefail

event="${1:?usage: parse_submission_issue.sh <issue-event.json>}"

field() { # <form heading>
  jq -r '.issue.body // ""' "$event" | tr -d '\r' | awk -v heading="### $1" '
    /^### / { inside = ($0 == heading); next }
    inside { print }
  ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | head -c 1024 | sed 's/^_No response_$//'
}

printf 'archive-url=%s\n' "$(field 'Archive URL')"
printf 'archive-sha256=%s\n' "$(field 'Archive SHA-256')"
printf 'publisher=%s\n' "$(field 'Publisher identifier')"
printf 'public-key=%s\n' "$(field 'Developer public key')"
printf 'author=%s\n' "$(field 'Author name')"
