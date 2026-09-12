#!/usr/bin/env bash
# Build laned-core and regenerate its Swift bindings into swift/MaxPaneCore.
#
# uniffi generates three files from the built dylib: the Swift API, a C header,
# and a modulemap. The header and modulemap become the `LanedCoreFFI` system
# target; the Swift file becomes `LanedCore`. Re-run after any change to a
# `#[uniffi::export]` signature.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

PROFILE="${1:-release}"
CARGO_FLAG=""
[ "$PROFILE" = "release" ] && CARGO_FLAG="--release"

cargo build $CARGO_FLAG -p laned-core

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cargo run $CARGO_FLAG --bin uniffi-bindgen -- generate \
  --library "target/$PROFILE/liblaned_core.dylib" \
  --language swift --out-dir "$OUT"

PKG="swift/MaxPaneCore/Sources"
rm -rf "$PKG/laned_coreFFI"
mkdir -p "$PKG/laned_coreFFI/include" "$PKG/LanedCore"
cp "$OUT/laned_coreFFI.h" "$PKG/laned_coreFFI/include/"
cp "$OUT/laned_core.swift" "$PKG/LanedCore/"

# The module MUST be named laned_coreFFI: the generated Swift does
# `#if canImport(laned_coreFFI)`, and a different name silently compiles the
# bindings with no FFI symbols at all. SwiftPM requires the target name to match,
# so the target is named laned_coreFFI too.
cp "$OUT/laned_coreFFI.modulemap" "$PKG/laned_coreFFI/include/module.modulemap"

echo "bindings regenerated into $PKG (profile: $PROFILE)"
