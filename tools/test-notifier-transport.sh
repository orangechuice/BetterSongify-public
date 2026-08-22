#!/bin/bash
# Exercises the native loopback parser in --transport-test mode. That mode
# does not start AppKit, query Spotify, mutate login state, or post a macOS
# notification; its coordinator returns a synthetic successful delivery.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EXECUTABLE="$ROOT/dist/BetterSongifyNotifier.app/Contents/MacOS/BetterSongifyNotifier"
LOG=$(mktemp /tmp/better-songify-notifier-test.XXXXXX)
PID=""
PORT=17353
parallel_dir=""
MATCHER_PATH="$HOME/Applications/BetterSongifyNotifier.app/Contents/MacOS/BetterSongifyNotifier"

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
    [ -z "$parallel_dir" ] || rm -rf "$parallel_dir"
    rm -f "$LOG"
}
trap cleanup EXIT

[ -x "$EXECUTABLE" ] || { echo "test-notifier: build first with npm run build:notifier" >&2; exit 1; }
# Mirrors install-macos.sh's command-prefix matcher. The second fixture is an
# awk command containing the path and must not be mistaken for the app.
matcher_fixture=$(printf '101 %s --maintenance quit\n202 awk -v executable=%s matcher-program\n303 /tmp/BetterSongifyNotifier\n' "$MATCHER_PATH" "$MATCHER_PATH" | awk -v executable="$MATCHER_PATH" '
    {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        split(line, fields, /[[:space:]]+/)
        pid = fields[1]
        sub(/^[^[:space:]]+[[:space:]]+/, "", line)
        if (line == executable || index(line, executable " ") == 1) print pid
    }
')
[ "$matcher_fixture" = "101" ] || { echo "test-notifier: installed-app PID matcher fixture failed" >&2; exit 1; }
"$EXECUTABLE" --transport-test >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 30); do
    if curl --silent --max-time 0.2 --output /dev/null --write-out '%{http_code}' -X OPTIONS "http://127.0.0.1:$PORT/notify" 2>/dev/null | grep -qx 204; then break; fi
    sleep 0.1
done
if ! curl --silent --max-time 0.5 --output /dev/null --write-out '%{http_code}' -X OPTIONS "http://127.0.0.1:$PORT/notify" | grep -qx 204; then
    cat "$LOG" >&2
    exit 1
fi

