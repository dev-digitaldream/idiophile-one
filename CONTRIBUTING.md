# Contributing

Thank you for helping. Idiophile One is in alpha: bug reports from real hardware are the most
valuable contribution right now.

## Reporting a bug

Open an [issue](https://github.com/dev-digitaldream/idiophile-one/issues/new/choose) and include:

- macOS version and Mac model;
- the DAC or output used (name, connection), and whether DIRECT was on;
- the file format (for example FLAC 24/96) or the radio stream;
- what you did, what you expected, what happened;
- a screenshot of **Output › Audio Path** when the problem is about sound.

## Code

1. Read [docs/BUILDING.md](docs/BUILDING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
2. Keep the existing style: small doc comments that explain *why*, no new dependency without
   discussion, nothing that runs on the audio thread may allocate or wait on a lock.
3. Claims must be verifiable: if a change affects the samples, extend the tests (the bit-perfect
   and equalizer tests show how to render through the real units) and keep the Audio Path honest.
4. If you change the in-app help, run `scripts/gen-guide.py` so the online guide follows.
5. Run the tests before opening a pull request.

Never copy code, assets or text from other players, including closed-source ones. Learning what
a feature does is fine; reproducing their implementation is not.

By contributing you agree that your work is licensed under the GPL-3.0-or-later.
