#!/bin/bash
#
#
# BetterSongify local installer for macOS.
# Builds this repository and installs dist/BetterSongify.js into Spotify.app.
#
# Usage:
#   ./install-macos.sh            interactive menu
#   ./install-macos.sh install    build and install or update
#   ./install-macos.sh reinstall  remove completely, then build and install fresh
#   ./install-macos.sh remove     remove completely
#
# Install and reinstall include the notifier companion (BetterSongifyNotifier.app:
# macOS song-change notifications and the menu-bar song) unless given
# --no-notifier, which installs only the script inside Spotify and removes a
# companion left by an earlier full install. The interactive menu asks.
#
set -euo pipefail

CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; GRAY=$'\033[90m'; RESET=$'\033[0m'

info()    { echo " ${CYAN}[i]${RESET} $1"; }
success() { echo " ${GREEN}[✓]${RESET} $1"; }
warn()    { echo " ${YELLOW}[!]${RESET} $1"; }
error()   { echo " ${RED}[×]${RESET} $1"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_FILE="$SCRIPT_DIR/dist/BetterSongify.js"
SCRIPT_TAG='<script src="BetterSongify.js"></script>'
# Legacy injections (BetterSpotify, SpotifyLyrics); scrubbed on install/remove
LEGACY_SCRIPT_TAG_1='<script src="BetterSpotify.js"></script>'
LEGACY_SCRIPT_TAG_2='<script src="SpotifyLyrics.js"></script>'

logo() {
    echo "${CYAN} ____       _   _            ____                    _  __       ${RESET}"
    echo "${CYAN}| __ )  ___| |_| |_ ___ _ __/ ___|  ___  _ __   __ _(_)/ _|_   _ ${RESET}"
    echo "${CYAN}|  _ \\ / _ \\ __| __/ _ \\ '__\\___ \\ / _ \\| '_ \\ / _\` | | |_| | | |${RESET}"
    echo "${CYAN}| |_) |  __/ |_| ||  __/ |   ___) | (_) | | | | (_| | |  _| |_| |${RESET}"
    echo "${CYAN}|____/ \\___|\\__|\\__\\___|_|  |____/ \\___/|_| |_|\\__, |_|_|  \\__, |${RESET}"
    echo "${CYAN}                                               |___/       |___/ ${RESET}"
    echo ""
    echo "${GRAY} BetterSongify Local Installer for macOS ${RESET}"
    echo "${GRAY}---------------------------------------------------${RESET}"
}

find_spotify() {
    local candidates=("/Applications/Spotify.app" "$HOME/Applications/Spotify.app")
    for app in "${candidates[@]}"; do
        if [ -e "$app/Contents/Resources/Apps/xpui.spa" ]; then
            echo "$app"
            return 0
        fi
    done

    local found
    found=$(mdfind "kMDItemCFBundleIdentifier == 'com.spotify.client'" 2>/dev/null | head -n 1 || true)
    if [ -n "$found" ] && [ -e "$found/Contents/Resources/Apps/xpui.spa" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

build_bundle() {
    info "Building local BetterSongify bundle..."
    if ! command -v npm >/dev/null 2>&1; then
        error "npm was not found. Install Node.js/npm first."
        exit 1
    fi

    # Desktop target only: the macOS install never touches dist/chrome/. Without
    # the companion the bundle is built to match, so its panel offers no
    # menu-bar toggle and song changes go straight to the in-app toast.
    if [ "$WITH_NOTIFIER" = true ]; then
        (cd "$SCRIPT_DIR" && npm run build:desktop)
    else
        (cd "$SCRIPT_DIR" && npm run build:desktop -- --no-notifier)
    fi

    if [ ! -f "$BUNDLE_FILE" ]; then
        error "Build did not produce $BUNDLE_FILE"
        exit 1
    fi

    success "Built $BUNDLE_FILE"
}

get_better_songify_js() {
    local dest="$1"
    build_bundle
    info "Using local built bundle: dist/BetterSongify.js"
    cp "$BUNDLE_FILE" "$dest"
}

quit_spotify() {
    # Reinstall runs both the removal and installation phases, so this message appears twice.
    info "Stopping Spotify to unlock core files..."
    osascript -e 'quit app "Spotify"' >/dev/null 2>&1 || true
    sleep 2
    pkill -x Spotify 2>/dev/null || true
}

# --- Resident song-change notifier -------------------------------------------
#
# Real macOS notifications cannot be posted from inside Spotify's renderer (its
# Notification permission can never be granted), so the injected script POSTs to
# BetterSongifyNotifier.app. The resident menu-bar app owns 127.0.0.1:17352 and
# shows authoritative Spotify playback state even while Spotify is closed.

NOTIFIER_LABEL="io.bettersongify.notifier"
# ~/Applications, not Application Support: LaunchServices only treats standard
# application directories as app locations, and Notification Center resolves a
# notification's icon through LaunchServices — an app installed outside one
# posts notifications with a blank icon.
NOTIFIER_APPS_DIR="$HOME/Applications"
NOTIFIER_APP="$NOTIFIER_APPS_DIR/BetterSongifyNotifier.app"
NOTIFIER_LEGACY_SUPPORT="$HOME/Library/Application Support/BetterSongify"
NOTIFIER_PLIST="$HOME/Library/LaunchAgents/$NOTIFIER_LABEL.plist"
NOTIFIER_PORT=17352
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

unload_notifier_agent() {
    launchctl bootout "gui/$UID/$NOTIFIER_LABEL" 2>/dev/null || true
}

installed_notifier_is_resident() {
    [ -f "$NOTIFIER_APP/Contents/Info.plist" ] && \
        [ "$(/usr/libexec/PlistBuddy -c 'Print :BSNotifierResident' "$NOTIFIER_APP/Contents/Info.plist" 2>/dev/null || true)" = "true" ]
}

wait_for_notifier_exit() {
    local attempts=0 installed_pid
    installed_pid() {
        # Split ps output instead of regex-matching its full line: this avoids
        # matching awk's own command line (which contains the executable path)
        # and accepts only the installed bundle executable plus optional args.
        ps -axo pid=,command= | awk -v executable="$NOTIFIER_APP/Contents/MacOS/BetterSongifyNotifier" '
            {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                split(line, fields, /[[:space:]]+/)
                pid = fields[1]
                sub(/^[^[:space:]]+[[:space:]]+/, "", line)
                if (line == executable || index(line, executable " ") == 1) print pid
            }
        '
    }
    while [ -n "$(installed_pid)" ] && [ "$attempts" -lt 20 ]; do
        sleep 0.25
        attempts=$((attempts + 1))
    done
    if [ -n "$(installed_pid)" ]; then
        warn "Installed notifier did not exit gracefully; terminating that bundle only."
        kill -TERM $(installed_pid) 2>/dev/null || true
        sleep 1
    fi
}

notifier_port_is_listening() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$NOTIFIER_PORT" -sTCP:LISTEN >/dev/null 2>&1
    else
        nc -z -w 1 127.0.0.1 "$NOTIFIER_PORT" >/dev/null 2>&1
    fi
}

wait_for_notifier_port_release() {
    local attempts=0
    while notifier_port_is_listening && [ "$attempts" -lt 20 ]; do
        sleep 0.25
        attempts=$((attempts + 1))
    done
    if notifier_port_is_listening; then
        warn "Port $NOTIFIER_PORT is still occupied; not replacing the notifier bundle."
        return 1
    fi
}

stop_notifier() {
    # Maintenance mode runs from the installed bundle context. It asks any
    # resident instance to terminate without touching the login registration.
    if installed_notifier_is_resident && [ -x "$NOTIFIER_APP/Contents/MacOS/BetterSongifyNotifier" ]; then
        "$NOTIFIER_APP/Contents/MacOS/BetterSongifyNotifier" --maintenance quit >/dev/null 2>&1 || true
    fi
    wait_for_notifier_exit
}

remove_legacy_notifier_agent() {
    unload_notifier_agent
    rm -f "$NOTIFIER_PLIST"
}

restore_legacy_notifier_agent() {
    local backup="$1"
    [ -n "$backup" ] && [ -f "$backup" ] || return 0
    cp "$backup" "$NOTIFIER_PLIST"
    if launchctl bootstrap "gui/$UID" "$NOTIFIER_PLIST" 2>/dev/null; then
        warn "Restored the legacy socket LaunchAgent after the skipped notifier upgrade."
    else
        warn "Could not restart the legacy LaunchAgent; the occupied port may belong to another process."
    fi
}

recover_notifier_upgrade() {
    local staging="$1" previous="$2" legacy_backup="$3" had_resident="$4" reason="$5"
    # If the old bundle was already moved aside, restore it before attempting
    # its normal LaunchServices lifecycle. Never execute legacy binaries here.
    if [ -e "$previous" ] && [ ! -e "$NOTIFIER_APP" ]; then
        if ! mv "$previous" "$NOTIFIER_APP"; then
            warn "Could not restore the previous notifier bundle; left it at $previous."
        fi
    fi
    rm -rf "$staging"
    if [ "$had_resident" = true ] && [ -d "$NOTIFIER_APP" ]; then
        open -g "$NOTIFIER_APP" >/dev/null 2>&1 || true
        warn "Notifier upgrade skipped ($reason); relaunched the previous resident companion."
    else
        restore_legacy_notifier_agent "$legacy_backup"
        warn "Notifier upgrade skipped ($reason); preserved the previous legacy configuration."
    fi
    # A restored previous path has been moved back. If it could not be moved,
    # retain it rather than deleting the only recoverable installed bundle.
    [ -e "$NOTIFIER_APP" ] && rm -rf "$previous"
    rm -f "$legacy_backup"
}

# Anything an earlier full install could have left: the resident bundle, the
# socket LaunchAgent before it, or the Application Support layout before that.
notifier_is_present() {
    [ -e "$NOTIFIER_APP" ] || [ -f "$NOTIFIER_PLIST" ] || [ -e "$NOTIFIER_LEGACY_SUPPORT" ]
}

probe_notifier() {
    local attempts=0 response
    while [ "$attempts" -lt 12 ]; do
        response=$(curl --silent --show-error --max-time 1 --output /dev/null --write-out '%{http_code}' -X OPTIONS \
            -H 'Access-Control-Request-Private-Network: true' "http://127.0.0.1:$NOTIFIER_PORT/notify" 2>/dev/null || true)
        if [ "$response" = "204" ]; then
            return 0
        fi
        sleep 0.25
        attempts=$((attempts + 1))
    done
    return 1
}

install_notifier() {
    # Detection only on this path: removing a trust setting can raise a password
    # dialog, and an install must not do that for a leftover it merely noticed.
    warn_legacy_signing_identity
    info "Building the resident notification companion..."
    if ! bash "$SCRIPT_DIR/tools/build-notifier-app.sh" >/dev/null 2>&1; then
        warn "Could not build the notifier app (needs Xcode Command Line Tools)."
        warn "Everything else still works; song changes will show in-app instead."
        return 0
    fi

    mkdir -p "$NOTIFIER_APPS_DIR" "$(dirname "$NOTIFIER_PLIST")"
    # Verify a sibling staging copy before touching a known-good installed app.
    local staging staged_app previous legacy_backup="" had_resident=false
    staging=$(mktemp -d "$NOTIFIER_APPS_DIR/.BetterSongifyNotifier.XXXXXX")
    staged_app="$staging/BetterSongifyNotifier.app"
    previous="$NOTIFIER_APPS_DIR/.BetterSongifyNotifier.previous.$$"
    cp -R "$SCRIPT_DIR/dist/BetterSongifyNotifier.app" "$staged_app"
    if ! codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1 || \
       [ "$(/usr/libexec/PlistBuddy -c 'Print :BSNotifierResident' "$staged_app/Contents/Info.plist" 2>/dev/null || true)" != "true" ]; then
        rm -rf "$staging"
        warn "Notifier staging verification failed; keeping the installed companion."
        return 0
    fi
    if installed_notifier_is_resident; then had_resident=true; fi
    # Retain an exact legacy plist only until migration has released the port,
    # so an upgrade blocked by an unrelated listener can restore its prior
    # socket owner rather than silently disabling the existing notifier.
    if [ -f "$NOTIFIER_PLIST" ]; then
        legacy_backup=$(mktemp /tmp/better-songify-notifier-legacy.XXXXXX)
        cp "$NOTIFIER_PLIST" "$legacy_backup"
    fi
    # Stop before replacement so a probe cannot reach stale code. The
    # SMAppService open-at-login registration is left alone here and refreshed
    # below; only explicit removal unregisters it.
    remove_legacy_notifier_agent
    stop_notifier
    if ! wait_for_notifier_port_release; then
        recover_notifier_upgrade "$staging" "$previous" "$legacy_backup" "$had_resident" "port $NOTIFIER_PORT remained occupied"
        return 0
    fi
    if [ -e "$NOTIFIER_APP" ] && ! mv "$NOTIFIER_APP" "$previous"; then
        recover_notifier_upgrade "$staging" "$previous" "$legacy_backup" "$had_resident" "could not stage the installed bundle for replacement"
        return 0
    fi
    if ! mv "$staged_app" "$NOTIFIER_APP"; then
        recover_notifier_upgrade "$staging" "$previous" "$legacy_backup" "$had_resident" "could not move the verified staged bundle into place"
        return 0
    fi
    rm -rf "$previous"
    rmdir "$staging" 2>/dev/null || true
    rm -f "$legacy_backup"
    # Layout used before the app moved to ~/Applications; remove it only once
    # the verified resident bundle is safely in place.
    rm -rf "$NOTIFIER_LEGACY_SUPPORT"
    # Without this the app is invisible to LaunchServices, and macOS refuses to
    # let it post notifications at all ("Notifications are not allowed").
    "$LSREGISTER" -f "$NOTIFIER_APP" 2>/dev/null || true
    # The companion tears down its menu bar item when Spotify quits but stays
    # resident, so this registration is the only thing that brings it back after
    # a restart — and the only reason launching Spotify can start it at all.
    # Every push alternative (URL scheme, CFBundleExecutable shim) was tried and
    # failed, so retest those before replacing this. Runs from the installed app
    # so SMAppService keeps its expected identity.
    if ! "$NOTIFIER_APP/Contents/MacOS/BetterSongifyNotifier" --maintenance register-login >/dev/null 2>&1; then
        warn "Could not set BetterSongify to open at login; the menu bar item will not return after a restart until you re-run this installer."
    fi
    open -g "$NOTIFIER_APP" >/dev/null 2>&1 || true
    if probe_notifier; then
        success "Resident notification companion installed and listening."
    else
        warn "Notifier did not answer on port $NOTIFIER_PORT; song changes will show in-app."
    fi
}

# The Info.plist hash sealed in Spotify's own signature (code directory special
# slot -1), as printed by codesign. Empty when it cannot be read.
sealed_info_plist_hash() {
    codesign -d --verbose=6 "$SPOTIFY_APP" 2>&1 | awk '
        /^[[:space:]]*-1=/ { sub(/^[[:space:]]*-1=/, ""); if (length($0) == 64) { print; exit } }'
}

# Why this exists, and why every future edit of Spotify's Info.plist must end
# here: Info.plist is special slot -1 of Spotify's code directory, so its bytes
# feed the bundle's CDHash. Spotify ships that plist in BINARY format and
# PlistBuddy silently rewrites it as XML — same content, different bytes,
# different CDHash. macOS pins Automation ("control Spotify") approvals to that
# hash for a bundle whose signature no longer validates, which ours never does
# once xpui.spa is injected, so a format flip silently invalidates every
# existing grant: the companion's Spotify reads then fail with -1743 and the
# menu bar reports "Spotify access unavailable" with no prompt to fix it.
# Injecting xpui.spa alone is safe — it is an ordinary sealed resource and
# leaves the CDHash untouched. Only the plist moves it.
#
# Converting back to binary reproduces the vendor's exact bytes, so this both
# undoes the damage in the same run and repairs machines a previous version
# already broke. The candidate is adopted only when it hashes to the sealed
# value, so a genuine content difference is reported instead of guessed at.
# Sets SPOTIFY_PLIST_STATE to intact (already the signed bytes), repaired (put
# back just now), or mismatch (content genuinely differs, or codesign gave us
# nothing to compare against). Returns non-zero only for mismatch.
SPOTIFY_PLIST_STATE="unknown"
restore_spotify_plist_bytes() {
    local plist="$SPOTIFY_APP/Contents/Info.plist"
    local sealed actual candidate
    SPOTIFY_PLIST_STATE="mismatch"
    sealed=$(sealed_info_plist_hash)
    [ -n "$sealed" ] || return 1
    actual=$(shasum -a 256 "$plist" 2>/dev/null | awk '{print $1}')
    if [ "$actual" = "$sealed" ]; then
        SPOTIFY_PLIST_STATE="intact"
        return 0
    fi
    candidate=$(mktemp /tmp/BetterSongify_InfoPlist.XXXXXX)
    if plutil -convert binary1 -o "$candidate" "$plist" 2>/dev/null &&
       [ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = "$sealed" ] &&
       cat "$candidate" > "$plist" 2>/dev/null; then
        rm -f "$candidate"
        "$LSREGISTER" -f "$SPOTIFY_APP" 2>/dev/null || true
        SPOTIFY_PLIST_STATE="repaired"
        return 0
    fi
    rm -f "$candidate"
    return 1
}

# Restores the signed plist bytes when possible, and explains the one-time
# re-approval when the content genuinely changed and cannot be put back.
settle_spotify_plist() {
    if restore_spotify_plist_bytes; then
        success "Spotify's signed Info.plist bytes are back — macOS keeps its Automation approval."
        return 0
    fi
    warn "Spotify's Info.plist no longer matches its signature, so macOS will drop BetterSongify's approval to read Spotify."
    echo "     ${YELLOW}Re-approve with:${RESET} tccutil reset AppleEvents $NOTIFIER_LABEL"
    echo "     ${GRAY}Then play or pause a track and allow the prompt.${RESET}"
    return 1
}

# Do NOT reintroduce a CFBundleExecutable shim to start the companion on
# Spotify's launch. It was tried and it breaks Spotify outright: repointing
# CFBundleExecutable at a wrapper script strips Spotify's real binary of the
# bundle's code identity and entitlements, and it then exits instantly and
# silently — running Contents/MacOS/Spotify by hand reproduces it with no
# output. The shim itself works fine and does start the companion, which makes
# the failure look like a launcher bug; it is not. Only the executable named by
# CFBundleExecutable can acquire a hardened-runtime bundle's identity.
# This function remains solely to undo installs that shipped with that shim.
remove_spotify_launcher() {
    local macos_dir="$SPOTIFY_APP/Contents/MacOS"
    local plist="$SPOTIFY_APP/Contents/Info.plist"
    local current
    current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
    if [ "$current" = "$LAUNCHER_NAME" ]; then
        local target
        target=$(cat "$LAUNCHER_BACKUP" 2>/dev/null || true)
        [ -n "$target" ] || target="Spotify"
        if /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $target" "$plist" 2>/dev/null; then
            # PlistBuddy just rewrote the plist as XML; put the vendor's exact
            # bytes back before anything reads the bundle's identity again.
            settle_spotify_plist
            "$LSREGISTER" -f "$SPOTIFY_APP" 2>/dev/null || true
            success "Restored Spotify's stock launch entry."
        else
            warn "Could not restore Spotify's launch entry; reinstall Spotify to fix it."
        fi
    fi
    rm -f "$macos_dir/$LAUNCHER_NAME" "$LAUNCHER_BACKUP"
}

# Migration only: builds up to August 2026 minted a per-machine self-signed code
# signing identity, kept in its own keychain and trusted as a root, to stop macOS
# mislabelling the menu bar row. Measured against an ad-hoc install, it never
# bought that (see the note in tools/build-notifier-app.sh), so nothing creates
# it any more — but a trusted code-signing root and a keychain holding its
# private key must not be left on a machine that ran an older build.
LEGACY_SIGNING_CN="BetterSongify Local Signing"
LEGACY_SIGNING_KEYCHAIN="$HOME/Library/Keychains/BetterSongify.keychain-db"

# 0 while the old certificate is still installed anywhere macOS will find it.
legacy_signing_identity_present() {
    security find-certificate -c "$LEGACY_SIGNING_CN" >/dev/null 2>&1 || [ -f "$LEGACY_SIGNING_KEYCHAIN" ]
}

remove_signing_identity() {
    legacy_signing_identity_present || return 0
    info "Removing the local code signing identity left by an earlier BetterSongify build..."
    # Two independent leftovers, and neither implies the other. Trust settings
    # live in the trust store rather than in the keychain, so they outlive the
    # file — and on machines where the trust prompt was authorised as an admin,
    # the root was filed in /Library/Keychains/System.keychain instead of the
    # user's own store, where only root can remove it. Search every keychain
    # rather than the (possibly already deleted) BetterSongify one.
    local cert
    cert=$(mktemp) || return 0
    if security find-certificate -c "$LEGACY_SIGNING_CN" -p > "$cert" 2>/dev/null; then
        security remove-trusted-cert "$cert" >/dev/null 2>&1 || true
        if [ "$(id -u)" = "0" ]; then
            security remove-trusted-cert -d "$cert" >/dev/null 2>&1 || true
            security delete-certificate -c "$LEGACY_SIGNING_CN" /Library/Keychains/System.keychain >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$cert"
    if [ -f "$LEGACY_SIGNING_KEYCHAIN" ]; then
        local remaining
        remaining=$(security list-keychains -d user 2>/dev/null | sed 's/^[[:space:]]*"//;s/"$//' | grep -v "BetterSongify.keychain-db" | tr '\n' ' ')
        [ -n "$remaining" ] && security list-keychains -d user -s $remaining >/dev/null 2>&1 || true
        security delete-keychain "$LEGACY_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
    fi
    warn_legacy_signing_identity
}

# A root in the System keychain needs privileges this installer does not ask
# for, so say exactly how to finish rather than failing or prompting.
warn_legacy_signing_identity() {
    security find-certificate -c "$LEGACY_SIGNING_CN" >/dev/null 2>&1 || return 0
    warn "An old BetterSongify code signing root is still trusted on this Mac. Remove it with:"
    warn "  sudo security delete-certificate -c \"$LEGACY_SIGNING_CN\" /Library/Keychains/System.keychain"
}

remove_notifier() {
    info "Removing the resident notification companion..."
    # Always unregister, including on the reinstall path. Skipping it to dodge
    # the "Login Item Added" notice was tried and is actively harmful: deleting
    # the bundle invalidates the BTM entry, but leaving that entry behind makes
    # the reinstall's register() a silent no-op, so the app ends up
    # .notFound — quiet, and not registered at all. The notice is the honest
    # cost of a real registration. This maintenance command runs from the
    # installed app so SMAppService keeps its expected app identity.
    if installed_notifier_is_resident && [ -x "$NOTIFIER_APP/Contents/MacOS/BetterSongifyNotifier" ]; then
        "$NOTIFIER_APP/Contents/MacOS/BetterSongifyNotifier" --maintenance unregister-login >/dev/null 2>&1 || true
    fi
    stop_notifier
    remove_legacy_notifier_agent
    if ! wait_for_notifier_port_release; then
        warn "Port $NOTIFIER_PORT remains occupied; continuing removal because the listener may be unrelated."
    fi
    rm -rf "$NOTIFIER_APP" "$NOTIFIER_LEGACY_SUPPORT"
    remove_signing_identity
    success "Notification companion removed."
}

repack_spa() {
    local src_dir="$1" out_zip="$2"
    rm -f "$out_zip"
    (cd "$src_dir" && zip -q -r "$out_zip" . -x ".DS_Store" -x "*/.DS_Store")
}

choose_operation() {
    local choice="${1:-}"
    case "$choice" in
        install|i|I) echo "I" ;;
        remove|uninstall|r|R) echo "R" ;;
        reinstall|ri|RI|x|X) echo "RI" ;;
        "")
            echo " Please select an operation:" >&2
            echo "   ${GREEN}[I] Install or Update BetterSongify${RESET}" >&2
            echo "   ${YELLOW}[X] Reinstall (remove, then install fresh)${RESET}" >&2
            echo "   ${RED}[R] Remove completely${RESET}" >&2
            echo "" >&2
            local answer attempts=0
            while true; do
                if [ "$attempts" -ge 5 ]; then
                    warn "No valid input received. Defaulting to Install." >&2
                    echo "I"
                    return 0
                fi
                read -r -p " > Selection (I/X/R): " answer || { echo "I"; return 0; }
                answer=$(echo "$answer" | tr '[:lower:]' '[:upper:]' | xargs)
                if [ "$answer" = "I" ] || [ "$answer" = "R" ]; then
                    echo "$answer"
                    return 0
                fi
                if [ "$answer" = "X" ]; then
                    echo "RI"
                    return 0
                fi
                attempts=$((attempts + 1))
            done
            ;;
        *)
            error "Unknown option: $choice (use 'install', 'reinstall', or 'remove', optionally with --no-notifier)" >&2
            exit 1
            ;;
    esac
}

