#!/usr/bin/env bash
# Prove that every key and entry of a registry can be signed and verified.
#
# usage: tools/rehearse_signing.sh [registry-directory]
#   Signs a copy of keys/, namespaces/ (when present) and packages/ with throwaway root and repository keys
#   generated here, then verifies the result from the throwaway root public key
#   the way a device does: every file listed in the index and signed by the
#   repository key, with an authorized publisher for each entry. No real key or
#   secret is involved, so it runs on pull requests. Real signing is
#   tools/sign.sh, in the publication job only.
set -euo pipefail

root="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
builder="$(bash "$(dirname "${BASH_SOURCE[0]}")/xila-package.sh")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/registry"
cp -R "$root/keys" "$work/registry/"
for directory in namespaces packages; do
  if [[ -d "$root/$directory" ]]; then
    cp -R "$root/$directory" "$work/registry/"
  fi
done
mkdir -p "$work/registry/packages"

"$builder" key generate "$work/root.seed" "$work/root.pub" >/dev/null
"$builder" key generate "$work/repository.seed" "$work/repository.pub" >/dev/null
"$builder" registry root "$work/root.seed" test-root "$work/repository.pub" test-repository 1 \
  "$work/registry/root.json" >/dev/null
"$builder" registry sign "$work/registry" "$work/root.pub" "$work/repository.seed" "$work/site" \
  --expires-in-days 1 >/dev/null
"$builder" registry verify-signed "$work/site" "$work/root.pub"