split_response=$({ printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 34\r\n\r\n{"title":"Split'; sleep 0.05; printf '","artist":"Write"}'; } | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$split_response" | grep -q 'HTTP/1.1 200 OK'
printf '%s' "$split_response" | grep -q '"ok":true'

invalid_response=$(printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1\r\n\r\n{' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$invalid_response" | grep -q 'HTTP/1.1 400'
oversize_response=$(printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4097\r\n\r\n' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$oversize_response" | grep -q 'HTTP/1.1 413'
missing_length_response=$(printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n{}' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$missing_length_response" | grep -q 'HTTP/1.1 411'
method_response=$(printf 'GET /notify HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$method_response" | grep -q 'HTTP/1.1 405'
path_response=$(printf 'OPTIONS /wrong HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$path_response" | grep -q 'HTTP/1.1 404'

# The CORS grant is what stops any web page the user happens to be visiting
# from driving this endpoint (spoofing notifications, hiding the menu-bar item,
# or reading back the current track). It was `*`; only Spotify's own origins
# may hold it. Preflights are covered too, since that is where a browser asks.
for origin in https://xpui.app.spotify.com https://open.spotify.com; do
    granted=$(printf 'OPTIONS /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: %s\r\n\r\n' "$origin" | nc -w 1 127.0.0.1 "$PORT")
    printf '%s' "$granted" | grep -q "Access-Control-Allow-Origin: $origin" || {
        echo "test-notifier: Spotify origin $origin was refused the CORS grant" >&2; exit 1; }
    # Without Vary a shared cache could hand a Spotify-origin grant to another site.
    printf '%s' "$granted" | grep -q 'Vary: Origin' || {
        echo "test-notifier: CORS grant is missing Vary: Origin" >&2; exit 1; }
done

# The second case is suffix confusion: it must not satisfy a "spotify.com" test.
for origin in https://evil.example.com https://notspotify.com; do
    refused=$(printf 'OPTIONS /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: %s\r\n\r\n' "$origin" | nc -w 1 127.0.0.1 "$PORT")
    printf '%s' "$refused" | grep -q 'HTTP/1.1 204'
    ! printf '%s' "$refused" | grep -q 'Access-Control-Allow-Origin' || {
        echo "test-notifier: foreign origin $origin was granted CORS access" >&2; exit 1; }
done

# CORS is browser-enforced, so origin-less clients — the installer's curl health
# check, and the rest of this file — must keep working with no grant at all.
originless=$(printf 'OPTIONS /notify HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$originless" | grep -q 'HTTP/1.1 204'
! printf '%s' "$originless" | grep -q 'Access-Control-Allow-Origin' || {
    echo "test-notifier: origin-less request was granted CORS access" >&2; exit 1; }

# Menu-bar visibility shares the parser but not the notification path: it must
# answer immediately and reject a non-boolean rather than coercing one.
menu_bar_payload='{"visible":false}'
menu_bar_response=$(printf 'POST /menu-bar HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %s\r\n\r\n%s' "${#menu_bar_payload}" "$menu_bar_payload" | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$menu_bar_response" | grep -q 'HTTP/1.1 200 OK'
printf '%s' "$menu_bar_response" | grep -q '"ok":true'
menu_bar_preflight=$(printf 'OPTIONS /menu-bar HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$menu_bar_preflight" | grep -q 'HTTP/1.1 204'
menu_bar_invalid='{"visible":"yes"}'
menu_bar_invalid_response=$(printf 'POST /menu-bar HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %s\r\n\r\n%s' "${#menu_bar_invalid}" "$menu_bar_invalid" | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$menu_bar_invalid_response" | grep -q 'HTTP/1.1 400'
stalled_response=$({ printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 20\r\n\r\n{"title":"slow"'; sleep 0.6; } | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$stalled_response" | grep -q 'HTTP/1.1 408'

# Test-only coordinator delays this valid request past the injected 0.3s
# processing timeout. Its cancellation token prevents the delayed success from
# becoming a late submission after HTTP has returned the fallback-causing 503.
submissions_before=$(curl --silent --max-time 1 "http://127.0.0.1:$PORT/test-submissions" | sed -n 's/.*"submissions":\([0-9][0-9]*\).*/\1/p')
[ -n "$submissions_before" ] || { echo "test-notifier: missing submission counter" >&2; exit 1; }
delayed_payload='{"title":"Delayed"}'
delayed_response=$(printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %s\r\n\r\n%s' "${#delayed_payload}" "$delayed_payload" | nc -w 1 127.0.0.1 "$PORT")
printf '%s' "$delayed_response" | grep -q 'HTTP/1.1 503'
sleep 0.7
submissions_after=$(curl --silent --max-time 1 "http://127.0.0.1:$PORT/test-submissions" | sed -n 's/.*"submissions":\([0-9][0-9]*\).*/\1/p')
[ "$submissions_after" = "$submissions_before" ] || { echo "test-notifier: delayed request submitted after cancellation" >&2; exit 1; }

# Concurrent valid requests plus another deadline exercise request-local serial
# queues and ensure one timeout cannot consume a neighbor's response.
parallel_dir=$(mktemp -d /tmp/better-songify-notifier-parallel.XXXXXX)
parallel_pids=()
for number in 1 2 3 4; do
    payload=$(printf '{"title":"Parallel%s"}' "$number")
    { printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %s\r\n\r\n%s' "${#payload}" "$payload" | nc -w 1 127.0.0.1 "$PORT" >"$parallel_dir/$number"; } &
    parallel_pids+=("$!")
done
({ printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 99\r\n\r\n{"title":"timeout"'; sleep 0.6; } | nc -w 1 127.0.0.1 "$PORT" >"$parallel_dir/timeout") &
parallel_pids+=("$!")
for pid in "${parallel_pids[@]}"; do wait "$pid"; done
for number in 1 2 3 4; do grep -q 'HTTP/1.1 200 OK' "$parallel_dir/$number"; done
grep -q 'HTTP/1.1 408' "$parallel_dir/timeout"
rm -rf "$parallel_dir"
parallel_dir=""

echo "test-notifier: PID matcher, submission counter, split/parallel POSTs, menu-bar visibility, CORS origin allowlist, malformed requests, and stalled deadlines passed"
