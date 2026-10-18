# Idiophile One — User Guide

> Generated from the in-app help (Help › Idiophile One Help) by `scripts/gen-guide.py`. Version française : [USER-GUIDE.fr.md](USER-GUIDE.fr.md).

A bit-perfect music player for macOS, built like a hi-fi rack: network player, integrated amplifier and graphic equalizer.

- [Getting started](#getting-started)
- [The rack](#the-rack)
- [Sources and radio](#sources-and-radio)
- [Amplifier controls](#amplifier-controls)
- [Sound quality](#sound-quality)
- [Equalizer](#equalizer)
- [Analysis and trust](#analysis-and-trust)
- [ReplayGain](#replaygain)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Troubleshooting](#troubleshooting)
- [Menus](#menus)

## Getting started

- Drop audio files or folders on the rack, or press **⏏** / **⌘O**. Folders are read recursively and sorted by name.
- **Space** plays or pauses. **⌘→** / **⌘←** go to the next or previous track. The keyboard media keys, headset buttons and Control Center work too.
- Supported: FLAC, ALAC, WAV, AIFF, MP3, AAC. Tags and covers embedded in FLAC files are read; otherwise a `cover.jpg` / `folder.jpg` next to the files is used.

![The library: songs view.](images/library-songs.png)
*The library: songs view.*

## The rack

- **Network player** (top): cover, title, artist, album, the signal path and the next tracks.
- **Amplifier** (middle): VU meters, input selector, volume and the panel keys.
- **Graphic equalizer** (bottom): ten faders and a spectrum analyser.
- Keep only what you want: **⌘3** network player, **⌘5** amplifier and **⌘4** equalizer each show or hide on their own (at least one stays). **View › Animate VU Meters** and **Animate Spectrum Analyzer** freeze the meters at rest while keeping them in view: with both cut the full rack uses about 3 % of a core.
- View menu: **⌘1** full rack, **⌘2** amplifier only, **⌘3** / **⌘4** / **⌘5** show or hide each unit. **⌘-** / **⌘0** / **⌘=** small, medium, large; **⌃⌘F** fits the screen.
- View › Finish: **Champagne**, **Black** or **Blue Glass**.
- Drag the rack by any bare part of a front panel.
- **Right-click** anywhere on the rack or the compact player for the full menu: playback, source, output, sound, appearance and analysis.
- **Compact Player** (⌥⌘M) is a slim player for when you work. It draws nothing animated and uses about 2 % of a processor core.

![The full rack, Blue Glass finish.](images/rack-blue-glass.png)
*The full rack, Blue Glass finish.*

![The three finishes: Champagne, Black, Blue Glass.](images/finishes.png)
*The three finishes: Champagne, Black, Blue Glass.*

![The compact player.](images/compact.png)
*The compact player.*

## Sources and radio

- The **INPUT** knob and **Playback › Source** (⌃1 / ⌃2 / ⌃3) really switch the source. **LIB** returns to your library queue where it stopped, **RADIO** plays the last station, **NET** opens your media servers. A source with nothing to play opens its browser instead.
- **Internet radio** (Library window › Internet Radio): favourites, popular stations, your country, genres and search. Star a station to keep it; drag favourites to reorder them.
- A station often has several streams. Idiophile One groups them and plays the **best one**: it weighs codec and bitrate (AAC 128 beats MP3 128), skips dead or HLS streams when it can, and prefers https. Choose *Best*, *Balanced* (up to 128 kbps) or *Light* (up to 64 kbps), or turn automatic choice off. The **N streams** menu on a row lets you pick one by hand.
- Radio goes through the same engine as files, so the meters, the equalizer and the DAC clock apply. It is never bit-perfect.
- **Network** (Library window › Network): DLNA / UPnP media servers on your network are found automatically. A server out of reach of discovery (VPN, another subnet) can be added by name or address. Some NAS only serve devices they have allowed: on a QNAP, allow this Mac in DLNA Media Server › Media Receivers.

![Internet radio: streams grouped by station, best quality chosen for you.](images/library-radio.png)
*Internet radio: streams grouped by station, best quality chosen for you.*

![A DLNA / UPnP server browsed from the Network source.](images/network.png)
*A DLNA / UPnP server browsed from the Network source.*

## Amplifier controls

- **POWER** fades the lamps out and quits. The volume is remembered.
- **VOLUME**: turn it by dragging around the knob, with the scroll wheel (up = louder), or with the keyboard volume keys. When the DAC has its own volume control, the knob drives it directly, so the samples stay untouched.
- **DIRECT** takes the shortest path: equalizer and ReplayGain out, exclusive access to the DAC (other apps and system sounds are muted on it).
- **METER** switches between **VU** (classic 300 ms ballistics) and **PEAK** (fast attack, slow fall).
- **DIMMER** sets the backlight: full, warm, or deep.
- The **BIT-PERFECT** lamp lights when the file reaches the DAC unaltered.

## Sound quality

- Choose your DAC in the **Output** menu. A DAC plugged in later appears automatically.
- The DAC clock follows each file's sample rate, so nothing is resampled. If the DAC can't play that rate, the player shows **RESAMPLED**.
- The DAC is set to its deepest integer format (for example 24-bit) so no bits are lost.
- BIT-PERFECT requires: DIRECT on, the same rate and enough bits on the DAC, and the volume on the DAC (or the knob fully up).
- The MacBook's built-in speakers apply their own processing: use an external DAC for a true bit-perfect path.

![Audio Path: every step from file to DAC, read live.](images/audio-path-live.png)
*Audio Path: every step from file to DAC, read live.*

## Equalizer

- Each output device keeps its own equalizer setting: headphones and speakers want different curves. A new device starts flat.
- **EDIT** (or Output › Equalizer Editor, ⌥⌘E) opens the **parametric editor**: up to 20 filters (peak, low or high shelf, low or high pass, notch) with frequency, gain and Q, a preamp, and the response curve. **PARAM** switches between the faders and your parametric profile; with the profile in use, the rack shows its curve instead of the faders.
- **Headphone correction**: Presets › Headphones (built-in) has ready-made profiles. To add yours, drop one or several AutoEq / Equalizer APO `.txt` files on the editor, use Presets › Import, or copy the filter list and choose **Paste Filters from Clipboard** (`Preamp: -6.2 dB`, `Filter 1: ON PK Fc 100 Hz Gain -3 dB Q 0.7`). Imported files become saved presets. Your own settings can be saved and exported in the same format.
- **Compare (A/B)**: in the editor, load a profile in **A** and another in **B**, then switch with **A**, **B**, **Off** (keys 1, 2, 3) while the music plays. **Same loudness** lowers the louder choice to the level of the quieter one, so you judge the curve, not the volume. Switches are ramped: no click.
- A boost never clips: the loudest point of the curve is held at 0 dB by an automatic headroom (an AutoEq preamp already provides it). A flat equalizer changes nothing, to the last bit.
- Drag a fader or scroll over it; double-click returns it to 0 dB.
- **BYPASS** removes the equalizer; **FLAT** resets every band. A pre-gain is applied automatically when you boost, to avoid clipping.
- In DIRECT the equalizer is out (**EQ OUT · DIRECT**). Touching a fader or BYPASS leaves DIRECT.

![The parametric editor with the Compare (A/B) bar.](images/eq-editor.png)
*The parametric editor with the Compare (A/B) bar.*

## Analysis and trust

- **Audio Path** (Output › Audio Path, ⌥⌘A) lists every step from file to DAC, read live: each is transparent, alters the signal, or cannot be verified. **Verify** compares the samples sent to Core Audio with the file, one by one.
- **True resolution** (Scan in the same panel) reads the spectrum and the bits actually used: it shows a 96 kHz file that is really a 44.1 kHz master, a low-pass typical of MP3/AAC, or 16-bit content in a 24-bit file.
- **Loudness** is measured in the background for every track without ReplayGain tags (EBU R128), stored in the library, never written to your files.
- **Polarity** (Output): invert one track or all of them. It negates every sample exactly; the path then reads as modified.
- **Rate Change Delay** gives a DAC time to settle after a sample-rate change so the start of a track is not lost.
- **Lock Output** keeps playback off the speakers if your DAC disappears; it waits and reconnects paused. Each DAC remembers its own volume and limit, and a new one starts quietly.

![Audio Path with the equalizer and the DAC volume in play.](images/audio-path.png)
*Audio Path with the equalizer and the DAC volume in play.*

## ReplayGain

- Output › ReplayGain evens out loudness: **Track** levels every song, **Album** keeps the dynamics of an album.
- It needs ReplayGain tags in the files and never pushes peaks past full scale. It is off in DIRECT.

## Keyboard shortcuts

- **Space** play/pause · **⌘→** next · **⌘←** previous · **⌘O** open · **⇧⌘M** mute
- **⌥⌘M** compact player · **⌥⌘E** equalizer editor · **⌥⌘A** audio path
- **⇧⌘B** DIRECT · **⇧⌘D** dimmer · **⇧⌘P** power off
- **⌘1–⌘4** rack layout · **⌘- ⌘0 ⌘=** size · **⌃⌘F** fit screen · **⌘?** help

## Troubleshooting

- **No sound**: check Output, the knob position and the DAC's own volume. Other apps are silent on the DAC while DIRECT is on.
- **BIT-PERFECT stays off**: turn DIRECT on, check the signal path on the player for RESAMPLED or a lower bit depth.
- **Meters look slow**: press METER for PEAK mode; VU is slow by design.

![The built-in help (Help › Idiophile One Help), in English and French.](images/help.png)
*The built-in help (Help › Idiophile One Help), in English and French.*

## Menus

- **File**: Open… (⌘O) · Library (⌘L) · Close (⌘W) · Close All (⌥⌘W)
- **View**: Full Rack (⌘1) · Amplifier Only (⌘2) · Compact Player (⌥⌘M) · Network Player (⌘3) · Equalizer (⌘4) · Amplifier (⌘5) · Animate VU Meters · Animate Spectrum Analyzer · Small (⌘-) / Medium (⌘0) / Large (⌘=) · Fit Screen (⌃⌘F) · Finish ▸ Champagne, Black, Blue Glass
- **Output**: Output Device ▸ (System Default and every device found) · Lock Output · Rate Change Delay ▸ · Volume Limit ▸ · Invert Polarity of This Track (⌥⌘I) / of All Tracks · Measure Library Loudness · ReplayGain ▸ Off, Track, Album · Equalizer Editor… (⌥⌘E) · Audio Path… (⌥⌘A) · Scan True Resolution… · Verify Bit-Perfect Path… (⌥⌘V) · Direct (⇧⌘B)
- **Playback**: Source ▸ Library (⌃1), Internet Radio (⌃2), Network (⌃3) · Play / Pause (Space) · Next Track (⌘→) · Previous Track (⌘←) · Mute (⇧⌘M) · Power Off (⇧⌘P) · Dimmer (⇧⌘D)
- **Window**: Compact Player · Library · Equalizer · Audio Path
- **Help**: Idiophile One Help (⌘?)
- **Right-click** on the rack or the compact player: the same playback, source, output, sound, appearance and analysis commands in one menu.
