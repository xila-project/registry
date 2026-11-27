#!/usr/bin/env bash
# Verify the public claim for the official namespace.
set -euo pipefail

url=https://www.xila.dev/.well-known/xila-namespace.txt
proof="$(mktemp)"
trap 'rm -f "$proof"' EXIT
if ! status="$(curl --fail --silent --show-error --proto '=https' \
  --max-filesize 128 --max-time 30 --retry 2 --retry-max-time 75 \
  --output "$proof" --write-out '%{http_code}' "$url")" \
  || [[ "$status" != 200 ]] || ! cmp -s "$proof" <(printf '%s\n' 'dev.xila:xila:47e8dc46df1a9b70219cf553aab96c80'); then
  printf 'Ownership proof for dev.xila is invalid at %s\n' "$url" >&2
  exit 1
fi
