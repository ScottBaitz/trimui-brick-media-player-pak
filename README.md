# trimui-brick-music-player.pak

A TrimUI Brick pak wrapping the built-in Music Player app, with **Last.fm scrobble logging** support.

## Installation

1. Mount your TrimUI Brick SD card.
2. Download the latest release from Github. It will be named `Music.Player.pak.zip`.
3. Copy the zip file to `/Tools/tg5040/Music Player.pak.zip`.
4. Extract the zip in place, then delete the zip file.
5. Confirm that there is a `/Tools/tg5040/Music Player.pak/launch.sh` file on your SD card.
6. Unmount your SD Card and insert it into your TrimUI Brick.

## Scrobble Logging (Last.fm)

This fork adds a background scrobble monitor that tracks your music listening history
in the standard **Audioscrobbler `.scrobbler.log`** format — the same format used by
Rockbox and compatible with many Last.fm submission tools.

### Enabling scrobbling

Scrobbling is **disabled by default**. To enable it:

1. Mount your SD card and edit the file inside the pak folder:
   ```
   Tools/tg5040/Music Player.pak/scrobble_enabled
   ```
2. Change the contents from `0` to `1`
3. Save and eject

To disable again, change back to `0`.

### How it works

- When scrobbling is enabled, a lightweight background daemon (`scrobble_monitor.sh`)
  starts automatically and **keeps running even after you exit the player UI** — so plays are
  tracked while music plays in the background during gaming.
- It reads the TrimUI `musicserver`'s JSON status file (`/tmp/trimui_music/status`) which contains
  the current track's title, artist, album, track number, and filename. Duration is read from
  `/tmp/trimui_music/music_info.txt` (ffprobe output written by musicserver).
- When a track completes (track is ≥ 30 seconds long **and** at least `min(duration/2, 4 minutes)`
  has been played — per Last.fm's official scrobbling spec), an entry is appended to the scrobble log.

### Scrobble log location

```
/mnt/SDCARD/.scrobbler.log
```

The file is hidden (`.` prefix) but will be at the **root of your SD card** — easy to find when you mount the card on your computer.

### Log format

The `.scrobbler.log` file follows the Audioscrobbler 1.1 spec:

```
#AUDIOSCROBBLER/1.1
#TZ/UTC
#CLIENT/TrimUI Music Player Scrobbler
artist	album	title	tracknum	duration	L	unix_timestamp	(empty mbid)
```

Example entry:
```
'Haunted' George	Bone Hauler	This Is A Test	1	91	L	1708560000	
```

### Submitting to Last.fm

Copy `.scrobbler.log` from your SD card to your computer and submit using any of these tools:

| Tool | Type | URL |
|------|------|-----|
| Open Scrobbler | Web | https://openscrobbler.com |
| Universal Scrobbler | Web | https://universalscrobbler.com |
| Web Scrobbler | Browser extension | https://web-scrobbler.com |
| beets | CLI | `beets lastimport` |
| lastfmsubmitd | CLI | Reads `.scrobbler.log` natively |

> **Tip:** The log file accumulates entries across sessions. After submitting, you can
> delete or archive the file — a fresh header will be written on the next track play.

### Known limitations

- **Single-track repeat / loop:** If the same song plays on repeat (repeat-one mode), the title, artist, and file path are all identical on each play — the monitor cannot distinguish repeat plays from a track still in progress. Only the first play of a looped track will be scrobbled per session.
- **Duration unknown:** If a file has no duration metadata and `ffprobe` returns 0 seconds, the track will not be scrobbled (it can't satisfy the "track >= 30 seconds" rule). This is uncommon with well-tagged files.

### Disabling scrobbling

Edit `Tools/tg5040/Music Player.pak/scrobble_enabled` on your SD card and change the contents to `0`.
The music player will continue to work normally — the scrobble monitor simply won't start.
