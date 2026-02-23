#!/bin/sh
# =============================================================================
# scrobble_monitor.sh — TrimUI Music Player Last.fm Scrobble Monitor
# =============================================================================
# Watches the TrimUI musicserver's status file and writes completed track
# plays to a standard .scrobbler.log file (Rockbox/Audioscrobbler format).
#
# The musicserver writes a JSON status file:
#   /tmp/trimui_music/status
#
# Example content:
#   {"status":"playing","duration":0,"position":0,"volume":100,
#    "filename":"/mnt/SDCARD/Music/Artist/song.mp3",
#    "title":"Song Title","artist":"Artist","album":"Album",
#    "year":"2010","track":"4","genre":"Math Rock"}
#
# Duration is read from /tmp/trimui_music/music_info.txt (ffprobe output)
# because the JSON "duration" field is unreliable (often 0).
#
# .scrobbler.log can be submitted to Last.fm using:
#   - Web: https://openscrobbler.com  or  https://universalscrobbler.com
#   - CLI: lastfmsubmitd, beets import, etc.
#
# Format per line (tab-separated):
#   artist  album  title  tracknum  duration  L  unix_timestamp  (empty mbid)
#
# Last.fm scrobble rules honoured:
#   - Track must be >= 30 seconds long
#   - Track must have been played for >= min(track_duration/2, 240 seconds)
# =============================================================================

MUSIC_STATUS="/tmp/trimui_music/status"
MUSIC_INFO="/tmp/trimui_music/music_info.txt"
SCROBBLE_LOG="/mnt/SDCARD/.scrobbler.log"
PID_FILE="/tmp/scrobble_monitor.pid"

# Exit after this many seconds of no music server activity (conserve resources)
INACTIVITY_TIMEOUT=600

mkdir -p "$(dirname "$SCROBBLE_LOG")"

# Write .scrobbler.log header if the file is new or empty
if [ ! -s "$SCROBBLE_LOG" ]; then
    printf '#AUDIOSCROBBLER/1.1\n' > "$SCROBBLE_LOG"
    printf '#TZ/UTC\n' >> "$SCROBBLE_LOG"
    printf '#CLIENT/TrimUI Music Player Scrobbler\n' >> "$SCROBBLE_LOG"
fi

# Save our PID so launch.sh can kill stale instances
echo $$ > "$PID_FILE"

