#!/bin/bash
set -euo pipefail

# PolarAligner complete build script
# Builds Rust core → generates UniFFI bindings → copies to Swift package → builds Xcode project

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/polar-core/polar-core"
POLAR_CORE_PKG="$SCRIPT_DIR/PolarCore"
XCODE_PROJECT="$SCRIPT_DIR/PolarAligner/PolarAligner.xcodeproj"

# Find Rust toolchain
if command -v cargo &>/dev/null; then
    CARGO=cargo
elif [ -f "$HOME/.cargo/bin/cargo" ]; then
    CARGO="$HOME/.cargo/bin/cargo"
elif [ -f "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo" ]; then
    export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
    CARGO=cargo
else
    echo "Error: cargo not found. Install Rust: https://rustup.rs"
    exit 1
fi

CONFIGURATION="${1:-Debug}"
echo "=== PolarAligner Build (${CONFIGURATION}) ==="

# Step 1: Build Rust library
echo ""
echo "--- [1/4] Building Rust core library ---"
$CARGO build --release --manifest-path "$RUST_DIR/Cargo.toml"
echo "  ✓ Rust library built"

# Step 2: Generate UniFFI Swift bindings
echo ""
echo "--- [2/4] Generating UniFFI Swift bindings ---"
UNIFFI_OUT=$(mktemp -d)
$CARGO run --release --manifest-path "$RUST_DIR/Cargo.toml" \
    --features=uniffi/cli --bin uniffi-bindgen \
    generate --library "$SCRIPT_DIR/polar-core/target/release/libpolar_core.a" \
    --language swift --out-dir "$UNIFFI_OUT"
echo "  ✓ Bindings generated"

# Step 3: Copy artifacts to PolarCore Swift package
echo ""
echo "--- [3/4] Copying artifacts to PolarCore package ---"
cp "$UNIFFI_OUT/polar_core.swift" "$POLAR_CORE_PKG/Sources/PolarCore/polar_core.swift"
cp "$UNIFFI_OUT/polar_coreFFI.h" "$POLAR_CORE_PKG/Sources/PolarCore/polar_coreFFI.h"
cp "$UNIFFI_OUT/polar_coreFFI.h" "$POLAR_CORE_PKG/Sources/PolarCoreFFI/include/polar_coreFFI.h"
cp "$SCRIPT_DIR/polar-core/target/release/libpolar_core.a" "$POLAR_CORE_PKG/libpolar_core.a"
rm -rf "$UNIFFI_OUT"
echo "  ✓ libpolar_core.a + Swift bindings copied"

# Step 4: Build Xcode project
echo ""
echo "--- [4/4] Building Xcode project ---"
xcodebuild -project "$XCODE_PROJECT" -scheme PolarAligner \
    -configuration "$CONFIGURATION" build 2>&1 | \
    grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

echo ""
echo "=== Build complete ==="
