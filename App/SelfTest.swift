//
//  SelfTest.swift
//  End-to-end check of the speech-provider extension THROUGH iOS, for development only - the method
//  ClassicVoices uses (App/SelfTest.swift there): ask the system for our voices, then render fixed
//  sentences with AVSpeechSynthesizer.write, the same path VoiceOver's audio takes, so this exercises
//  the extension's SSML parsing, rate mapping, the shared settings and the streaming.
//
//  Runs only when the app is launched with the argument -evSelfTest
//  (simulator: xcrun simctl launch --console <udid> com.quinton.eloquencevoices -evSelfTest;
//   device:    xcrun devicectl device process launch --console ... com.quinton.eloquencevoices -- -evSelfTest).
//  Prints one "EVSELFTEST ..." line per step to stdout, saves each render as Documents/selftest-<case>.wav,
//  then exits the process (so the console capture ends by itself). Never runs in normal use.
//
//  Cases (the stub makes every parameter audible, so each has a measurable expectation):
//   reed_default        the baseline: frames > 0, format reported, tone near 247 Hz. iOS sends NO
//                       rate for a default-rate utterance, so this is the "absent rate" path.
//   sandy_default       Sandy's preset ships at speed 70; at the default rate she must take exactly as
//                       long as Reed (same frame count): the preset's speed must not leak in.
//   reed_slow           utterance rate 0.25 -> a rate IS sent -> a longer render than the baseline
//   reed_after_slow     default rate straight after reed_slow: no rate sent, the 3 s memory applies ->
//                       still slow (the switched-voice announcement case, documented behaviour)
//   reed_after_wait     default rate 3.5 s after the last rated utterance: memory expired -> baseline
//                       length again (the "one setting does nothing" trap closed)
//   reed_high           pitchMultiplier 1.5 -> a higher tone than the baseline
//   shelley_default     a second voice, different (female) tone
//   glen_custom_pitch   the shared settings: Glen's pitch set to 30 in the app group before the case
//                       (preset 69) -> a lower tone than Glen's preset would give; restored afterwards
//   ssml_pause          VoiceOver's <s>label</s><s>trait</s> shape -> two tones with a gap between
//   ssml_scoped_pitch   an outer pitch="+0.0%" and a nested pitch="-15%" around the label only: the
//                       extension's `prosody` log line must show segPitch=[-2.81>.. 0.00>..] (scoped,
//                       2026-09-24), and its shape= field the structure with no words
//   dict_iphone         "iPhone" with the community dictionary switched ON for the case (restored after):
//                       the extension's status line says dict=on with the root entries handed over, if
//                       a release is installed (dict=off otherwise)
//   userdict_without / userdict_with   -evUserDictSelfTest, simulator only: "unread" without and with a
//                       user entry of the user's own (restored after) - the frame counts must differ
//  -evRateSelfTest (instead of the cases above): the OUTPUT SAMPLE RATE setting through the system path.
//   Each case sets the app group's rate first, then: on the same synthesizer as before / after
//   AVSpeechSynthesisProviderVoice.updateSpeechVoices() / on a NEW AVSpeechSynthesizer. Every case's line
//   carries the buffers' own format rate (what the host was really handed) and the extension's status
//   line its hz= and au= (which audio unit, made when, how many allocations): together they say when a
//   changed rate lands. The setting the run found is put back at the end.
//  -evToneSelfTest (instead of the cases above): the TONE controls (equalizer, Mellow) through the system path, at
//   22050 Hz: flat, Bright on a new synthesizer, treble +12 on the SAME synthesizer (a handle in use hears it on its
//   next utterance), Mellow on a new one, and everything back to the defaults (11025, flat, Mellow off) at the end.
//   Each render is saved for the Mac to measure bands on.
//  -evResetSound (development, devicectl): the sample rate, equalizer, treble, Mellow and Shorten pauses back to the defaults, and
//   exit - how a test value is put back without the rest of the self-test.
//  With -evDictSelfTest as well: before the cases, the app downloads/validates/installs the latest
//  release exactly as "Update now" does (network), then renders "iPhone and iMessage" in THIS process
//  with the dictionary off and on and reports both frame counts.
//  The extension's own log line per request (rateSource=ssml|voiceMemory|anyMemory|default and the
//  eight values it told the engine) is read back from the Mac:
//   xcrun simctl spawn <udid> log show --last 5m --predicate 'subsystem == "com.quinton.eloquencevoices"'
//