# Clean up PID file on exit
cleanup() {
    rm -f "$PID_FILE"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helper: extract a quoted string field from the JSON status file
# Handles:  "field":"value"
# ---------------------------------------------------------------------------
get_json_string() {
    local field="$1"
    grep -o "\"${field}\":\"[^\"]*\"" "$MUSIC_STATUS" 2>/dev/null \
        | head -1 \
        | sed 's/^"[^"]*":"//' \
        | sed 's/"$//' \
        | tr -d '\r\n'
}

# ---------------------------------------------------------------------------
# Helper: extract a bare number field from the JSON status file
# Handles:  "field":12345
# ---------------------------------------------------------------------------
get_json_number() {
    local field="$1"
    grep -o "\"${field}\":[0-9]*" "$MUSIC_STATUS" 2>/dev/null \
        | head -1 \
        | sed 's/^"[^"]*"://' \
        | tr -dc '0-9'
}

# ---------------------------------------------------------------------------
# Helper: get duration in seconds from music_info.txt (ffprobe verbose output)
# Parses the "Duration: HH:MM:SS.cs" line written by musicserver.
# Used as fallback when the JSON "duration" field is 0 or missing.
# ---------------------------------------------------------------------------
get_duration_from_info() {
    local dur_str h m s
    dur_str=$(grep -m1 "Duration:" "$MUSIC_INFO" 2>/dev/null \
        | sed 's/.*Duration:[[:space:]]*//' \
        | cut -d',' -f1 \
        | tr -d ' ')
    # dur_str is like "00:03:47.14"
    h=$(echo "$dur_str" | cut -d: -f1 | tr -dc '0-9'); h="${h:-0}"
    m=$(echo "$dur_str" | cut -d: -f2 | tr -dc '0-9'); m="${m:-0}"
    s=$(echo "$dur_str" | cut -d: -f3 | cut -d. -f1 | tr -dc '0-9'); s="${s:-0}"
    echo $((h * 3600 + m * 60 + s))
}

# ---------------------------------------------------------------------------
# Write one scrobble entry to the log
# ---------------------------------------------------------------------------
log_scrobble() {
    local artist="$1"
    local album="$2"
    local title="$3"
    local tracknum="$4"
    local duration="$5"
    local timestamp="$6"

    # Validate: title and artist must be non-empty
    if [ -z "$title" ] || [ -z "$artist" ]; then
        return
    fi

    # Log: artist<TAB>album<TAB>title<TAB>tracknum<TAB>duration<TAB>L<TAB>timestamp<TAB>mbid
    printf '%s\t%s\t%s\t%s\t%s\tL\t%s\t\n' \
        "$artist" "$album" "$title" "$tracknum" "$duration" "$timestamp" \
        >> "$SCROBBLE_LOG"
}

# ---------------------------------------------------------------------------
# Scrobble the currently tracked track if Last.fm rules are satisfied.
# Called both on track-change and on player-stop to catch the final track.
# ---------------------------------------------------------------------------
maybe_scrobble_current() {
    if [ -z "$LAST_TITLE" ] || [ -z "$TRACK_START" ]; then
        return
    fi

    local safe_dur now elapsed half threshold
    safe_dur=$(printf '%s' "$LAST_DURATION" | tr -dc '0-9')
    safe_dur="${safe_dur:-0}"

    now=$(date +%s)
    elapsed=$((now - TRACK_START))
    half=$((safe_dur / 2))

    # Last.fm rules: track >= 30s AND played >= min(track_duration/2, 240s)
    threshold=$half
    [ "$threshold" -gt 240 ] && threshold=240

    if [ "$safe_dur" -ge 30 ] && [ "$elapsed" -ge "$threshold" ]; then
        log_scrobble \
            "$LAST_ARTIST" \
            "$LAST_ALBUM" \
            "$LAST_TITLE" \
            "$LAST_TRACKNUM" \
            "$safe_dur" \
            "$TRACK_START"
    fi
}

# ---------------------------------------------------------------------------
# Main monitoring loop
# ---------------------------------------------------------------------------
LAST_TITLE=""
LAST_ARTIST=""
LAST_ALBUM=""
LAST_FILENAME=""
LAST_TRACKNUM=""
LAST_DURATION="0"
TRACK_START=""
WAS_PLAYING=0
INACTIVE_SINCE=""

while true; do
    SERVER_ACTIVE=0

    if [ -f "$MUSIC_STATUS" ]; then
        STATUS=$(get_json_string "status")

        if [ "$STATUS" = "playing" ]; then
            SERVER_ACTIVE=1
            INACTIVE_SINCE=""

            TITLE=$(get_json_string "title")
            ARTIST=$(get_json_string "artist")
            ALBUM=$(get_json_string "album")
            TRACKNUM=$(get_json_string "track")
            FILENAME=$(get_json_string "filename")

            # Detect new track: title/artist changed OR different file (covers repeats)
            NEW_TRACK=0
            if [ -n "$TITLE" ]; then
                if [ "$TITLE" != "$LAST_TITLE" ] || [ "$ARTIST" != "$LAST_ARTIST" ]; then
                    NEW_TRACK=1
                elif [ -n "$FILENAME" ] && [ "$FILENAME" != "$LAST_FILENAME" ]; then
                    # Same metadata but different file counts as a new play
                    NEW_TRACK=1
                fi
            fi

            if [ "$NEW_TRACK" = "1" ]; then
                # Scrobble the PREVIOUS track if it qualifies
                maybe_scrobble_current

                # Duration: try JSON field first (ms? or s?), fallback to music_info.txt
                DUR=$(get_json_number "duration")
                if [ -z "$DUR" ] || [ "$DUR" = "0" ]; then
                    DUR=$(get_duration_from_info)
                fi
                DUR=$(printf '%s' "$DUR" | tr -dc '0-9')
                DUR="${DUR:-0}"

                # Start tracking the new track
                LAST_TITLE="$TITLE"
                LAST_ARTIST="$ARTIST"
                LAST_ALBUM="$ALBUM"
                LAST_FILENAME="$FILENAME"
                LAST_TRACKNUM="$TRACKNUM"
                LAST_DURATION="$DUR"
                TRACK_START=$(date +%s)
            fi

            WAS_PLAYING=1

        else
            # Status file exists but not "playing" (paused) — wait, don't scrobble yet
            SERVER_ACTIVE=1
            INACTIVE_SINCE=""
        fi

    else
        # Status file gone — musicserver stopped/player closed
        if [ "$WAS_PLAYING" = "1" ]; then
            maybe_scrobble_current
            LAST_TITLE=""
            LAST_ARTIST=""
            LAST_ALBUM=""
            LAST_FILENAME=""
            TRACK_START=""
            WAS_PLAYING=0
        fi
    fi

    # Inactivity timeout: exit cleanly after INACTIVITY_TIMEOUT seconds of no server
    if [ "$SERVER_ACTIVE" = "0" ]; then
        if [ -z "$INACTIVE_SINCE" ]; then
            INACTIVE_SINCE=$(date +%s)
        else
            NOW=$(date +%s)
            IDLE=$((NOW - INACTIVE_SINCE))
            if [ "$IDLE" -ge "$INACTIVITY_TIMEOUT" ]; then
                exit 0
            fi
        fi
    fi

    sleep 4
done
