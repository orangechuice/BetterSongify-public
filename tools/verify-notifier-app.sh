#!/bin/bash
# Static verification for the generated resident BetterSongifyNotifier bundle.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
APP="$ROOT/dist/BetterSongifyNotifier.app"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/BetterSongifyNotifier"
RESOURCES="$APP/Contents/Resources"

fail() { echo "verify-notifier: $1" >&2; exit 1; }

[ -d "$APP" ] || fail "bundle is missing; run npm run build:notifier first"
[ -x "$EXECUTABLE" ] || fail "executable is missing or not executable"
plutil -lint "$PLIST" >/dev/null || fail "Info.plist is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "io.bettersongify.notifier" ] || fail "bundle identifier changed"
[ "$(/usr/libexec/PlistBuddy -c 'Print :BSNotifierResident' "$PLIST")" = "true" ] || fail "resident capability marker is missing"
[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$PLIST")" ] || fail "CFBundleIconName is missing"
[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")" ] || fail "CFBundleIconFile is missing"
[ -f "$RESOURCES/BetterSongify.icns" ] || fail "CFBundleIconFile fallback resource is missing"
[ ! -e "$RESOURCES/notifier.js" ] || fail "legacy notifier.js was packaged"
[ ! -e "$RESOURCES/notifier-launch.sh" ] || fail "legacy notifier-launch.sh was packaged"
codesign --verify --deep --strict "$APP" >/dev/null || fail "code signature verification failed"
LINKS=$(otool -L "$EXECUTABLE")
grep -q -- '-framework Network' "$SCRIPT_DIR/build-notifier-app.sh" || fail "build script no longer explicitly links Network.framework"
for framework in AppKit ServiceManagement UserNotifications; do
    echo "$LINKS" | grep -q "/$framework.framework/" || fail "$framework.framework is not linked"
done
# Swift's Network overlay emits libswiftNetwork rather than a direct framework
# load command on current Xcode toolchains; accept either while still requiring
# the build script's explicit -framework Network above.
echo "$LINKS" | grep -Eq '/Network\.framework/|/libswiftNetwork\.dylib' || fail "Network framework/Swift overlay is not linked"

echo "verify-notifier: plist, executable, icons, signature, bundle ID, and framework links passed"
