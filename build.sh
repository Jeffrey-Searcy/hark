#!/usr/bin/env bash
# build.sh — compiles Hark in release mode, wraps it in Hark.app,
# ad-hoc signs it, and installs it to ~/Applications so Spotlight can launch it.
# Note: ad-hoc signing means macOS treats every rebuild as a new app, so the
# mic / system-audio / Accessibility permissions must be granted again after each rebuild.
# This is the developer build: whisper-cli and uv come from Homebrew. Missing model files
# or a missing Read Aloud environment are fetched by the app's setup window on launch
# (or by ./Resources/setup-reader.sh for Read Aloud). For the build you sell, see release.sh.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Hark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Hark "$APP/Contents/MacOS/Hark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/reader_helper.py "$APP/Contents/Resources/reader_helper.py"
cp Resources/reader-requirements.txt "$APP/Contents/Resources/reader-requirements.txt"
codesign --force --sign - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Hark.app"
cp -R "$APP" "$HOME/Applications/Hark.app"
echo "Installed: $HOME/Applications/Hark.app"
