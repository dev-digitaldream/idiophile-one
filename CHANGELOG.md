# Changelog

All notable changes. This project follows [Semantic Versioning](https://semver.org/);
versions before 1.0 may change behaviour and settings.

## [0.1.0-alpha.1] — 2026-10-18

First public alpha.

### Playback and sound
- FLAC, ALAC, WAV, AIFF, MP3 and AAC playback; gapless when the format, ReplayGain and polarity allow it.
- Output follows each file's sample rate and uses the DAC's deepest integer format; settle delay after a rate change.
- DIRECT mode (exclusive access, equalizer and ReplayGain out) and a strict BIT-PERFECT lamp.
- Audio Path panel and sample-by-sample verification of what is handed to Core Audio.
- Volume on the DAC when it has one; safety rules (new DAC starts quiet, sudden jumps refused, per-DAC limit); locked output when the DAC disappears.
- ReplayGain (track / album) from tags or measured EBU R128 loudness; polarity inversion; true-resolution scan.

### Equalizer
- Own real-time Audio Unit: RBJ biquads in double precision, exact bypass, automatic headroom.
- 10-band graphic and parametric (up to 20 filters) modes, one setting per output device.
- Presets; AutoEq / Equalizer APO import and export (file, drag-and-drop, clipboard); built-in headphone profiles.
- A/B comparison at equal loudness while the music plays; click-free switching.

### Library and sources
- Library with albums, artists, composers, genres, songs, full-text search and a queue.
- Internet radio: directory, favourites, best stream chosen among a station's streams, track titles.
- DLNA / UPnP media servers: discovery and servers added by address.

### Interface
- Hi-fi stack: network player, integrated amplifier with VU / PEAK meters, equalizer with spectrum analyser.
- Three finishes (Champagne, Black, Blue Glass), compact player, per-unit hiding, right-click menu.
- Help in English and French.

### Known issues
- Not signed with a Developer ID nor notarised: macOS asks you to allow it once.
- Sources above 24 bits are rounded to 24 bits (float engine).
- HLS / Ogg radio streams have no meters and no equalizer.
- Tested on few DACs; please report your hardware and what happens.
