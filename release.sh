#!/usr/bin/env bash
# release.sh — builds the Hark you sell: a signed, notarized Hark-<version>.dmg that a
# buyer can open and use without Homebrew, Terminal, or security warnings.
#
# What it does:
#   1. Builds whisper-cli from whisper.cpp source as one self-contained file (no
#      Homebrew libraries), with Metal on and CPU tuning off, so it runs on every
#      Apple Silicon Mac, not just this one.
#   2. Downloads uv (checksum checked). The app uses it on first launch to set up
#      the Read Aloud Python environment.
#   3. Builds Hark, puts both tools in Hark.app/Contents/MacOS, and sets the
#      HarkBundledTools key so the app looks for them there (see AppPaths.swift).
#   4. Signs everything with your Developer ID and the hardened runtime, sends the app
#      to Apple for notarization, staples the ticket, then does the same for the DMG.
#
# Usage:
#   HARK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   HARK_NOTARY_PROFILE="hark-notary" ./release.sh
#       HARK_NOTARY_PROFILE is the name you gave `xcrun notarytool store-credentials`.
#   ./release.sh --unsigned
#       Test build for this Mac only: ad-hoc signed (still with the hardened runtime),
#       not notarized. Other Macs will refuse to open it.
#
# Needs: Xcode Command Line Tools, cmake (brew install cmake), git, curl.
# Output: build/release/Hark-<version>.dmg (version comes from Resources/Info.plist).
set -euo pipefail
cd "$(dirname "$0")"

WHISPER_VERSION="1.9.5"
UV_VERSION="0.9.27"
UV_SHA256="1359538ed8664d172692cf4719ee0933a4a3bfb22fc91b0be1e19e7bdd8f5ef3"

MODE="signed"
case "${1:-}" in
  "") ;;
  --unsigned) MODE="unsigned" ;;
  *) echo "Unknown option: $1 (use --unsigned or nothing)" >&2; exit 2 ;;
esac

if [[ "$MODE" == "signed" ]]; then
  : "${HARK_SIGN_IDENTITY:?Set HARK_SIGN_IDENTITY to your \"Developer ID Application: …\" certificate name (see: security find-identity -v -p codesigning)}"
  : "${HARK_NOTARY_PROFILE:?Set HARK_NOTARY_PROFILE to the profile name you saved with: xcrun notarytool store-credentials}"
  IDENTITY="$HARK_SIGN_IDENTITY"
else
  IDENTITY="-"
fi
command -v cmake >/dev/null || { echo "cmake is missing. Install it with: brew install cmake" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
OUT="build/release"
TOOLS="$OUT/tools"
mkdir -p "$TOOLS"

# --- 1. whisper-cli, built once per version and kept in build/release/tools ---
WHISPER_BIN="$TOOLS/whisper-cli-$WHISPER_VERSION"
if [[ ! -x "$WHISPER_BIN" ]]; then
  SRC="$OUT/whisper.cpp-$WHISPER_VERSION"
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "v$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp.git "$SRC"
  # why each flag:
  #   BUILD_SHARED_LIBS=OFF       one file, no .dylib files to ship and sign
  #   GGML_METAL_EMBED_LIBRARY=ON the GPU code lives inside the binary, not in a side file
  #   GGML_NATIVE=OFF             don't tune for this Mac's chip, so it runs on an M1 too
  #   GGML_OPENMP=OFF             otherwise it may link Homebrew's libomp, which buyers don't have
  cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64
  cmake --build "$SRC/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"
  cp "$SRC/build/bin/whisper-cli" "$WHISPER_BIN"
fi
# why: a link to anything outside /usr/lib or /System would crash on a buyer's Mac.
if otool -L "$WHISPER_BIN" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
  echo "whisper-cli links a library buyers won't have (listed above)." >&2
  exit 1
fi

# --- 2. uv, downloaded once per version and checked against its published checksum ---
UV_BIN="$TOOLS/uv-$UV_VERSION"
if [[ ! -x "$UV_BIN" ]]; then
  TAR="$TOOLS/uv-$UV_VERSION.tar.gz"
  curl -fL --progress-bar -o "$TAR" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"
  echo "$UV_SHA256  $TAR" | shasum -a 256 -c - >/dev/null || { rm -f "$TAR"; echo "uv download failed its checksum" >&2; exit 1; }
  tar -xzf "$TAR" -C "$TOOLS" uv-aarch64-apple-darwin/uv
  mv "$TOOLS/uv-aarch64-apple-darwin/uv" "$UV_BIN"
  rmdir "$TOOLS/uv-aarch64-apple-darwin"
  rm "$TAR"
fi

# --- 3. Hark.app ---
swift build -c release --arch arm64
APP="$OUT/Hark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Hark "$APP/Contents/MacOS/Hark"
cp "$WHISPER_BIN" "$APP/Contents/MacOS/whisper-cli"
cp "$UV_BIN" "$APP/Contents/MacOS/uv"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :HarkBundledTools bool true" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/reader_helper.py Resources/reader-requirements.txt "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# --- 4. Sign: the two tools first, then the app (signing order matters: inside out) ---
SIGN=(codesign --force --options runtime --sign "$IDENTITY")
if [[ "$MODE" == "signed" ]]; then SIGN+=(--timestamp); fi
"${SIGN[@]}" "$APP/Contents/MacOS/whisper-cli"
"${SIGN[@]}" "$APP/Contents/MacOS/uv"
"${SIGN[@]}" --entitlements Resources/Hark.entitlements "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# Sends a file to Apple's notary service, waits for the answer, and staples the ticket.
notarize() {
  local file="$1" submit="$1"
  if [[ "$file" == *.app ]]; then
    # why: notarytool takes a zip, dmg, or pkg, not a bare .app folder.
    submit="$OUT/notarize-upload.zip"
    ditto -c -k --keepParent "$file" "$submit"
  fi
  xcrun notarytool submit "$submit" --keychain-profile "$HARK_NOTARY_PROFILE" --wait
  if [[ "$submit" != "$file" ]]; then rm "$submit"; fi
  xcrun stapler staple "$file"
}

if [[ "$MODE" == "signed" ]]; then
  notarize "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# --- 5. DMG with an Applications shortcut, so buyers drag Hark across to install ---
DMG="$OUT/Hark-$VERSION.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Hark.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hark $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
if [[ "$MODE" == "signed" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarize "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
echo "Built ($MODE): $DMG"
