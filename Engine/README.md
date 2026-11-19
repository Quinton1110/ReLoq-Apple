# The engine

The speech engine is **ReLoq C** by Karl Eick (https://github.com/hozosch/Reloq-C, GPL-3.0-or-later). It is
in this repository as a git submodule, `Engine/Reloq-C`, pinned to the exact commit the app is built
with: ReLoq C release 1.4.1 (upstream commit 5d56224) with three fixes for Apple platforms on top. The build
script for Apple platforms, `Engine/apple.mk`, is in this repository.

| change | file in ReLoq C | what it fixes |
|---|---|---|
| silence fix (from openEVV) | `vendor/openevv61/src/port/evv_arena.c` | On Darwin a thread's `__thread` storage is gone before the pthread key destructor runs, so a caller thread's 4 MB frame stack was never given back. A host that cuts utterances off from fresh threads used up the engine's 256 MB region and the voice went silent for good after about 64 interruptions. On Apple platforms the frame stack is now the key's value and the destructor frees that. |
| Apple arm64 assembly | `vendor/openevv61/src/port/evv_land.c` | The arm64 landing pair was written for ELF only and did not assemble for iOS or macOS. A Mach-O variant: same registers and layout, x18 left alone (Apple's reserved platform register). |
| setNonSequential | `vendor/openevv61/src/eci/bridge/eci_deltainit2.c` | A variadic rule primitive called through a fixed prototype. Apple's arm64 passes variable arguments on the stack, so it read garbage: a crash creating the first US English voice on an iPhone, and wrong or refused speech in a build without LTO. On Apple arm64 it now takes fixed arguments. Other platforms are unchanged. |

All three are proposed to ReLoq C upstream as one pull request (branch `apple-fixes`). Until they are merged,
the submodule points at that branch of a fork, https://github.com/Quinton1110/Reloq-C; once they are, it can
point at https://github.com/hozosch/Reloq-C itself.

## Building it

```
git submodule update --init      # once, after cloning
make engine                      # a few minutes: the three slices, with ThinLTO
```

`make engine` runs `Engine/apple.mk` on the submodule's sources (static libraries for iPhone, the iPhone
simulator and Apple-silicon Macs, built in `build/reloq`, nothing written into the submodule) and copies the
result to where project.yml looks for it (both are build products and are not committed):

| path | what |
|---|---|
| `Engine/reloq.xcframework/` | `ios-arm64`, `ios-arm64-simulator`, `macos-arm64`, each one `libreloq.a` |
| `Engine/reloq-include/` | `eci.h`, `reloq_eci.h`, and `reloq_build.h` (the ReLoq C commit and release) |

`reloq_build.h` puts the ReLoq C commit into the engine line the app shows under "This build" (and the
extension writes into its status file), for example `ReLoq C 1.4.1 ECI 1.2.2 build Reloq-C@e79b00c`, so a
build always says which engine source it contains. If the submodule has uncommitted changes the line ends in
`+dirty`.

## How it is linked

`Shared/Bridge/ev_bridge.c` has two halves behind one interface (`ev_bridge.h`): the real engine when
`ELOQUENCE_ENGINE` is defined, and a stub tone generator otherwise (what `make test` checks on the Mac). The
bridge and the engine are ONE dynamic framework, `EloquenceEngine.framework` (project.yml targets
`EloquenceEngine` / `EloquenceEngine-macOS`), embedded once in the app's Frameworks folder and loaded by both
the app and the speech extension. It exports only the bridge's `ev_` names (`Shared/Bridge/ev_bridge.exports`).
The engine's own `eci` names are hidden inside it.

`make engine-check` compiles the engine half against ReLoq C's header; `make engine-test` links it against
the Mac slice and runs it (pitch in hertz, the dictionary by phonemes, phrase prediction, voice tags).

## What the engine path in ev_bridge.c does

- `eciNewEx(language)`, `eciRegisterCallback`, `eciSetOutputBuffer` FIRST (no buffer = `eciAddText`
  refuses; the engine has no audio device on iOS).
- Per utterance: the sample rate (ECI rate code 0-6) only when it changed; `eciCopyVoice(h, preset, 0)`;
  the eight `eciSetVoiceParam(h, 0, i, value)` in eci.h's order; the tone controls only when they differ
  from what the instance has; `eciAddText` (Windows-1252, the Latin-script languages) or `eciAddTextUtf8`
  (Chinese, Japanese, Korean, Greek); `eciSynthesize`.
- Cancel: the callback returns `eciDataAbort` when the audio stream refuses the chunk (the utterance was
  cancelled); ReLoq C reports that as a failure, which the bridge treats as a stop. After a stopped
  utterance the bridge speaks one letter into nothing on that instance, so the next real request does not
  pay ReLoq's reset (about 10 ms) before its first sound.
- US English text goes through openEVV's text pre-pass first (`Shared/Bridge/ev_marks.inc`): units read as
  letters where they are not units, file names and e-mail addresses read as words, and so on.
- Threads: one utterance at a time per handle; `EloquenceEngine.swift` pools handles per voice, on threads
  the extension owns.
- Privacy: nothing logs or stores the text it speaks. The extension writes structure and numbers only
  (rate, voice, audio unit, timings, memory) to `Documents/engine-status.txt` in its own container.
