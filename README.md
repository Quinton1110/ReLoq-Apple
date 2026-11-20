# ReLoq Apple

ReLoq Apple is an iPhone, iPad and Mac app that adds ReLoq C voices to the system, so VoiceOver and Spoken Content (Speak Screen, Speak Selection) can use them. ReLoq C is Karl Eick's speech engine, written in C, that keeps the familiar character of Eloquence; it also runs in NVDA, on Android and as a Windows SAPI5 voice.

It offers 14 languages with 8 voices each, 112 system voices in all. The voices are Reed, Shelley, Bobby, Rocko, Glen, Sandy, Grandma and Grandpa, and each name ends in "(ReLoq)", for example "Reed (ReLoq)", so they are easy to tell apart from Apple's own Eloquence voices.

The languages are English (United States), English (United Kingdom), Spanish (Spain), Spanish (Latin America), French (France), French (Canada), German, Italian, Portuguese (Brazil), Finnish, Greek, Chinese (Mandarin, also offered for Traditional Chinese), Japanese and Korean. Polish is not available, because ReLoq C has no Polish.

## Just want to use it?

Ready to install builds are on the downloads page: https://quintonwilliams.me/reloq-apple/

- iPhone and iPad: [ReLoq-Apple-0.1.1.ipa](https://quintonwilliams.me/reloq-apple/ReLoq-Apple-0.1.1.ipa)
- Mac, Apple Silicon only: [ReLoq-Apple-0.1.1-mac.zip](https://quintonwilliams.me/reloq-apple/ReLoq-Apple-0.1.1-mac.zip)
- AltStore source: `https://quintonwilliams.me/reloq-apple/source.json`

The downloads page lists each file's size and SHA-256.

The community pronunciation dictionary is downloaded straight from its GitHub project (IBMTTSDictionaries), not bundled with the app.

These builds contain engine language data that is not owned by this project. ReLoq C's own notices say parts of its language rules and data are transcribed from IBM's Embedded ViaVoice and from the ETI Eloquence 6.1 language modules Apple ships with its operating systems. That data isn't covered by this project's licence or ReLoq C's, and it will be removed if a rights holder asks. NOTICE has the details.

AltStore, using the source (stays installed, refreshes itself over Wi-Fi, and shows updates):

1. Install AltServer on your Mac or PC from [altstore.io](https://altstore.io/), then use it to put AltStore on your iPhone.
2. In AltStore, go to the Sources screen and tap the plus button.
3. Paste `https://quintonwilliams.me/reloq-apple/source.json` and add it.
4. Open the ReLoq Apple source, tap Free or Get next to ReLoq Apple, and sign in with your Apple ID if asked.
5. Open ReLoq Apple once. Keep AltServer running so AltStore can refresh the app before it expires.

AltStore also installs the IPA directly: download it, then in My Apps tap the plus button and pick the file.

SideStore reads the same source. Add it in SideStore the same way. SideStore refreshes apps on the phone itself, so after its one time setup you don't need a computer to keep ReLoq Apple running.

Sideloadly (quick one time install):

1. Install Sideloadly on your Mac or PC from [sideloadly.io](https://sideloadly.io/).
2. Connect your iPhone with a cable and open Sideloadly.
3. Drag the IPA in, enter your Apple ID, and click Start.
4. On your iPhone, open Settings, then General, then VPN and Device Management, and trust your developer profile.
5. Open ReLoq Apple once.

With a free Apple ID the app stops working after 7 days and has to be reinstalled. A paid Apple Developer account keeps it running for a year.

On the Mac, the download is signed and notarized. Unzip it, put ReLoq Apple in Applications and open it once so macOS picks up the voices. Leave it there, since macOS finds the voices through the app. The Mac app needs an Apple Silicon Mac; it does not run on an Intel Mac.

## Requirements

- iPhone or iPad with iOS 18 or later.
- Mac with Apple silicon and macOS 15 or later.

## Use it as a system voice

Open the app once. Then choose a voice whose name ends in "(ReLoq)":

- VoiceOver on iPhone: Settings, Accessibility, VoiceOver, Speech, Voice.
- VoiceOver on the Mac: VoiceOver Utility, Speech.
- Spoken Content: Settings, Accessibility, Spoken Content, Voices.

On the Mac, keep the app in the Applications folder: the voices live inside it.

## Settings

Changes reach the voice the next time it speaks, except the sample rate (below).

- Language and voice: which of the 112 voices the settings below apply to.
- Voice settings: head size, pitch, pitch range, roughness, breathiness, speed and volume for each voice, with a button to go back to the voice's defaults. A preview with its own speaking rate lets you hear a change before VoiceOver uses it.
- Pronunciation dictionary: an optional community dictionary (IBMTTSDictionaries), off until you switch it on, downloaded straight from its GitHub project rather than bundled with the app, with automatic updates daily, weekly or monthly, and "Update now". "Dictionary entries" lists every community entry and lets you add, change or remove your own words, with Listen on each.
- Sample rate: 8 kHz, 11 kHz (the classic sound and the default), 16, 22, 32, 44.1 or 48 kHz. ReLoq C makes the speech at each rate itself; nothing is resampled. VoiceOver takes a new rate only when VoiceOver restarts (see Observations). The preview uses it at once.
- Equalizer: Off, Bright or Custom. Bright is the preset from ReLoq's Android app (treble up 4 dB, bass down 1 dB). Custom shows a Treble slider, from minus 12 to plus 12 dB.
- Mellow mode: ReLoq's mellower sound, a little less energy around 3 to 5 kHz. It is offered at 16 kHz and above, because below that it does nothing.
- Phrase prediction: pauses in long sentences that have no punctuation. On by default.
- Enable backquote voice tags: lets text change the voice with Eloquence-style backquote tags, as NVDA's option does. Off by default.

## Observations

Quinton's, from using it with VoiceOver on his iPhone:

- To me it sounds essentially identical to Eloquence.
- On iOS the sample rate setting makes very little audible difference, even 8 kHz against 16 kHz. In Code Factory's Eloquence for Android, going from 8 to 16 kHz was miles different. I'm not sure how ReLoq's own Android app handles it.
- VoiceOver only picks up a sample rate change after VoiceOver restarts.

What we measured behind those (on an iPhone and on a Mac; the iPhone's output was sample for sample the Mac's at the same settings):

- The engine's output really is different at 8 and 16 kHz. At 8 kHz it is genuinely band-limited, with nothing above 4 kHz. But ReLoq piles energy just under 4 kHz, about 4 dB more there than at 16 kHz, so 8 kHz does not come out as a dull, telephone-like version of 16 kHz.
- At 16 kHz and above, ReLoq deliberately keeps the 11 kHz sound: it carries the 11 kHz voice over to the wider rate rather than resampling, and adds only weak content above 5.5 kHz.
- Bright adds about 4 dB of top end, from 3 kHz up, and takes under 1 dB off the bass.
- VoiceOver makes one audio unit (the piece of the app that speaks for it) when it starts, and keeps it. The app does not change the rate of an audio unit that is in use, because speech made at another rate would play at the wrong speed. So a rate chosen later reaches VoiceOver only when VoiceOver restarts. A newly made speech synthesizer, such as the app's own preview, uses the new rate straight away. The equalizer and Mellow mode apply to the next thing said, VoiceOver included.
- The Android comparison above is Code Factory's Eloquence, a different engine from ReLoq C. How ReLoq's own Android app sounds at 8 and 16 kHz has not been compared; it sets the rate through the same engine parameter as this app.

## Engine fixes this app carries

ReLoq C is used at release 1.4.1 with three fixes for Apple platforms (Engine/README.md has the details). The two that matter most:

- Silence after many interruptions, ported from openEVV. On Apple systems the engine never gave back the 4 MB of working memory it sets aside for each thread that speaks through it. A host that cut speech off from new threads used up the engine's memory after about 64 of them, and the voice stayed silent until it was restarted. Now that memory is freed when the thread ends.
- A crash in setNonSequential on Apple arm64. One rule function takes a variable number of arguments but is called as if it had fixed ones. Apple's arm64 passes such arguments differently from Android and Linux, so the function read garbage: the iPhone crashed creating its first US English voice, and a build without link-time optimisation gave wrong or refused speech. On Apple arm64 it now takes fixed arguments. Other platforms are unchanged.

The third is a Mac and iPhone version of a small piece of assembly that was written for Linux and Android only. All three are proposed to ReLoq C upstream. The build script for Apple platforms is in this repository (Engine/apple.mk).

## Building

You need a Mac with Apple silicon, Xcode (built with Xcode 27.2) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
git clone --recurse-submodules https://github.com/Quinton1110/ReLoq-Apple.git
cd ReLoq-Apple
make engine        # builds ReLoq C for iPhone, the simulator and the Mac (a few minutes)
make test          # Mac tests: the C bridge, the SSML parser, the user dictionary
xcodegen generate  # writes EloquenceVoices.xcodeproj
```

Then build the `EloquenceVoices` scheme for iPhone or the `EloquenceVoices-macOS` scheme for the Mac, in Xcode or with xcodebuild. To check that it builds without signing:

```
xcodebuild -project EloquenceVoices.xcodeproj -scheme EloquenceVoices -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project EloquenceVoices.xcodeproj -scheme EloquenceVoices-macOS -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

If you cloned without `--recurse-submodules`, run `git submodule update --init` first. After `make engine`, `make engine-test DICT_DIR=Engine/Reloq-C/data/community` runs the real engine through the bridge on the Mac, using the copy of the community dictionary that ReLoq C carries.

To sign it yourself, change `DEVELOPMENT_TEAM` in project.yml to your team, and change the bundle identifiers (`com.quinton.eloquencevoices` and the two under it) and the app group (in the entitlements files and `Shared/AppGroup.swift`) to ones your team owns. The app and its speech extension share their settings through that app group. A copy installed through AltStore or SideStore is given a different group by them, which the app reads from their `ALTAppGroups` list in its Info.plist.

The project, scheme and bundle identifiers still say EloquenceVoices, the app's name before it moved to ReLoq C. They are kept on purpose: an installed copy updates in place and keeps its voice choice and settings.

## Releasing

One command builds and publishes a release: the IPA, the notarized Mac zip, the AltStore / SideStore source and the downloads page.

```
make release VERSION=0.1 NOTES="What's new in this version." DRYRUN=1   # build and show the changes, publish nothing
make release VERSION=0.1 NOTES="What's new in this version."            # the real thing
```

It needs the engine built (`make engine`), and the server and notarization settings in `tools/release.local` (the list is at the top of `tools/release.sh`). It sets the version in `project.yml` and the next build number, builds both apps, reads the version back out of the built apps, adds the new entry to the top of `source.json`, updates the page, backs both up on the server before replacing them, and checks the live source and the IPA download afterwards. The first release starts the source and the page from `tools/release/`. It refuses a version that is already in the source. A dry run only reads the server; add `NOTARIZE=1` to notarize in it too, and `SKIPBUILD=1` to a later release to publish exactly those files. AltStore and SideStore show the update the next time they refresh the source. Commit and push `project.yml` and `README.md` afterwards, so the published source matches the published builds.

Mac updates through Sparkle aren't set up yet; Mac users download the new zip from the page.

## Credits

- Engine: [ReLoq C](https://github.com/hozosch/Reloq-C) by Karl Eick and ReLoq C contributors, GPL-3.0-or-later.
- [openEVV](https://github.com/Mudb0y/openevv) by Stanislaw Przedzinkowski and contributors, MIT: ReLoq C vendors a copy of it, the silence fix comes from it, and so does the US English text pre-pass this app runs before ReLoq C (Shared/Bridge/ev_marks.inc).
- Community pronunciation dictionary: [IBMTTSDictionaries](https://github.com/eigencrow/IBMTTSDictionaries) by eigencrow and contributors, CC0 (public domain). The app downloads it only when you switch it on.

## Licence

ReLoq Apple is free software under the GNU General Public License, version 3 or (at your option) any later version. See LICENSE. ReLoq C is GPL as well, and the app ships its licence notices.

Some of the language data compiled into the engine comes from IBM's and Apple's Eloquence and is not covered by any licence here or in ReLoq C. NOTICE explains this. Not affiliated with IBM, Cerence, Nuance, Microsoft or Apple. Eloquence is a trademark of its respective owner.
