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
# job before the binary runs (issue #24). Only the final binary is cached
# (the workflows cache .tools/xila-package): the build never writes into the
# cached directory, and any residue in .tools/ is removed before building, so
# a planted cache entry cannot run build scripts before the digest check.
# Update the digest in the same commit as PACKAGE_MANAGER_REVISION, from a
# binary built by a trusted runner.
set -euo pipefail

# package_manager revision providing `xila-package registry check | sign | verify-signed`,
# registry entry format 2 (`xila_version`), developer key `kinds` (Wasm or
# native authorization) and namespace files for reverse-DNS identifiers.
PACKAGE_MANAGER_REVISION=75b7596768a3470d17f2104b2ca4255971d6e1ba

# SHA-256 of the xila-package binary built from PACKAGE_MANAGER_REVISION with
# RUST_VERSION for BUILD_TARGET below: static musl, no incremental
# compilation, remapped Cargo home and build directory, so the digest does not
# depend on the runner image.
XILA_PACKAGE_SHA256=b67cdfec1872a87c64dd4f4cf80e02dff1c18056f14ef7d8b02746d3128d3da9

# One Rust version for every Xila repository; keep in sync with the
# rust_version variable of xila-project/workspace mise/shared.toml. The CI jobs
# install it with mise (mise.toml) before this script runs.
RUST_VERSION=1.97.0

# Static musl build: no host gcc, glibc or dynamic loader objects, so the
# binary runs on every Linux runner and its bytes do not depend on the image.
BUILD_TARGET=x86_64-unknown-linux-musl

verify() { # <binary>: refuse anything but the pinned executable regular file
  local file="$1" actual
  if [[ ! -f "$file" || -L "$file" || ! -x "$file" ]]; then
    echo "xila-package is not an executable regular file: $file" >&2
    exit 1
  fi
  actual="$(sha256sum -- "$file" | cut -d ' ' -f 1)"
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
tools="$root/.tools"
binary="$tools/xila-package"
# Build only when the path does not exist at all: a planted non-executable
# file or symlink skips the build and fails in verify below.
if [[ ! -e "$binary" && ! -L "$binary" ]]; then
  cargo_version="$(cargo --version | cut -d ' ' -f 2)"
  if [[ "$cargo_version" != "$RUST_VERSION" ]]; then
    echo "xila-package must be built with Rust $RUST_VERSION, but cargo reports $cargo_version; run 'mise install' first" >&2
    exit 1
  fi
  if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed | grep -qx "$BUILD_TARGET"; then
      rustup target add "$BUILD_TARGET" >&2
    fi
  fi
  # Remove any residue of a cache entry, then build outside the cached
  # directory, in a fresh temporary directory that is removed on exit.
  rm -rf "$tools"
  temporary_directory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  build="$(mktemp -d "${temporary_directory%/}/xila-package.XXXXXX")"
  trap 'rm -rf "$build"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  CARGO_INCREMENTAL=0 \
  CARGO_TARGET_DIR="$build/target" \
  RUSTFLAGS="--remap-path-prefix=$cargo_home=/cargo --remap-path-prefix=$build=/build" \
    cargo install --locked --quiet --target "$BUILD_TARGET" --root "$build/root" \
    --git https://github.com/xila-project/package_manager --rev "$PACKAGE_MANAGER_REVISION" xila-package-builder >&2
  mkdir -p "$tools"
  cp "$build/root/bin/xila-package" "$binary"
fi
verify "$binary"
echo "$binary"
