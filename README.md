<p align="center">
  <img src="Assets/Brand/xsComic-lockup.png" alt="xsComic" width="420">
</p>

**xsComic** is a native macOS reader for CBR/CBZ/etc. I cooked it up
because I wanted to read *Beastars* (sue me), didn't want unvetted
third-party software on my work partition, and realized because Codex
could make something passable in five minutes.

I then decided to run an experiment: can an LLM — tools (entities?)
that have gained infamy for their wild preference for adding lines
over deleting them — successfully write aggressively footprint-optimized
software? And can it write code that's "good," not simply "working"?
Recent models (post-January '26, basically) have seemed, perhaps,
capable of doing so.

*Reader, be advised: LLM writing is to follow.*

I believe the experiment to have been a success. Its result is a 510 KB app bundle,
about 220 KB of which is icon resources. It launches very quickly and includes no
third-party code. The source, from what I've seen, is legibile, well-structured,
and even educational. (The RAM footprint could still use some work.)

*Reader, be advised: human language stops here.*

## What it does

- opens CB7/7z, CBR/RAR, CBT/tar, CBZ/ZIP, and image directories
- reads one or two pages at a time, left-to-right or right-to-left
- offers keyboard controls, pinch-and-drag zooming, fit, and actual size
- includes a page sidebar, direct page jump, and adjacent-volume continuation
- prepares the pages you are most likely to turn to next

The minimum supported system is macOS 14.

## Give it a try

Build and open xsComic:

```sh
./scripts/build-and-run.sh
```

That is the whole getting-started procedure. The build uses SwiftPM and Apple's
developer tools; there is no Xcode project or dependency installation.

## If you are curious

The more technical material lives in [`docs/`](docs/):

- [the project guide](docs/guide.md) explains the features, architecture, and
  codebase;
- [the optimization record](docs/optimization.md) keeps the before-and-after
  measurements and the reasoning behind them;
- [the release procedure](docs/releasing.md) covers tests, packaging, signing,
  and notarization;
- [the raw metrics](Metrics/) preserve the machine-readable evidence.

## License

The software is **AGPL-3.0-or-later**. Documentation and measurements are
**CC BY-SA 4.0**. The xsComic name and everything under `Assets/` are expressly
excluded: no license is granted for the branding or character artwork. The
short, unambiguous map is in [`LICENSING.md`](LICENSING.md).

This is still a release candidate. Before publishing a binary, the project
needs a permanent bundle identifier, public support/security contact,
Developer ID signature, and notarization. Those decisions are left to the
eventual publisher rather than guessed here.
