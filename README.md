# peep

Audio preview for [yazi](https://yazi-rs.github.io/), plus a small waveform
PNG renderer.

## peep

`peep` integrates with yazi: when you hover a file inside yazi, it plays the
file's audio. Any argument after the program name is forwarded to yazi
unchanged.

```sh
peep
peep /path/to/dir
peep /some/absolute/file.mp3
```

peep spawns `ya sub hover` and waits for it to connect to the yazi daemon
before listening for hover events. Hover events carry a sender id; peep only
plays media from the yazi instance it spawned, ignoring sender-filtered lines
from other clients and malformed lines entirely.

### PEEP_NO_CLIENT_ID

Some yazi versions do not support hover client ids. Set this environment
variable to 1 to spawn yazi without `--client-id` and disable sender
filtering:

```sh
PEEP_NO_CLIENT_ID=1 peep
```

This is a compatibility fallback: when unset, peep generates a random client
id and passes it to yazi.

## peak

`peak` renders a 400x200 waveform PNG of an audio file to standard output:

```sh
peak song.wav > waveform.png
```

The PNG is 400x200 RGBA with transparent background. Silent regions are drawn
as a red center line; audible waveform peaks are drawn in white.