#if os(iOS)   // drives UIKit's idle timer; the Mac app has no self-test (as in Sapple)
import AVFoundation
import UIKit

enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-evSelfTest") }

    /// `-evSetRate <hz>` (development, devicectl): sets the output sample-rate setting and exits - how a test value is
    /// put back without the rest of the self-test (11025 = the native default, i.e. no stored value).
    static func handleSetRateArgument() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-evResetSound") {
            setvbuf(stdout, nil, _IONBF, 0)
            let before = soundSummary
            resetSound()
            report("EVSELFTEST reset sound: was \(before), now \(soundSummary)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return true
        }
        guard let i = args.firstIndex(of: "-evSetRate"), i + 1 < args.count, let hz = Int(args[i + 1]) else { return false }
        setvbuf(stdout, nil, _IONBF, 0)
        let before = store.sampleRate
        store.sampleRate = hz
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        report("EVSELFTEST set rate: was \(before), now \(store.sampleRate)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        return true
    }

    private struct Case {
        let name: String
        let voiceSlug: String
        var rate: Float? = nil            // nil = AVSpeechUtteranceDefaultSpeechRate
        var pitch: Float? = nil           // AVSpeechUtterance.pitchMultiplier
        var text = "Hello from Eloquence Voices."
        var ssml = false
        var before: (() -> Void)? = nil
        var after: (() -> Void)? = nil
        var delayBefore: TimeInterval = 0   // wait this long before starting (lets the rate memory expire)
        var newSynth = false                // a new AVSpeechSynthesizer for this case
        var settle: TimeInterval = 0        // wait this long AFTER `before` (e.g. after updateSpeechVoices)
    }

    private static let store = VoiceSettingsStore.shared
    private static let glen = ELOQUENCE_VOICES.first { $0.slug == "glen" }!

    private static var soundSummary: String {
        "rate=\(store.sampleRate) equalizer=\(store.tone.rawValue) treble=\(store.trebleDB) mellow=\(store.mellow)" +
            " pauses=\(store.shortenPauses.rawValue)"
    }
    private static func resetSound() {
        store.sampleRate = OutputSampleRate.native
        store.tone = .off
        store.trebleDB = 0
        store.mellow = false
        store.shortenPauses = .never
    }
    private static func setTone(_ t: ToneSetting, treble: Int = 0, mellow: Bool = false) {
        store.tone = t
        store.trebleDB = treble
        store.mellow = mellow
        report("EVSELFTEST tone now \(soundSummary)")
    }
    /// -evToneSelfTest (see the header). Short on purpose: it runs on a real phone.
    private static var toneCases: [Case] {
        [
            Case(name: "tone_flat_22k", voiceSlug: "reed", text: rateText,
                 before: { setRate(22050, update: false); setTone(.off) }, newSynth: true),
            Case(name: "tone_bright_22k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setTone(.bright) }, newSynth: true),
            Case(name: "tone_treble12_22k_same_synth", voiceSlug: "reed", text: rateText,
                 before: { setTone(.custom, treble: 12) }),
            Case(name: "tone_mellow_22k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setTone(.off, mellow: true) }, newSynth: true),
            Case(name: "tone_back_defaults_11k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { resetSound(); report("EVSELFTEST tone now \(soundSummary)") },
                 after: { resetSound(); report("EVSELFTEST defaults restored: \(soundSummary)") }, newSynth: true),
        ]
    }

    /// -evRate816SelfTest: 8000 against 16000 on NEW synthesizers (a new audio unit each, as a restarted VoiceOver gets),
    /// then the rate set before is put back exactly; nothing else (equalizer, treble, Mellow) is touched.
    private static let rateAtStart = store.sampleRate
    private static var rate816Cases: [Case] {
        [
            Case(name: "r816_8k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { _ = rateAtStart; setRate(8000, update: false) }, newSynth: true),
            Case(name: "r816_16k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setRate(16000, update: false) }, newSynth: true),
            Case(name: "r816_8k_again_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setRate(8000, update: false) },
                 after: { setRate(rateAtStart, update: false); report("EVSELFTEST his rate restored: \(soundSummary)") },
                 newSynth: true),
        ]
    }

    private static let cases: [Case] = ProcessInfo.processInfo.arguments.contains("-evRate816SelfTest") ? rate816Cases
        : ProcessInfo.processInfo.arguments.contains("-evToneSelfTest") ? toneCases
        : ProcessInfo.processInfo.arguments.contains("-evRateSelfTest") ? rateCases
        : ProcessInfo.processInfo.arguments.contains("-evCompareSelfTest") ? compareCases
        : baseCases + userDictCases

    /// -evCompareSelfTest: the five comparison sentences (the 2026-11-19 ReLoq evaluation's) through the
    /// system path at 11025, 22050 and 48000 Hz (Reed, default rate), each rate on a new synthesizer after the
    /// setting changed; selftest-cmp_<hz>_<name>.wav. The setting is put back at the end.
    private static let compareSentences: [(String, String)] = [
        ("fox", "The quick brown fox jumps over the lazy dog."),
        ("time", "Hello, it's 8:35 in the morning, and you have 3 new messages."),
        ("baker", "Dr. Smith lives at 221B Baker St., doesn't he?"),
        ("iphone", "VoiceOver, Safari, and iMessage are on my iPhone 16."),
        ("prose", "When I got to the station this morning, the train was already twenty minutes late, and nobody on the platform seemed to know why. A man next to me, holding a coffee in one hand and a newspaper in the other, said it happens every Thursday. I asked him whether he had ever complained, and he laughed. Why would I, he said, when the coffee here is this good?"),
    ]
    private static var compareCases: [Case] {
        var out: [Case] = []
        for hz in [11025, 22050, 48000] {
            for (i, (name, text)) in compareSentences.enumerated() {
                var c = Case(name: "cmp_\(hz)_\(name)", voiceSlug: "reed", text: text)
                if i == 0 {
                    c.before = { setRate(hz, update: true) }
                    c.newSynth = true
                    c.settle = 2
                }
                out.append(c)
            }
        }
        out[out.count - 1].after = { setRate(11025, update: true) }
        return out
    }

    /// -evRateSelfTest: when does a changed output rate reach the host? (see the header)
    private static func setRate(_ hz: Int, update: Bool) {
        store.sampleRate = hz
        report("EVSELFTEST rate setting now \(store.sampleRate) updateSpeechVoices=\(update)")
        // off the main thread (ContentView.rateChanged says why): run 2 on the Air stopped right here
        if update { DispatchQueue.global(qos: .utility).async { AVSpeechSynthesisProviderVoice.updateSpeechVoices() } }
    }
    private static let rateText = "The quick brown fox jumps over the lazy dog."
    private static var rateCases: [Case] {
        // Kept short on purpose (it runs on a real phone): one baseline, then each rate on a NEW synthesizer (a new audio
        // unit), one same-synthesizer case to show the old audio unit keeps its rate, and back to 11025 at the end -
        // explicitly 11025, not "whatever it was", so a run killed half way and rerun cannot preserve a test value.
        [
            Case(name: "rate_11k_first", voiceSlug: "reed", text: rateText,
                 before: { setRate(11025, update: false) }, newSynth: true),
            Case(name: "rate_22k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setRate(22050, update: false) }, newSynth: true),
            Case(name: "rate_48k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setRate(48000, update: false) }, newSynth: true),
            Case(name: "rate_16k_same_synth", voiceSlug: "reed", text: rateText,
                 before: { setRate(16000, update: false) }),
            Case(name: "rate_back_11k_new_synth", voiceSlug: "reed", text: rateText,
                 before: { setRate(11025, update: true) }, after: { setRate(11025, update: true) }, newSynth: true),
        ]
    }

    /// -evUserDictSelfTest, SIMULATOR ONLY: "unread" through the extension without and then with a user
    /// entry of the user's own ("unread" -> "un red", a real case) written to the app group's
    /// UserDictionary folder - proves the extension reads the user's files. The user's list is put back
    /// exactly as it was after the case. Never compiled into a run on a device, so nothing can be left
    /// in the user's dictionary by a killed run.
    private static var userDictCases: [Case] {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("-evUserDictSelfTest") else { return [] }
        return [
            Case(name: "userdict_without", voiceSlug: "reed", text: "unread"),
            Case(name: "userdict_with", voiceSlug: "reed", text: "unread",
                 before: {
                     guard let s = PronunciationDictionary.userStore else { report("EVSELFTEST no user store"); return }
                     savedUserEntries = s.load()
                     var list = savedUserEntries ?? []
                     list.append(DictionaryEntry(kind: .word, word: "unread", replacement: "un red"))
                     try? s.save(list)
                     report("EVSELFTEST user entry added for the case (\(list.count) entries)")
                 },
                 after: {
                     if let s = PronunciationDictionary.userStore, let saved = savedUserEntries {
                         try? s.save(saved)
                         report("EVSELFTEST user entries restored (\(s.load().count) entries)")
                     }
                 }),
        ]
        #else
        return []
        #endif
    }
    private static var savedUserEntries: [DictionaryEntry]?

    private static let baseCases: [Case] = [
        Case(name: "reed_default", voiceSlug: "reed"),
        Case(name: "sandy_default", voiceSlug: "sandy"),
        Case(name: "reed_slow", voiceSlug: "reed", rate: 0.25),
        Case(name: "reed_after_slow", voiceSlug: "reed"),
        Case(name: "reed_after_wait", voiceSlug: "reed", delayBefore: 3.5),
        Case(name: "reed_high", voiceSlug: "reed", pitch: 1.5),
        Case(name: "shelley_default", voiceSlug: "shelley"),
        Case(name: "glen_custom_pitch", voiceSlug: "glen",
             before: {
                 var s = EloquenceEngine.shared.presetSettings(for: glen)
                 s.pitch = 30
                 store.save(s, for: glen)
                 report("EVSELFTEST set glen settings: \(s.summary)")
             },
             after: { store.reset(for: glen); report("EVSELFTEST glen settings reset") }),
        Case(name: "ssml_pause", voiceSlug: "reed", text: "<speak><s>Speech</s><s>button</s></speak>", ssml: true),
        Case(name: "ssml_scoped_pitch", voiceSlug: "reed",
             text: #"<speak><prosody pitch="+0.0%"><s><prosody pitch="-15%">Message</prosody></s><s>Hello there</s></prosody></speak>"#,
             ssml: true),
        Case(name: "dict_iphone", voiceSlug: "reed", text: "iPhone",
             before: { dictWasOn = store.dictionaryEnabled; store.dictionaryEnabled = true
                       report("EVSELFTEST dictionary on for the case, installed=\(store.dictionaryTag ?? "none")") },
             after: { store.dictionaryEnabled = dictWasOn; report("EVSELFTEST dictionary restored to \(dictWasOn)") }),
    ]
    private static var dictWasOn = false

    private static var synth: AVSpeechSynthesizer?
    /// The utterance's end as the synthesizer reports it (didFinish), beside the empty end buffer of write(): on
    /// iOS 27.3 (iPhone Air, 2026-11-19) no empty buffer arrived and every case waited for its timeout, so a case now
    /// ends on whichever comes first and says which ("end=").
    private final class Finish: NSObject, AVSpeechSynthesizerDelegate {
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
            DispatchQueue.main.async { SelfTest.ended(by: "didFinish") }
        }
    }
    private static let finishDelegate = Finish()
    private static var endedBy = "-"
    private static var current: Case?
    static func ended(by how: String) {
        guard let c = current, !caseDone else { return }
        endedBy = how
        complete(c)
    }
    private static var systemVoices: [AVSpeechSynthesisVoice] = []
    private static var index = 0
    private static var samples: [Int16] = []
    private static var formatDescription = "-"
    private static var bufferCount = 0
    private static var started = Date()
    private static var caseDone = false
    private static var timeout: DispatchWorkItem?
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Every EVSELFTEST line goes to stdout AND to Documents/selftest-report.txt, so the report survives
    /// a console that never connects (simctl launch --console hung twice on 2026-09-22): read it from
    /// the Mac at `xcrun simctl get_app_container <udid> com.quinton.eloquencevoices data`/Documents.
    private static let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("selftest-report.txt")
    private static let reportLock = NSLock()
    static func report(_ line: String) {
        print(line)
        reportLock.lock(); defer { reportLock.unlock() }
        if let h = try? FileHandle(forWritingTo: reportURL) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (line + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        }
    }

    static func run() {
        // `simctl launch --console` hands the app a pipe, which stdio block-buffers: without this
        // nothing appears until the process exits, and a run that is killed prints nothing at all.
        setvbuf(stdout, nil, _IONBF, 0)
        try? FileManager.default.removeItem(at: reportURL)
        report("EVSELFTEST start engine=\(EloquenceEngine.engineDescription) sharedSettings=\(store.isShared) group=\(AppGroup.id)")
        UIApplication.shared.isIdleTimerDisabled = true
        // Launched from the Mac while the phone is in someone's hand, the app may not be in front: ask for
        // background time, or iOS can suspend it between two cases (both rate runs on the Air stopped after the
        // fourth case with the main thread idle, 2026-11-19).
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "EVSELFTEST") {
            report("EVSELFTEST background time ran out")
        }
        enginePass()
        for def in ELOQUENCE_VOICES {
            report("EVSELFTEST preset \(def.slug) engineName=\"\(EloquenceEngine.shared.engineVoiceName(for: def))\" \(EloquenceEngine.shared.presetSettings(for: def).summary)")
        }
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        if ProcessInfo.processInfo.arguments.contains("-evDictSelfTest") {
            Task { @MainActor in
                let status = await DictionaryUpdater.shared.updateForSelfTest()
                report("EVSELFTEST dictionary update: \(status) installed=\(store.dictionaryTag ?? "none") counts=\(store.dictionaryCounts)")
                dictionaryPass()
                enumerate(attempt: 1)
            }
        } else {
            enumerate(attempt: 1)
        }
    }

    /// In this process: "iPhone and iMessage" with the dictionary off, then on (fresh handles each).
    private static func dictionaryPass() {
        let reed = ELOQUENCE_VOICES[0]
        let req = EloquenceEngine.request(settings: store.settings(for: reed), sampleRate: OutputSampleRate.native)
        let was = store.dictionaryEnabled
        store.dictionaryEnabled = false
        PronunciationDictionary.configureEngine()
        EloquenceEngine.shared.releaseIdle()
        let off = EloquenceEngine.shared.synthesize(text: "iPhone and iMessage", voice: reed, request: req)
        store.dictionaryEnabled = true
        let t0 = Date()
        let configured = PronunciationDictionary.configureEngine()
        let t1 = Date()
        EloquenceEngine.shared.releaseIdle()
        let on = EloquenceEngine.shared.synthesize(text: "iPhone and iMessage", voice: reed, request: req)
        let t2 = Date()
        report(String(format: "EVSELFTEST dictionary inproc configured=%@ rootTable=%d configure=%.3fs firstUtteranceWithLoad=%.3fs off.frames=%d on.frames=%d differ=%@ %@",
                      configured ? "yes" : "no", ev_dict_root_entries(), t1.timeIntervalSince(t0), t2.timeIntervalSince(t1),
                      off?.count ?? -1, on?.count ?? -1, off == on ? "no" : "yes", EloquenceEngine.shared.dictionarySummary))
        store.dictionaryEnabled = was
        PronunciationDictionary.configureEngine()
    }

    /// The engine IN THIS PROCESS, before anything else touches it: what one instance costs, what an
    /// utterance costs, how fast it is. The render is saved as selftest-inproc-reed.wav: this is the
    /// engine's own output with nothing between (no audio unit, no host), the file to hold byte for
    /// byte against the Mac build's `evv -v 1 -s 50 -o x.wav "Hello from Eloquence Voices."`, and
    /// then the system-path render selftest-reed_default.wav against it.
    private static func enginePass() {
        let reed = ELOQUENCE_VOICES[0]
        let text = "Hello from Eloquence Voices."
        let m0 = EloquenceEngine.processFootprintMB()
        let t0 = Date()
        let settings = store.settings(for: reed)      // the dial: preset with speed 50
        let m1 = EloquenceEngine.processFootprintMB() // one instance open (pooled)
        let t1 = Date()
        let req = EloquenceEngine.request(settings: settings, sampleRate: OutputSampleRate.native)
        let first = EloquenceEngine.shared.synthesize(text: text, voice: reed, request: req)
        let t2 = Date()
        let m2 = EloquenceEngine.processFootprintMB()
        let second = EloquenceEngine.shared.synthesize(text: text, voice: reed, request: req)   // warm handle: state carries
        let t3 = Date()
        let m3 = EloquenceEngine.processFootprintMB()
        let n1 = first?.count ?? -1, n2 = second?.count ?? -1
        let d1 = Double(max(0, n1)) / EloquenceEngine.nativeSampleRate
        report(String(format: "EVSELFTEST engine reed settings[%@] open=%.3fs first: frames=%d dur=%.3fs synth=%.3fs rtf=%.0fx  second: frames=%d synth=%.3fs identical=%@  memMB start=%.1f instance=%.1f spoken=%.1f second=%.1f",
                      settings.summary, t1.timeIntervalSince(t0), n1, d1, t2.timeIntervalSince(t1),
                      t2.timeIntervalSince(t1) > 0 ? d1 / t2.timeIntervalSince(t1) : 0,
                      n2, t3.timeIntervalSince(t2), (first == second) ? "yes" : "no", m0, m1, m2, m3))
        if let first {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("selftest-inproc-reed.wav")
            try? WAVFile.data(first, sampleRate: OutputSampleRate.native).write(to: url)
        }
    }

    /// The system's voice list is refreshed asynchronously: ask, wait, ask again (up to ~20 s).
    private static func enumerate(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let all = AVSpeechSynthesisVoice.speechVoices()
            let ours = all.filter { $0.identifier.contains(ELOQUENCE_VOICE_ID_PREFIX) }
            report("EVSELFTEST voices attempt=\(attempt) total=\(all.count) ours=\(ours.count)")
            if ours.isEmpty && attempt < 5 {
                enumerate(attempt: attempt + 1)
                return
            }
            for v in ours {
                report("EVSELFTEST voice id=\(v.identifier) name=\"\(v.name)\" language=\(v.language) gender=\(v.gender.rawValue) quality=\(v.quality.rawValue)")
            }
            // Apple's own Eloquence voices carry the bare names; list any that share ours.
            let bare = Set(ELOQUENCE_VOICES.map { VoiceCatalog.shortName($0) })
            for v in all where !v.identifier.contains(ELOQUENCE_VOICE_ID_PREFIX) && bare.contains(v.name) {
                report("EVSELFTEST apple-voice-with-same-name id=\(v.identifier) name=\"\(v.name)\" language=\(v.language)")
            }
            systemVoices = ours
            synth = AVSpeechSynthesizer()
            synth?.delegate = finishDelegate
            index = 0
            next()
        }
    }

    private static func next() {
        guard index < cases.count else {
            report("EVSELFTEST done cases=\(cases.count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return
        }
        let c = cases[index]
        c.before?()
        if c.settle > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + c.settle) { start(c) }
        } else {
            start(c)
        }
    }

    private static func start(_ c: Case) {
        guard let voice = systemVoices.first(where: { $0.identifier.hasSuffix("." + c.voiceSlug) }) else {
            report("EVSELFTEST case=\(c.name) FAIL voice not found")
            finish(c)
            return
        }
        guard let u = c.ssml ? AVSpeechUtterance(ssmlRepresentation: c.text) : AVSpeechUtterance(string: c.text) else {
            report("EVSELFTEST case=\(c.name) FAIL bad SSML")
            finish(c)
            return
        }
        u.voice = voice
        if c.newSynth { synth = AVSpeechSynthesizer(); synth?.delegate = finishDelegate }
        current = c
        endedBy = "-"
        if let r = c.rate { u.rate = r }
        if let p = c.pitch { u.pitchMultiplier = p }
        samples = []
        bufferCount = 0
        formatDescription = "-"
        caseDone = false
        started = Date()
        report("EVSELFTEST start case=\(c.name) voice=\(voice.identifier)")

        let t = DispatchWorkItem {
            guard !caseDone else { return }
            endedBy = "timeout"
            report("EVSELFTEST case=\(c.name) TIMEOUT after 20 s, buffers=\(bufferCount) frames=\(samples.count)")
            synth?.stopSpeaking(at: .immediate)
            complete(c)
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: t)

        synth?.write(u) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                DispatchQueue.main.async { ended(by: "emptyBuffer") }
                return
            }
            bufferCount += 1
            formatDescription = "rate=\(Int(pcm.format.sampleRate)) ch=\(pcm.format.channelCount) fmt=\(pcm.format.commonFormat.rawValue) interleaved=\(pcm.format.isInterleaved)"
            append(pcm)
        }
    }

    private static func append(_ pcm: AVAudioPCMBuffer) {
        let n = Int(pcm.frameLength)
        if let f = pcm.floatChannelData {
            // The extension scaled Int16 by 1/32768; scale back and round so an untouched sample
            // round-trips EXACTLY (byte comparison against the engine's own render depends on it).
            for i in 0..<n { samples.append(Int16(max(-32768, min(32767, (f[0][i] * 32768).rounded())))) }
        } else if let s = pcm.int16ChannelData {
            for i in 0..<n { samples.append(s[0][i]) }
        } else if let s = pcm.int32ChannelData {
            for i in 0..<n { samples.append(Int16(s[0][i] >> 16)) }
        }
    }

    private static func complete(_ c: Case) {
        guard !caseDone else { return }
        caseDone = true
        timeout?.cancel()
        let elapsed = Date().timeIntervalSince(started)
        let rate = Double(formatDescription.split(separator: " ").first.flatMap { Int($0.dropFirst(5)) } ?? OutputSampleRate.native)
        let duration = Double(samples.count) / max(1, rate)
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        report(String(format: "EVSELFTEST case=%@ end=%@ buffers=%d frames=%d %@ duration=%.3fs zcHz=%.0f peak=%d elapsed=%.2fs rtf=%.1fx",
                     c.name, endedBy, bufferCount, samples.count, formatDescription, duration, zeroCrossingHz(rate: rate), peak,
                     elapsed, elapsed > 0 ? duration / elapsed : 0))
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selftest-\(c.name).wav")
        try? WAVFile.data(samples, sampleRate: Int(rate)).write(to: url)
        finish(c)
    }

    private static func finish(_ c: Case) {
        c.after?()
        index += 1
        let delay = 0.3 + (index < cases.count ? cases[index].delayBefore : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
    }

    /// A rough fundamental estimate over the loud part of the render: zero crossings per second / 2.
    private static func zeroCrossingHz(rate: Double) -> Double {
        let loud = samples.filter { abs(Int($0)) > 0 }
        guard loud.count > 2 else { return 0 }
        var crossings = 0
        for i in 1..<loud.count where (loud[i - 1] < 0) != (loud[i] < 0) { crossings += 1 }
        return Double(crossings) / 2.0 / (Double(loud.count) / rate)
    }
}
#endif
