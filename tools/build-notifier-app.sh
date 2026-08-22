#!/bin/bash
#
# Builds the resident menu-bar .app that owns BetterSongify's notification
# endpoint and posts macOS notifications.
#
# UNUserNotificationCenter (the only notification API macOS 26 still honors)
# refuses to run outside a bundled, signed app, so this compiles main.swift into
# a minimal LSUIElement app. Ad-hoc signing is enough for a locally built app.
#
# Output: dist/BetterSongifyNotifier.app
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

APP_NAME="BetterSongifyNotifier"
# Notification and Automation approvals are keyed to this identity. Changing it
# merely to invalidate Notification Center's generic-icon cache was tested with
# .v2-.v5 and left notifications denied even after visible approval prompts.
BUNDLE_ID="io.bettersongify.notifier"
APP_DIR="$ROOT/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found — install Xcode Command Line Tools (xcode-select --install)" >&2
    exit 1
fi

# Keep Swift/Clang module caches out of a potentially unwritable home cache
# (notably constrained build environments). This is only compiler scratch data.
NOTIFIER_CACHE_ROOT="${TMPDIR:-/tmp}/better-songify-notifier-module-cache"
mkdir -p "$NOTIFIER_CACHE_ROOT/clang" "$NOTIFIER_CACHE_ROOT/swift"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$NOTIFIER_CACHE_ROOT/clang}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$NOTIFIER_CACHE_ROOT/swift}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BetterSongify</string>
    <key>CFBundleDisplayName</key>
    <string>BetterSongify</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>BSNotifierResident</key>
    <true/>
    <!-- Deliberately no CFBundleURLTypes. Waking this app from the injected
         script via a custom scheme was tried and does not work: Spotify's
         embedded Chromium does not implement external protocol handling, so
         iframe src, location.href, window.open and a synthesized anchor click
         all silently do nothing — with and without user activation — while the
         identical scheme launches fine from open(1). Spotify's launch shim,
         installed by install-macos.sh, is what starts this app instead. -->

    <key>CFBundleIconFile</key>
    <string>BetterSongify</string>
    <!-- Keep this even without actool: modern macOS looks for the named app
         icon first, while BetterSongify.icns remains the CLT fallback. -->
    <key>CFBundleIconName</key>
    <string>BetterSongify</string>
    <!-- Shown verbatim in the one-time macOS Automation prompt. Without this
         key the AppleEvents request fails outright on modern macOS, and with a
         vague one the user is asked to grant control of Spotify for no stated
         reason. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>BetterSongify reads the currently playing track from Spotify so it can show song-change notifications with the artist and album art.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# The native executable owns 127.0.0.1:17352 — nothing else belongs in
# Resources. An earlier socket-activated LaunchAgent architecture put a Node
# script here; verify-notifier-app.sh asserts it never comes back.
mkdir -p "$APP_DIR/Contents/Resources"

# App icon, so the notification and the permission prompts read as BetterSongify
# rather than a generic binary. Source is assets/icon-1024.png, pre-rendered
# from assets/icon.svg with headless Chrome and committed so this build stays
# dependency-free — every size here is a downscale, never an upscale.
ICON_WORK=$(mktemp -d)
ICONSET="$ICON_WORK/BetterSongify.iconset"
APPICONSET="$ICON_WORK/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET" "$APPICONSET" "$APP_DIR/Contents/Resources"
ICON_SRC="$ROOT/assets/icon-1024.png"

