#!/bin/zsh
# Builds Aether's Rust cores for Apple silicon and hands them to Swift:
# a static library and its C header in an xcframework, plus the generated
# Swift bindings in the DiffuseBridge target. Run it after any change under
# cores/ or to Proton's proton-diffuse crate.
set -euo pipefail

ROOT=${0:A:h:h}
KIT="$ROOT/Packages/AetherKit"
GEN="$ROOT/build/uniffi"
MANIFEST="$ROOT/cores/Cargo.toml"

# Whatever target directory Cargo is configured with (a shared cache, often).
TARGET_DIR=$(cargo metadata --manifest-path "$MANIFEST" --format-version 1 --no-deps \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')

TARGET=aarch64-apple-darwin
# C and assembly in dependencies (ring's crypto) aim at the app's macOS. Not
# MACOSX_DEPLOYMENT_TARGET: it reaches rustc's proc-macro dylibs too, and
# macOS 27's dyld refuses those ("mis-aligned LINKEDIT string pool").
export CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=26.0"
cargo build --manifest-path "$MANIFEST" --release -p aether-diffuse --target "$TARGET"
LIB="$TARGET_DIR/$TARGET/release/libaether_diffuse"

rm -rf "$GEN"
mkdir -p "$GEN/headers"
# The generator reads `cargo metadata` from the working directory.
(cd "$ROOT/cores" && cargo run --release -q -p uniffi-bindgen -- \
  generate --library "$LIB.dylib" --language swift --out-dir "$GEN")
mv "$GEN"/aether_diffuseFFI.h "$GEN/headers/"
mv "$GEN"/aether_diffuseFFI.modulemap "$GEN/headers/module.modulemap"

OUT="$KIT/Frameworks/AetherDiffuseFFI.xcframework"
rm -rf "$OUT"
mkdir -p "$KIT/Frameworks"
xcodebuild -create-xcframework -library "$LIB.a" -headers "$GEN/headers" -output "$OUT" >/dev/null

mkdir -p "$KIT/Sources/DiffuseBridge"
cp "$GEN/aether_diffuse.swift" "$KIT/Sources/DiffuseBridge/aether_diffuse.swift"
echo "cores: $(du -sh "$OUT" | cut -f1) xcframework, bindings in Sources/DiffuseBridge"
