# Building Idiophile One

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 5 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

There is no other dependency: the app uses system frameworks only (SwiftUI, AppKit,
AVFoundation, Core Audio, the system `libsqlite3`).

## Build and run

```sh
git clone https://github.com/dev-digitaldream/idiophile-one.git
cd idiophile-one
xcodegen generate            # writes IdiophileOne.xcodeproj from project.yml
open IdiophileOne.xcodeproj  # then Run (⌘R)
```

Build a Release copy and install it in `/Applications` in one step:

```sh
scripts/install.sh
```

Run the app from `/Applications`: macOS then shows its icon and keeps its settings for that copy.

## Tests

```sh
xcodebuild test -project IdiophileOne.xcodeproj -scheme IdiophileOne -destination 'platform=macOS'
```

The tests cover volume safety, the volume knob law, ReplayGain, meter ballistics, the FFT, the
equalizer maths and its real-time unit, bit-perfect renders, EBU R128 reference signals, the
true-resolution scanner, radio stream ranking and polarity. They run in an app host; no DAC is
needed and none is touched.

## Release packages

```sh
scripts/release.sh 0.1.0-alpha.1
```

builds a universal (Apple silicon + Intel) Release, signs it ad hoc, and writes to `dist/`:
a `.dmg`, a `.zip` and `SHA256SUMS.txt`. Without an Apple Developer ID the app is not notarised;
users must allow it once (see the README).

## Useful while developing

- `IDIOPHILE_OPEN=<file or folder>` in the environment opens music at launch.
- Settings: `defaults read dev.digitaldream.idiophile-one`.
- Library database: `~/Library/Application Support/Idiophile One/library.sqlite`.
- User EQ presets: `~/Library/Application Support/Idiophile One/EQPresets.json`.
- `scripts/gen-guide.py` regenerates `docs/USER-GUIDE*.md` from the in-app help: edit the help
  in `App/Help/HelpView.swift`, then run the script.