# Interactive counterpart of --no-notifier, asked only after the menu picked an
# install. The full package is the default, so Return and unreadable input both
# keep the companion.
choose_notifier() {
    echo " Install the notifier companion as well?" >&2
    echo "   ${GREEN}[Y] Full package: song-change notifications and the menu-bar song (default)${RESET}" >&2
    echo "   ${YELLOW}[N] Spotify only: no companion app, macOS notifications or menu-bar item${RESET}" >&2
    echo "" >&2
    local answer attempts=0
    while [ "$attempts" -lt 5 ]; do
        read -r -p " > Include companion? (Y/n): " answer || { echo true; return 0; }
        answer=$(echo "$answer" | tr '[:lower:]' '[:upper:]' | xargs)
        case "$answer" in
            ""|Y|YES) echo true; return 0 ;;
            N|NO) echo false; return 0 ;;
        esac
        attempts=$((attempts + 1))
    done
    warn "No valid input received. Defaulting to the full package." >&2
    echo true
}

logo

OPERATION_ARG=""
WITH_NOTIFIER=""  # empty until decided: --no-notifier, the menu, or the full default
for arg in "$@"; do
    case "$arg" in
        --no-notifier) WITH_NOTIFIER=false ;;
        -*)
            error "Unknown flag: $arg (the only flag is --no-notifier)"
            exit 1
            ;;
        *)
            if [ -n "$OPERATION_ARG" ]; then
                error "Only one operation at a time: '$OPERATION_ARG' and '$arg' were both given."
                exit 1
            fi
            OPERATION_ARG="$arg"
            ;;
    esac
