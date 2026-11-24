#!/usr/bin/env bash
# Prepare the registry change for one released package archive.
#
# usage: tools/submit.sh <work-directory> [--archive <file>]
#   Reads the submission from environment variables. Their values are
#   untrusted (they come from an issue form): this script only compares them
#   with fixed patterns and passes them as arguments, never as code.
#
#   SUBMISSION_ARCHIVE_URL     HTTPS URL of the released .xpk (required)
#   SUBMISSION_ARCHIVE_SHA256  SHA-256 of the archive, or HTTPS URL of its
#                              .sha256 file (optional)
#   SUBMISSION_PUBLISHER       developer key identifier (required)
#   SUBMISSION_PUBLIC_KEY      base64 raw Ed25519 public key (new publishers)
#   SUBMISSION_AUTHOR          author name (new publishers)
#   SUBMISSION_SUBMITTER       GitHub account that submitted (from GitHub,
#                              not from the form; used for io.github.<account>)
#
#   --archive <file> uses a local copy of the archive instead of downloading
#   it (tests). The entry still records SUBMISSION_ARCHIVE_URL.
#
# The registry checkout must be clean. On success the new files are in the
# checkout (not committed) and copied to <work-directory>/files/. The script
# writes <work-directory>/result.json in every case where it reaches a
# decision:
#   outcome     automatic | review | duplicate | invalid
#   message     one-line explanation
#   identifier, version, entry, publisher, files[], reasons[] (when known)
# Outcome "automatic" means that the conditions for an automatic merge hold
# (issue #21); "review" means that a maintainer must review the pull request.
# Exit status: 0 for automatic or review, 1 for duplicate or invalid. Other
# failures (for example no network to install xila-package) exit without
# result.json.
#
# The archive is only parsed and verified by xila-package; nothing from it is
# built or executed.
set -euo pipefail

