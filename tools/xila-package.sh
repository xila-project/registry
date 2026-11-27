#!/usr/bin/env bash
# Print the path of xila-package at the pinned package_manager revision,
# installing it under .tools/ on first use. Set XILA_PACKAGE to reuse an
# existing binary: a local override that is not verified, because the
# workflows never set it.
#
# usage: tools/xila-package.sh [--verify <binary>]
#   --verify <binary> only checks <binary> against XILA_PACKAGE_SHA256.
#
# The installed binary is verified against XILA_PACKAGE_SHA256 before it is
# printed, so a cache entry that was planted or built differently fails the
# job before the binary runs (issue #24). Update the digest in the same commit
# as PACKAGE_MANAGER_REVISION, from a binary built by a trusted runner.
set -euo pipefail

# package_manager revision providing `xila-package registry check | sign | verify-signed`,
# registry entry format 2 (`xila_version`), developer key `kinds` (Wasm or
# native authorization) and namespace files for reverse-DNS identifiers.
PACKAGE_MANAGER_REVISION=75b7596768a3470d17f2104b2ca4255971d6e1ba

# SHA-256 of the xila-package binary installed from PACKAGE_MANAGER_REVISION
# with the runner image's Rust toolchain. The build is pinned by --locked and
# the pure-Rust dependency graph; the digest is recorded from a trusted runner
# build and is updated together with PACKAGE_MANAGER_REVISION (or when the
# runner image's Rust changes, which the mismatch reports).
XILA_PACKAGE_SHA256=1dbe553a83a62bf5ae832ef44e0b5f2845622a49551e4273251a5da1a13a2aeb

verify() { # <binary>: refuse a binary that is not the pinned one
  local file="$1" actual
  actual="$(sha256sum "$file" | cut -d ' ' -f 1)"
  if [[ "$actual" != "$XILA_PACKAGE_SHA256" ]]; then
    echo "xila-package digest mismatch for $file: expected $XILA_PACKAGE_SHA256, got $actual" >&2
    exit 1
  fi
}

if [[ "${1:-}" == "--verify" ]]; then
  [[ $# -eq 2 ]] || { echo "usage: xila-package.sh [--verify <binary>]" >&2; exit 1; }
  verify "$2"
  exit 0
fi
[[ $# -eq 0 ]] || { echo "usage: xila-package.sh [--verify <binary>]" >&2; exit 1; }

if [[ -n "${XILA_PACKAGE:-}" ]]; then
  echo "$XILA_PACKAGE"
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools="$root/.tools/xila-package-$PACKAGE_MANAGER_REVISION"
binary="$tools/bin/xila-package"
if [[ ! -x "$binary" ]]; then
  # Own target directory: a shared CARGO_TARGET_DIR/build.target-dir can hold
  # stale artifacts from other package_manager revisions.
  CARGO_TARGET_DIR="$root/.tools/target" cargo install --locked --quiet --root "$tools" \
    --git https://github.com/xila-project/package_manager --rev "$PACKAGE_MANAGER_REVISION" xila-package-builder >&2
fi
verify "$binary"
echo "$binary"
