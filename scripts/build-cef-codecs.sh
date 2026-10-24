#!/usr/bin/env bash
# Builds the CEF framework with H.264 and AAC that fetch-cef.sh downloads, for
# the CEF version pinned there, and packs it as the cef-codecs-<version>
# release asset docs/releasing.md describes. The stock CEF builds leave those
# codecs out. It also applies Tiller's patches in cef-patches, which show
# Tiller's tabs to extensions and fix the Origin header of their requests. Needs an Apple Silicon Mac, Xcode with its Metal Toolchain
# (xcodebuild -downloadComponent MetalToolchain), about 150 GB free and
# several hours, and access to Google's servers, through a proxy in
# https_proxy if need be. A rerun picks up where the last one stopped.
# Usage: scripts/build-cef-codecs.sh [build-folder]  (default ~/cef-build)
set -euo pipefail

# CEF_VERSION's CEF commit and branch, from its name at cef-builds.spotifycdn.com.
CEF_COMMIT="14c5a08"
CEF_BRANCH="8037"
CEF_VERSION="$(sed -n 's/^CEF_VERSION="\(.*\)"$/\1/p' "$(dirname "$0")/fetch-cef.sh")"
ROOT="${1:-$HOME/cef-build}"
FRAMEWORK="Chromium Embedded Framework.framework"

mkdir -p "$ROOT"
cd "$ROOT"
[ -f automate-git.py ] || curl -fsSLO https://raw.githubusercontent.com/chromiumembedded/cef/master/tools/automate/automate-git.py

GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome" \
python3 automate-git.py --download-dir="$ROOT/code" --branch="$CEF_BRANCH" --checkout="$CEF_COMMIT" \
    --arm64-build --no-debug-build --no-distrib --with-pgo-profiles \
    --no-chromium-history --no-build

# Tiller's own changes, on top of CEF's: cef.patch to the cef folder and
# chromium.patch to Chromium's. A rerun skips one already applied.
SRC="$ROOT/code/chromium/src"
PATCHES="$(cd "$(dirname "$0")" && pwd)/cef-patches"
apply_patch() {
    if git -C "$1" apply --reverse --check "$2" 2>/dev/null; then
        echo "==> $(basename "$2") already applied"
    else
        git -C "$1" apply "$2"
    fi
}
apply_patch "$SRC/cef" "$PATCHES/cef.patch"
apply_patch "$SRC" "$PATCHES/chromium.patch"
PATH="$ROOT/code/depot_tools:$PATH" autoninja -C "$SRC/out/Release_GN_arm64" cefsimple

# The build's framework has a Versions folder; the stock download's, which
# the app expects, holds that version's files directly.
BUILT="$ROOT/code/chromium/src/out/Release_GN_arm64/$FRAMEWORK/Versions/A"
FOUND="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Resources/Info.plist")"
[ "$FOUND" = "$CEF_VERSION.0" ] || { echo "Built framework is $FOUND, not $CEF_VERSION." >&2; exit 1; }
rm -rf "$ROOT/stage"
mkdir -p "$ROOT/stage/$FRAMEWORK"
ditto "$BUILT" "$ROOT/stage/$FRAMEWORK"

OUT="$ROOT/cef-$CEF_VERSION-macosarm64-codecs.tar.zst"
tar -cf - -C "$ROOT/stage" "$FRAMEWORK" | zstd -19 -T0 -f -o "$OUT"
echo "==> $OUT"
shasum -a 256 "$OUT"