if [ -f "$ICON_SRC" ]; then
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
        size=${spec%% *}
        name=${spec##* }
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/$name.png" >/dev/null 2>&1
        cp "$ICONSET/$name.png" "$APPICONSET/$name.png"
    done

    # .icns: the classic icon, still used by Finder and older surfaces.
    # iconutil rejects sizes it does not recognise, so hand it only the
    # traditional slots.
    rm -f "$ICONSET/icon_256x256@2x.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/BetterSongify.icns" 2>/dev/null || \
        echo "warning: .icns build failed; falling back to the default icon" >&2

    # Asset catalog: what macOS actually consults for an app's icon in modern
    # surfaces — Notification Center included. A bundle carrying only a .icns
    # posts notifications with a BLANK icon on macOS 26, which is the whole
    # reason this step exists. Needs actool (full Xcode); with Command Line
    # Tools alone the app still works and simply falls back to the .icns.
    cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images": [
    { "idiom": "mac", "size": "16x16",   "scale": "1x", "filename": "icon_16x16.png" },
    { "idiom": "mac", "size": "16x16",   "scale": "2x", "filename": "icon_16x16@2x.png" },
    { "idiom": "mac", "size": "32x32",   "scale": "1x", "filename": "icon_32x32.png" },
    { "idiom": "mac", "size": "32x32",   "scale": "2x", "filename": "icon_32x32@2x.png" },
    { "idiom": "mac", "size": "128x128", "scale": "1x", "filename": "icon_128x128.png" },
    { "idiom": "mac", "size": "128x128", "scale": "2x", "filename": "icon_128x128@2x.png" },
    { "idiom": "mac", "size": "256x256", "scale": "1x", "filename": "icon_256x256.png" },
    { "idiom": "mac", "size": "256x256", "scale": "2x", "filename": "icon_256x256@2x.png" },
    { "idiom": "mac", "size": "512x512", "scale": "1x", "filename": "icon_512x512.png" },
    { "idiom": "mac", "size": "512x512", "scale": "2x", "filename": "icon_512x512@2x.png" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON

    if ACTOOL=$(xcrun --find actool 2>/dev/null) && [ -x "$ACTOOL" ]; then
        if "$ACTOOL" --compile "$APP_DIR/Contents/Resources" \
                --app-icon AppIcon \
                --platform macosx \
                --minimum-deployment-target 11.0 \
                --output-partial-info-plist "$ICON_WORK/partial.plist" \
                "$ICON_WORK/Assets.xcassets" >/dev/null 2>&1; then
            # actool reports the icon name to reference; without this key the
            # compiled catalog is ignored.
            ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$ICON_WORK/partial.plist" 2>/dev/null || echo "AppIcon")
            /usr/libexec/PlistBuddy -c "Set :CFBundleIconName $ICON_NAME" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
        else
            echo "warning: asset-catalog icon build failed; notifications may show a blank icon" >&2
        fi
    else
        echo "note: actool unavailable (needs full Xcode) — notifications may show a blank icon" >&2
    fi

    # actool may emit AppIcon.icns instead of the classic file name. Keep the
    # CFBundleIconFile fallback real as well as CFBundleIconName/AppIcon.
    if [ ! -f "$APP_DIR/Contents/Resources/BetterSongify.icns" ] && [ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]; then
        cp "$APP_DIR/Contents/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/BetterSongify.icns"
    fi

    rm -rf "$ICON_WORK"
fi

swiftc -O \
    -target arm64-apple-macos11 \
    -framework AppKit \
    -framework Network \
    -framework ServiceManagement \
    -framework UserNotifications \
    -Xlinker -needed_framework -Xlinker Network \
    -o "$MACOS_DIR/$APP_NAME" \
    "$SCRIPT_DIR/notifier-app/main.swift"

# Nested helper that can host the status item when ControlCenter has blocked
# this bundle identifier (see the menuBarHelperBundleID notes in
# notifier-app/main.swift). It is the same executable under its own identifier,
# so there is no second source of truth; the main app starts it with
# --menubar-helper and only when the menuBarUseHelper default is set.
HELPER_NAME="BetterSongifyMenuBar"
# Contents/Helpers, never Contents/Library/LoginItems: that path is scanned by
# Background Task Management, which would surface this helper as its own Login
# Items entry (and its own "Login Item Added" notice) even though the main app
# launches it directly and never registers it.
HELPER_DIR="$APP_DIR/Contents/Helpers/$HELPER_NAME.app"
mkdir -p "$HELPER_DIR/Contents/MacOS"
cat > "$HELPER_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BetterSongify</string>
    <key>CFBundleDisplayName</key>
    <string>BetterSongify</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID.menubar</string>
    <key>CFBundleExecutable</key>
    <string>$HELPER_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <!-- Deliberately no NSAppleEventsUsageDescription: the helper never reads
         Spotify. Doing so would raise a second Automation prompt under a second
         identity for the same product. -->
</dict>
</plist>
PLIST
cp "$MACOS_DIR/$APP_NAME" "$HELPER_DIR/Contents/MacOS/$HELPER_NAME"
if [ -f "$APP_DIR/Contents/Resources/BetterSongify.icns" ]; then
    mkdir -p "$HELPER_DIR/Contents/Resources"
    cp "$APP_DIR/Contents/Resources/BetterSongify.icns" "$HELPER_DIR/Contents/Resources/"
fi

# Ad-hoc is the whole signing story. UNUserNotificationCenter refuses to deliver
# from an unsigned bundle, so a signature is required — but it does not have to
# carry an identity, and a locally minted one buys nothing here.
#
# The build used to create a per-machine self-signed certificate in its own
# keychain and trust it (one login-password prompt), on the theory that macOS
# falls back to a bundle's com.apple.provenance origin — the terminal that ran
# the installer — when the signature carries no identity, mislabelling the menu
# bar row. Measured August 2026 against an ad-hoc install, that is not what
# happens: LaunchServices reports name/displayName "BetterSongify" for the
# bundle and the helper, Background Task Management registers the login item
# [enabled, allowed, notified], and no surface reads "Terminal".
#
# What the two visible rows — System Settings > Control Center's menu-bar list
# and Login Items — actually show is the **bundle's file name**
# ("BetterSongifyNotifier"), not CFBundleName/CFBundleDisplayName, which are
# already "BetterSongify". Signing does not change that string; it only fills in
# BTM's "Developer Name". So renaming the bundle is the lever for those rows,
# and the certificate was pure cost: a password prompt on every clean install,
# a keychain, and a trusted code-signing root to clean up on uninstall.
# install-macos.sh still removes all three from machines that ran the old build.
#
# Nested code must be signed before the container, or the outer seal covers a
# helper that is then re-signed and the app fails validation.
codesign --force --sign - "$HELPER_DIR" >/dev/null 2>&1
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1

echo "Built $APP_DIR"
