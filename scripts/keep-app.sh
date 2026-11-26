#!/bin/bash
# Keeps the app just built in ~/Applications, where a disk cleaner won't take
# it for build output along with build/. The target's last build phase runs
# this, so a failed build leaves the last copy. Xcode signs the app after its
# phases, so the copy is signed here.
set -euo pipefail

built="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}"
kept="$HOME/Applications/$FULL_PRODUCT_NAME"
id() { /usr/bin/defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || true; }

# Only ever replace our own.
if [[ -e "$kept" && "$(id "$kept")" != "$(id "$built")" ]]; then
  echo "keep-app: $kept is some other app; leaving it" >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
swap="$(mktemp -d "$HOME/Applications/.Photon-keep.XXXXXX")"
trap 'rm -rf "$swap"' EXIT
/usr/bin/ditto "$built" "$swap/new.app"
/usr/bin/codesign --force --deep --sign - "$swap/new.app" 2>/dev/null

# Swapped whole, so a copy that's running keeps the files it has open.
[[ -e "$kept" ]] && mv "$kept" "$swap/old.app"
mv "$swap/new.app" "$kept"
