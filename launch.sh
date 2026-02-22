#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

# Redirect stdout+stderr to log first, THEN enable trace so all output is captured
rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >"$LOGS_PATH/$PAK_NAME.txt" 2>&1
set -x

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/$PAK_NAME"

cleanup() {
    rm -f /tmp/stay_awake
    # Intentionally do NOT kill musicserver or remove /tmp/stay_alive here —
    # musicserver must keep running so background music continues to the next song.
}

start_scrobble_monitor() {
    # Kill any stale monitor instance from a previous session
    if [ -f /tmp/scrobble_monitor.pid ]; then
        OLD_PID=$(cat /tmp/scrobble_monitor.pid 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            kill "$OLD_PID" 2>/dev/null
            sleep 1
        fi
        rm -f /tmp/scrobble_monitor.pid
    fi

    # Start the scrobble monitor as a background daemon. Trap '' HUP makes it
    # immune to SIGHUP when the pak exits (nohup/setsid aren't available on BusyBox).
    [ -x "$PAK_DIR/scrobble_monitor.sh" ] || chmod +x "$PAK_DIR/scrobble_monitor.sh"
    (trap '' HUP; exec "$PAK_DIR/scrobble_monitor.sh") </dev/null >/dev/null 2>&1 &

    echo "Scrobble monitor started (PID will be written to /tmp/scrobble_monitor.pid)"
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    # Scrobble toggle: only start monitor if explicitly enabled
    # The scrobble_enabled file ships with the pak (default: 0 = disabled)
    SCROBBLE_CONFIG="$PAK_DIR/scrobble_enabled"
    SCROBBLE_ON=$(cat "$SCROBBLE_CONFIG" 2>/dev/null | tr -dc '01' | head -c1)
    SCROBBLE_ON="${SCROBBLE_ON:-0}"
    if [ "$SCROBBLE_ON" = "1" ]; then
        start_scrobble_monitor
    else
        echo "Scrobbling disabled (set $SCROBBLE_CONFIG to 1 to enable)"
    fi

    # Ensure /usr/trimui/lib is in LD_LIBRARY_PATH — musicserver needs libSDL-1.2.so.0 from there.
    export LD_LIBRARY_PATH="/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

    # The musicplayer UI requires musicserver (the audio playback daemon) to be running.
    # The system's home screen normally starts musicserver before opening the music player,
    # but in pak context it's not running — so we start it ourselves.
    if ! pidof musicserver >/dev/null 2>&1; then
        /usr/trimui/bin/musicserver </dev/null >/dev/null 2>&1 &
        MUSICSERVER_PID=$!
        echo "Started musicserver (PID $MUSICSERVER_PID)"
        sleep 1
    fi

    # Change into musicplayer's own directory so relative paths inside its script resolve correctly.
    cd /usr/trimui/apps/musicplayer || exit 1

    # Run musicplayer directly instead of its launch.sh — that script removes
    # /tmp/stay_alive on exit which tells musicserver to stop, killing background playback.
    # We keep stay_alive so musicserver continues advancing through the queue.
    echo 1 > /tmp/stay_alive
    export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$(pwd)"
    ./musicplayer
}

main "$@"