done

SPOTIFY_APP="${SPOTIFY_APP:-}"
[ -n "$SPOTIFY_APP" ] || SPOTIFY_APP=$(find_spotify) || {
    echo ""
    error "Spotify core files not found!"
    echo "     ${YELLOW}Install Spotify from https://www.spotify.com/download${RESET}"
    exit 1
}

SPOTIFY_APPS_DIR="$SPOTIFY_APP/Contents/Resources/Apps"
SPA_FILE="$SPOTIFY_APPS_DIR/xpui.spa"
BACKUP_FILE="$SPOTIFY_APPS_DIR/xpui.spa.bak"
LAUNCHER_NAME="BetterSongifyLauncher"
LAUNCHER_BACKUP="$SPOTIFY_APP/Contents/MacOS/.bettersongify-stock-executable"

if [ ! -w "$SPOTIFY_APPS_DIR" ]; then
    error "No write permission for $SPOTIFY_APPS_DIR"
    echo "     ${YELLOW}Re-run this installer with sudo:${RESET}"
    echo "     ${YELLOW}sudo \"$0\" $*${RESET}"
    exit 1
fi

CHOICE=$(choose_operation "$OPERATION_ARG")
echo ""

if [ "$CHOICE" != "R" ] && [ -z "$WITH_NOTIFIER" ]; then
    if [ -z "$OPERATION_ARG" ]; then
        WITH_NOTIFIER=$(choose_notifier)
        echo ""
    else
        WITH_NOTIFIER=true
    fi
