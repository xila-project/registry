#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks in the printf formats are Markdown.
# Write the Markdown report of a package submission.
#
# usage: tools/report_submission.sh <submission-directory> <report-file>
#   <submission-directory> holds result.json and submit.log from
#   tools/submit.sh; both may be missing after an unexpected failure.
#   Prints the action for the issue on standard output: close-completed,
#   close-not-planned or keep-open. Exits 1 when the submission was not
#   accepted, so that the workflow run shows the failure.
#
# Environment (set by the workflow, trusted):
#   PROPOSE_STATE     state from tools/propose_submission.sh, or empty
#   PULL_REQUEST      pull request URL, or empty
#   PUBLISH_RESULT    result of the publication job (success, failure,
#                     cancelled, skipped), or empty
#   SUBMISSION_RUN_URL  URL of the workflow run
#
# Messages and logs quote untrusted text (URLs, archive fields, download
# errors). They are written inside a code block without backticks and
# truncated, so they cannot add links, mentions or formatting.
set -euo pipefail

submission="${1:?usage: report_submission.sh <submission-directory> <report-file>}"
report="${2:?usage: report_submission.sh <submission-directory> <report-file>}"
state="${PROPOSE_STATE:-}"
pull_request="${PULL_REQUEST:-}"
publish="${PUBLISH_RESULT:-}"
run="${SUBMISSION_RUN_URL:-}"

outcome="error"
if [[ -f "$submission/result.json" ]]; then
  outcome="$(jq -r '.outcome' "$submission/result.json")"
fi
quote() { # <file or text on standard input>
  printf '```text\n'
  tr -d '`\r' | head -n 60 | cut -c 1-300
  printf '```\n'
}
details() {
  if [[ -f "$submission/result.json" ]]; then
    { jq -r '.message' "$submission/result.json"; jq -r '.reasons[]' "$submission/result.json"; } | quote
  fi
}

action=keep-open
status=0
{
  case "$outcome" in
    automatic | review)
      case "$state" in
        merged)
          if [[ "$publish" == success ]]; then
            printf 'Published: %s merged automatically and the registry is signed and deployed.\n\n' "$pull_request"
          else
            printf 'Merged automatically in %s. The publication job ended with result `%s`; the next publication (each push to `main` and every week) will publish it.\n\n' "$pull_request" "${publish:-unknown}"
          fi
          action=close-completed
          ;;
        merge-failed)
          printf 'Validated, but the automatic merge failed. %s waits for a maintainer.\n\n' "$pull_request"
          ;;
        opened)
          printf 'Validated. %s waits for a maintainer review because:\n\n' "$pull_request"
          ;;
        pending)
          printf 'A submission of this version is already in progress: %s\n\n' "${pull_request:-the submission branch exists without an open pull request; a maintainer must delete it}"
          ;;
        dry-run)
          printf 'Dry run: the submission is valid (outcome `%s`). Nothing was pushed.\n\n' "$outcome"
          ;;
        *)
          printf 'Validated, but the pull request could not be opened. A maintainer will look at the run.\n\n'
          status=1
          ;;
      esac
      details
      ;;
    duplicate)
      printf 'This version is already in the registry. Published versions are immutable: release a new version and submit it.\n\n'
      details
      action=close-not-planned
      status=1
      ;;
    invalid)
      printf 'The submission was refused. Correct the issue description to submit it again.\n\n'
      details
      if [[ -s "$submission/submit.log" ]]; then
        printf '\nLast lines of the log:\n\n'
        tail -n 40 "$submission/submit.log" | quote
      fi
      status=1
      ;;
    *)
      printf 'The submission workflow failed before it reached a decision. A maintainer will look at the run.\n\n'
      status=1
      ;;
  esac
  printf '\n[Workflow run](%s)\n' "$run"
} > "$report"

echo "$action"
exit "$status"
