# Architecture

Idiophile One is a native macOS app: SwiftUI and AppKit for the interface, AVFoundation and
Core Audio for sound, SQLite for the library. No third-party code.

## Signal path

```
file / radio / DLNA
  → decoder (AVAudioFile, or the in-app MP3/AAC radio decoder)
  → AVAudioPlayerNode
  → ParametricEQUnit   equalizer filters + preamp/headroom + ReplayGain + A/B level match;
                       bypassed (samples copied untouched) when nothing is in use
  → tap                VU / PEAK meters and spectrum analyser
  → main mixer         digital volume when the DAC has none; a negative gain inverts polarity
  → output device      sample rate and integer format set to match the file; exclusive in DIRECT
```

`SignalPath` is the single description of these settings. Playback configures its units from it,
the **Audio Path** panel reports it, and `BitPerfectVerifier` renders the file offline through
the very same units to compare the samples with the source, one by one.

## Source layout

| Area | Files |
|---|---|
| App, menus, windows | `App/IdiophileOneApp.swift`, `App/Model/AmpModel.swift` (panel state, sources, session) |
| Engine | `App/Audio/PlayerEngine.swift`: queue, gapless, equalizer and ReplayGain, volume, DIRECT, devices, locked output, per-DAC profiles, meters, A/B audition |
| Equalizer | `EQ.swift` (filters, RBJ biquads, profiles, AutoEq parser, presets), `ParametricEQUnit.swift` (real-time `AUAudioUnit` registered in-process), `Facade/EQEditorView.swift`, `Facade/EQPlot.swift` |
| Signal description and proof | `SignalPath.swift`, `AudioPath.swift`, `BitPerfectVerifier.swift` |
| Core Audio | `OutputDevice.swift` (rates, formats, hardware volume, exclusive access), `VolumeSafety.swift` (pure rules) |
| Analysis | `Loudness.swift` (BS.1770 / EBU R128), `ResolutionScan.swift`, `MeterPhysics.swift` |
| Tags | `FLACMetadata.swift`, `Library/TagReader.swift` |
| Library | `Library/*`: SQLite wrapper, FTS5 search, incremental scan, artwork cache |
| Radio | `Radio/*`: radio-browser.info client, stream ranking, ICY + AudioFileStream decoder, AVPlayer fallback |
| Network | `Network/*`: SSDP discovery, ContentDirectory browsing, servers added by address |
| Interface | `Facade/*`: rack, amplifier, needles (Core Animation), player, equalizer, compact player, right-click menu, finishes |
| Help | `Help/HelpView.swift` (English and French; source of `docs/USER-GUIDE*.md`) |

## Design decisions worth knowing

- **Nothing is assumed.** The Audio Path is read from the running units and from Core Audio at
  the moment it is shown; a step that cannot be read is shown as unknown, never as a guarantee.
- **Volume on the DAC.** When the DAC has a hardware volume, the knob drives it, so the samples
  stay untouched. A USB DAC resets its volume when it re-enumerates: increases above 4 dB that
  the app did not ask for are refused, and the echo of the app's own writes is ignored.
- **A DAC's identity contains its USB port.** A single connected device with the saved name is
  adopted as the same DAC; its saved settings follow.
- **Exclusive access changes the system default output** on macOS; DIRECT therefore pins the
  output device.
- **AVPlayer audio taps never see live streams**, hence the app's own MP3/AAC radio decoder.
  An AAC decoder takes one packet per input request, so packets are fed one by one.
- **Real-time safety.** The equalizer unit reads new settings with a try-lock and applies them
  on the next buffer; gain changes are ramped across a buffer, so switching presets does not click.
- **Each 1 Hz refresh of a SwiftUI view costs about 1 % of a core** on the author's MacBook Pro
  (the whole display list is walked): clocks tick once per second, and meters can be frozen.

## Limits by design (for now)

- The engine computes in 32-bit float: 24 bits of precision. Sources above 24 bits are rounded
  and reported as such; the verifier refuses to "prove" more than it can.
- Gapless playback is pre-scheduled; ReplayGain or polarity cannot switch on the exact boundary
  sample, so a track pair whose gains differ is not strictly gapless.