fi

TEMP_FOLDER=$(mktemp -d /tmp/BetterSongify_Extraction.XXXXXX)
OUTPUT_ZIP="$TEMP_FOLDER.zip"
cleanup() { rm -rf "$TEMP_FOLDER" "$OUTPUT_ZIP"; }
trap cleanup EXIT

rollback() {
    warn "Rolling back changes and restoring original files..."
    if [ -f "$1" ]; then
        cp -f "$1" "$SPA_FILE"
        success "Rollback successful."
    fi
}

if [ "$CHOICE" = "R" ] || [ "$CHOICE" = "RI" ]; then
    EMERGENCY_BACKUP="$SPA_FILE.uninst.bak"
    trap 'error "UNINSTALLATION FAILED"; rollback "$EMERGENCY_BACKUP"; rm -f "$EMERGENCY_BACKUP"; cleanup' ERR

    quit_spotify

    info "Preparing removal..."
    cp -f "$SPA_FILE" "$EMERGENCY_BACKUP"

    info "Unpacking Spotify UI..."
    # Not unzip: Spotify (seen on 1.3.0.277) ships xpui.spa with a bare "/" entry, and
    # unzip exits 2 on it even though every file extracts, tripping set -e.
    ditto -x -k "$SPA_FILE" "$TEMP_FOLDER"

    if [ ! -f "$TEMP_FOLDER/index.html" ]; then
        error "index.html was not found inside the package."
        exit 1
    fi

    info "Scrubbing injected local BetterSongify script tag..."
    if grep -Fqi "$SCRIPT_TAG" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_1" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_2" "$TEMP_FOLDER/index.html"; then
        perl -0777 -pi -e 's{<script src="(?:BetterSongify|BetterSpotify|SpotifyLyrics)\.js"></script>}{}gi' "$TEMP_FOLDER/index.html"
        success "Cleared script injection."
    else
        warn "No local BetterSongify script tag found — may already be removed."
    fi

    if [ -f "$TEMP_FOLDER/BetterSongify.js" ] || [ -f "$TEMP_FOLDER/BetterSpotify.js" ] || [ -f "$TEMP_FOLDER/SpotifyLyrics.js" ]; then
        rm -f "$TEMP_FOLDER/BetterSongify.js" "$TEMP_FOLDER/BetterSpotify.js" "$TEMP_FOLDER/SpotifyLyrics.js"
        success "Deleted local BetterSongify.js asset."
    else
        warn "BetterSongify.js not found in package — may already be removed."
    fi

    info "Repacking clean application..."
    repack_spa "$TEMP_FOLDER" "$OUTPUT_ZIP"
    mv -f "$OUTPUT_ZIP" "$SPA_FILE"
    rm -f "$EMERGENCY_BACKUP" "$BACKUP_FILE"

    remove_spotify_launcher
    remove_notifier

    if [ "$CHOICE" = "RI" ]; then
        trap - ERR
        success "BetterSongify removed. Reinstalling fresh..."
        rm -rf "$TEMP_FOLDER"
        mkdir -p "$TEMP_FOLDER"
        echo ""
    else
        trap cleanup EXIT
        success "BetterSongify was fully removed. Restarting Spotify..."
        open -a Spotify
    fi