work="${1:?usage: submit.sh <work-directory> [--archive <file>]}"
shift
local_archive=""
if [[ $# -ge 2 && "$1" == "--archive" ]]; then
  local_archive="$2"
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
rm -rf "$work/files" "$work/download" "$work/result.json" "$work/entry.json" "$work/entry.error" \
  "$work/publisher.pub" "$work/validate.log"
mkdir -p "$work/files" "$work/download"

url="${SUBMISSION_ARCHIVE_URL:-}"
digest="${SUBMISSION_ARCHIVE_SHA256:-}"
publisher="${SUBMISSION_PUBLISHER:-}"
public_key="${SUBMISSION_PUBLIC_KEY:-}"
author="${SUBMISSION_AUTHOR:-}"
submitter="${SUBMISSION_SUBMITTER:-}"

identifier="" version="" entry=""
added=()
reasons=()

# finish <outcome> <message>: write result.json and exit.
finish() {
  local files_json reasons_json
  files_json="$(printf '%s\n' "${added[@]+"${added[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')"
  reasons_json="$(printf '%s\n' "${reasons[@]+"${reasons[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')"
  jq -n --arg outcome "$1" --arg message "$2" --arg identifier "$identifier" --arg version "$version" \
    --arg entry "$entry" --arg publisher "$publisher" --argjson files "$files_json" --argjson reasons "$reasons_json" \
    '{outcome: $outcome, message: $message, identifier: $identifier, version: $version, entry: $entry,
      publisher: $publisher, files: $files, reasons: $reasons}' > "$work/result.json"
  printf '%s: %s\n' "$1" "$2" >&2
  case "$1" in automatic | review) exit 0 ;; *) exit 1 ;; esac
}
refuse() { finish invalid "$1"; }

# ---- Input rules --------------------------------------------------------------

# check_url <value> <suffix>: HTTPS URL with a host name, no user information,
# port, query, fragment, "." or ".." segment, ending with <suffix>.
check_url() {
  local value="$1" suffix="$2" host path
  [[ ${#value} -le 256 ]] || return 1
  [[ "$value" =~ ^https://([a-z0-9.-]+)(/[A-Za-z0-9._~%+/-]*)$ ]] || return 1
  host="${BASH_REMATCH[1]}" path="${BASH_REMATCH[2]}"
  [[ "$host" == *.* && "$host" != *..* && "$host" != .* && "$host" != *. ]] || return 1
  # No IP address and no local name.
  [[ ! "$host" =~ ^[0-9.]+$ && "$host" != localhost && "$host" != *.localhost && "$host" != *.local ]] || return 1
  [[ "/$path/" != */./* && "/$path/" != */../* && "$path" != *//* ]] || return 1
  [[ "$path" == *"$suffix" && ${#path} -gt $((${#suffix} + 1)) ]] || return 1
}

[[ "$(git status --porcelain)" == "" ]] || { echo "the registry checkout has uncommitted changes" >&2; exit 2; }

check_url "$url" .xpk \
  || refuse "the archive URL must be an HTTPS URL of at most 256 characters with a host name, no port, query or fragment, ending with .xpk"
[[ ${#publisher} -le 64 && "$publisher" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || refuse "the publisher identifier must be lowercase letters, digits and hyphens (at most 64 characters, no hyphen at the start or end)"
expected_digest=""
if [[ -n "$digest" ]]; then
  if [[ "$digest" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    expected_digest="${digest,,}"
  elif ! check_url "$digest" .sha256; then
    refuse "the SHA-256 must be 64 hexadecimal digits or an HTTPS URL that ends with .sha256"
  fi
fi
if [[ -n "$public_key" && ! "$public_key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
  refuse "the public key must be the base64 form of a raw 32-byte Ed25519 key (44 characters, ending with =)"
fi
if [[ -n "$author" ]]; then
  [[ ${#author} -le 128 && ! "$author" =~ [[:cntrl:]\`\<\>] ]] \
    || refuse "the author name must have at most 128 characters, without control characters, backticks or angle brackets"
fi
if [[ -n "$submitter" && ! "$submitter" =~ ^[A-Za-z0-9-]{1,39}$ ]]; then
  refuse "the submitter is not a GitHub account name"
fi

# ---- Download -------------------------------------------------------------------

# HTTPS only, including redirects, with bounded redirects, size and time, as
# tools/validate.sh.
download() { # <url> <output> <maximum bytes>
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --max-redirs 5 --max-filesize "$3" --max-time 120 --retry 3 --output "$2" "$1"
}
archive="$work/download/archive.xpk"
if [[ -n "$local_archive" ]]; then
  cp "$local_archive" "$archive"
elif ! download "$url" "$archive" 16777216 2>"$work/download/error"; then
  refuse "the archive download failed (HTTPS only, at most 16 MiB and 120 seconds): $(head -c 300 "$work/download/error" | tr -d '\r\n')"
fi
[[ "$(stat -c %s "$archive")" -le 16777216 ]] || refuse "the archive is larger than 16 MiB"
actual_digest="$(sha256sum "$archive" | cut -d ' ' -f 1)"
if [[ -n "$digest" && -z "$expected_digest" ]]; then
  download "$digest" "$work/download/archive.sha256" 4096 2>"$work/download/error" \
    || refuse "the .sha256 download failed: $(head -c 300 "$work/download/error" | tr -d '\r\n')"
  expected_digest="$(head -c 4096 "$work/download/archive.sha256" | tr -d '\r' | head -n 1 | cut -d ' ' -f 1)"
  [[ "$expected_digest" =~ ^[0-9A-Fa-f]{64}$ ]] || refuse "the .sha256 file does not start with a SHA-256 digest"
  expected_digest="${expected_digest,,}"
fi
if [[ -n "$expected_digest" && "$expected_digest" != "$actual_digest" ]]; then
  refuse "the archive SHA-256 is $actual_digest, not the given $expected_digest"
fi

# ---- Developer key ----------------------------------------------------------------

key_file="keys/developers/$publisher.json"
if [[ -f "$key_file" ]]; then
  registered_key="$(jq -er '.public_key' "$key_file")"
  if [[ -n "$public_key" && "$public_key" != "$registered_key" ]]; then
    refuse "the public key differs from the registered key of $publisher; a key change needs a manual pull request"
  fi
  public_key="$registered_key"
else
  [[ -n "$public_key" && -n "$author" ]] \
    || refuse "$publisher is not a registered publisher: give its public key and author name, or use the identifier of a registered developer key"
  for other in keys/developers/*.json; do
    [[ -e "$other" ]] || continue
    if [[ "$(jq -r '.public_key' "$other")" == "$public_key" ]]; then
      refuse "this public key is already registered as $(basename "$other" .json)"
    fi
  done
  # A new key may publish Wasm only and has no legacy xila grant: a maintainer
  # grants native or the legacy namespace in a reviewed change.
  jq -n --arg id "$publisher" --arg author "$author" --arg key "$public_key" \
    '{id: $id, author: $author, algorithm: "ed25519", public_key: $key, kinds: ["wasm"]}' > "$key_file"
  added+=("$key_file")
  reasons+=("new publisher $publisher: a maintainer reviews the developer key")
fi
printf '%s' "$public_key" | base64 --decode > "$work/publisher.pub"

# ---- Entry --------------------------------------------------------------------------

builder="$(bash tools/xila-package.sh)"
if ! "$builder" registry entry "$archive" "$work/publisher.pub" "$publisher" "$url" "$work/entry.json" \
  2>"$work/entry.error"; then
  refuse "xila-package could not generate the entry (the archive must be a valid package signed by the key of $publisher): $(head -c 500 "$work/entry.error" | tr -d '\r' | tr '\n' ' ')"
fi
identifier="$(jq -r '.name' "$work/entry.json")"
version="$(jq -r '.version' "$work/entry.json")"
# xila-package enforces the schemas; check again before building a path.
[[ "$identifier" =~ ^[a-z0-9_-]+(\.[a-z0-9_-]+)+$ && ${#identifier} -le 96 ]] || { identifier=""; refuse "unexpected package identifier"; }
[[ "$version" =~ ^[A-Za-z0-9+-]+(\.[A-Za-z0-9+-]+)*$ && ${#version} -le 64 ]] || { version=""; refuse "unexpected package version"; }
entry="packages/${identifier//.//}/$version.json"
if git cat-file -e "HEAD:$entry" 2>/dev/null; then
  finish duplicate "$identifier $version is already in the registry ($entry); published versions are immutable, release a new version instead"
fi
mkdir -p "$(dirname "$entry")"
cp "$work/entry.json" "$entry"
added+=("$entry")

# ---- Namespace --------------------------------------------------------------------

covered=false
if [[ "$identifier" =~ ^xila\.[^.]+$ ]]; then
  covered=true # Legacy grant in the key file, checked by xila-package.
else
  IFS=. read -r -a components <<< "$identifier"
  prefix="${components[0]}"
  for ((index = 1; index < ${#components[@]} - 1; index++)); do
    prefix+=".${components[index]}"
    if [[ -f "namespaces/$prefix.json" ]]; then covered=true; fi
  done
fi
if [[ "$covered" == false ]]; then
  account="${submitter,,}"
  if [[ -n "$account" && "$identifier" == "io.github.$account."* ]]; then
    # The GitHub account that submitted owns io.github.<account>.
    namespace_file="namespaces/io.github.$account.json"
    mkdir -p namespaces
    jq -n --arg namespace "io.github.$account" --arg account "$account" --arg key "$publisher" \
      '{format_version: 1, namespace: $namespace, owner: {kind: "github", name: $account}, developer_keys: [$key]}' \
      > "$namespace_file"
    added+=("$namespace_file")
    reasons+=("new namespace io.github.$account for the account that submitted")
  else
    refuse "no namespace file covers $identifier: claim its namespace with a manual pull request first (see the README), or use io.github.<your account>"
  fi
fi

# ---- Validation -------------------------------------------------------------------

for file in "${added[@]}"; do
  mkdir -p "$work/files/$(dirname "$file")"
  cp "$file" "$work/files/$file"
done
if ! bash tools/validate.sh >"$work/validate.log" 2>&1; then
  tail -n 40 "$work/validate.log" >&2
  refuse "registry validation failed: $(grep -v '^ok\|^Built' "$work/validate.log" | tail -n 3 | tr -d '\r' | tr '\n' ' ' | head -c 600)"
fi

# ---- Automatic merge conditions (issue #21) ------------------------------------------

if [[ ${#added[@]} -ne 1 ]]; then
  reasons+=("the submission adds a developer key or a namespace file")
fi
source_url="$(jq -r '.metadata.source // ""' "$entry")"
if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/[^/]+/[^/]+$ ]]; then
  repository="${BASH_REMATCH[1],,}/${BASH_REMATCH[2],,}"
  source_lower="${source_url,,}"
  source_lower="${source_lower%.git}"
  if [[ "$source_lower" != "https://github.com/$repository" && "$source_lower" != "https://github.com/$repository/"* ]]; then
    reasons+=("the archive is not a release asset of the source repository that the package names (${source_url:-none})")
  fi
else
  reasons+=("the archive URL is not a GitHub release asset")
fi

if [[ ${#reasons[@]} -eq 0 ]]; then
  finish automatic "$identifier $version is valid and meets the conditions for an automatic merge"
fi
finish review "$identifier $version is valid and waits for a maintainer review"