fi

if [ "$CHOICE" = "I" ] || [ "$CHOICE" = "RI" ]; then
    trap 'error "INSTALLATION FAILED"; rollback "$BACKUP_FILE"; cleanup' ERR

    quit_spotify

    # Heal a bundle an earlier version left with an XML Info.plist (see
    # restore_spotify_plist_bytes): its CDHash no longer matches what macOS
    # pinned the Automation approval to, which is the "Spotify access
    # unavailable" menu-bar state. Silent when the plist is already intact,
    # since that is every ordinary run.
    if restore_spotify_plist_bytes; then
        if [ "$SPOTIFY_PLIST_STATE" = "repaired" ]; then
            success "Repaired Spotify's Info.plist bytes — macOS keeps its Automation approval."
        fi
    else
        info "Spotify's Info.plist differs from its signature; BetterSongify may need Automation re-approved."
    fi

    info "Unpacking Spotify user interface..."
    ditto -x -k "$SPA_FILE" "$TEMP_FOLDER"

    if [ ! -f "$TEMP_FOLDER/index.html" ]; then
        error "Failed to locate Spotify app layout."
        exit 1
    fi

    if { grep -Fqi "$SCRIPT_TAG" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_1" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_2" "$TEMP_FOLDER/index.html"; } && [ -f "$BACKUP_FILE" ]; then
        info "Existing local BetterSongify installation detected — keeping original backup."
    else
        info "Creating application backup..."
        cp -f "$SPA_FILE" "$BACKUP_FILE"
    fi

    if grep -Fqi "$LEGACY_SCRIPT_TAG_1" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_2" "$TEMP_FOLDER/index.html" || [ -f "$TEMP_FOLDER/BetterSpotify.js" ] || [ -f "$TEMP_FOLDER/SpotifyLyrics.js" ]; then
        info "Migrating pre-rename installation — scrubbing old injection..."
        perl -0777 -pi -e 's{<script src="(?:BetterSpotify|SpotifyLyrics)\.js"></script>}{}gi' "$TEMP_FOLDER/index.html"
        rm -f "$TEMP_FOLDER/BetterSpotify.js" "$TEMP_FOLDER/SpotifyLyrics.js"
    fi

    info "Deploying built local BetterSongify bundle..."
    get_better_songify_js "$TEMP_FOLDER/BetterSongify.js"

    info "Linking local BetterSongify.js into Spotify startup..."
    if grep -Fqi "$SCRIPT_TAG" "$TEMP_FOLDER/index.html"; then
        success "BetterSongify script tag is already active."
    else
        perl -0777 -pi -e 's{</body>}{<script src="BetterSongify.js"></script></body>}i' "$TEMP_FOLDER/index.html"
        success "Successfully linked local BetterSongify.js."
    fi

    info "Recompiling Spotify application package..."
    repack_spa "$TEMP_FOLDER" "$OUTPUT_ZIP"
    mv -f "$OUTPUT_ZIP" "$SPA_FILE"

    if [ "$WITH_NOTIFIER" = true ]; then
        install_notifier
    else
        info "Skipping the notifier companion: installing BetterSongify inside Spotify only."
        # Switching down from a full install must not strand a resident menu-bar
        # app and its login item that the new script no longer talks to.
        if notifier_is_present; then
            remove_notifier
        else
            warn_legacy_signing_identity
        fi
    fi

    trap cleanup EXIT
    success "Installation complete. Booting Spotify..."
    open -a Spotify

    echo ""
    echo "${GRAY}Note: Spotify updates can overwrite BetterSongify. Re-run this installer after Spotify updates.${RESET}"
    if [ "$WITH_NOTIFIER" != true ]; then
        echo "${GRAY}To add notifications and the menu-bar song later, re-run the installer and include the companion.${RESET}"
    fi
fi

echo ""
echo "${GRAY}You can safely close this terminal.${RESET}"
