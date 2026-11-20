//
//  ContentView.swift
//  The app: pick a voice, adjust its eight engine dials (shared with the speech-provider extension
//  through the app group), preview, and manage the pronunciation dictionary. No VoiceOver hints and
//  no explanatory footers (a control's label has to stand alone; the last four went 2026-11-19).
//  Follows ClassicVoices' settings screen: plain
//  SwiftUI Form controls that VoiceOver drives natively - Picker, Slider with `step:` and an `.accessibilityValue` that speaks the real
//  number (without both, VoiceOver jumps 10% and announces a bare percentage), Toggle, Button.
//  No custom controls.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var voiceIndex = 0
    @State private var language = ELOQUENCE_US_ENGLISH
    @State private var settings = VoiceSettings(gender: 0, headSize: 50, pitch: 65, pitchRange: 30,
                                                roughness: 0, breathiness: 0, speed: 50, volume: 92)
    @State private var isCustomised = false
    @State private var previewRate: Double = 0.5      // slider fraction, the scale VoiceOver uses
    @State private var text: String = ""
    @State private var isBusy = false
    @State private var status = ""
    @State private var player: AVAudioPlayer?         // retained so playback isn't cut off
    @State private var loading = true                 // suppress saves while the current voice loads
    @State private var dictEnabled = VoiceSettingsStore.shared.dictionaryEnabled
    @State private var dictAutoUpdate = VoiceSettingsStore.shared.dictionaryAutoUpdate
    @State private var dictFrequency = VoiceSettingsStore.shared.dictionaryUpdateFrequency
    @State private var voiceTags = VoiceSettingsStore.shared.voiceTagsEnabled
    @State private var phrasePrediction = VoiceSettingsStore.shared.phrasePredictionEnabled
    @State private var sampleRate = VoiceSettingsStore.shared.sampleRate
    @State private var tone = VoiceSettingsStore.shared.tone
    @State private var trebleDB = VoiceSettingsStore.shared.trebleDB
    @State private var mellow = VoiceSettingsStore.shared.mellow
    @State private var shortenPauses = VoiceSettingsStore.shared.shortenPauses
    @StateObject private var dictionary = DictionaryUpdater.shared
    @Environment(\.scenePhase) private var scenePhase

    private let store = VoiceSettingsStore.shared

    private var voice: EloquenceVoiceDef {
        let list = VoiceCatalog.voices(for: language)
        return list[min(voiceIndex, list.count - 1)]
    }
    private var previewPercent: Int { Int((previewRate * 100).rounded()) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(ELOQUENCE_LANGUAGES) { l in Text(l.name).tag(l) }
                    }
                    .onChange(of: language) { _, _ in loadVoice() }
                    Picker("Voice", selection: $voiceIndex) {
                        ForEach(Array(ELOQUENCE_VOICES.enumerated()), id: \.offset) { i, v in
                            Text(v.display).tag(i)
                        }
                    }
                    .onChange(of: voiceIndex) { _, _ in loadVoice() }
                } header: {
                    Text("Voice")
                }

                Section {
                    dial("Head size", $settings.headSize)
                    dial("Pitch", $settings.pitch)
                    dial("Pitch range", $settings.pitchRange)
                    dial("Roughness", $settings.roughness)
                    dial("Breathiness", $settings.breathiness)
                    dial("Speed at the default rate", $settings.speed, max: VoiceSettings.speedMax, step: 10)
                    dial("Volume", $settings.volume)

                    Button("Reset to defaults") { resetVoice() }
                        .disabled(!isCustomised)
                } header: {
                    Text("Voice settings")
                }

                Section("Preview") {
                    Slider(value: $previewRate, in: 0...1, step: 0.05) {
                        Text("Speaking rate")
                    } minimumValueLabel: {
                        Text("Slow")
                    } maximumValueLabel: {
                        Text("Fast")
                    }
                    .accessibilityValue("\(previewPercent) percent, \(SpeechRate.describe(fraction: previewRate))")
                    Text("\(previewPercent)%, \(SpeechRate.describe(fraction: previewRate)) - like VoiceOver's speaking rate")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Text to speak")

                    Button(action: preview) {
                        Label("Preview", systemImage: "play.circle.fill")
                    }
                    .disabled(isBusy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !status.isEmpty {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Use community dictionary", isOn: Binding(
                        get: { dictEnabled },
                        set: { on in dictEnabled = on; dictionary.setEnabled(on) }))
                    Toggle("Update automatically", isOn: Binding(
                        get: { dictAutoUpdate },
                        set: { on in dictAutoUpdate = on; dictionary.setAutoUpdate(on) }))
                    if dictAutoUpdate {
                        // Shown only while automatic updates are on: a dimmed picker VoiceOver still
                        // stops on would read as a setting that does something.
                        Picker("Check for updates", selection: Binding(
                            get: { dictFrequency },
                            set: { f in dictFrequency = f; dictionary.setFrequency(f) })) {
                            ForEach(DictionaryUpdateFrequency.allCases) { f in
                                Text(f.title).tag(f)
                            }
                        }
                    }
                    Button("Update now") { dictionary.updateNow() }
                        .disabled(dictionary.isBusy)
                    NavigationLink {
                        DictionaryEditorView(voice: voice, settings: settings)
                    } label: {
                        Text("Dictionary entries")
                    }
                    Text(dictionary.installedDescription)
                        .font(.footnote)
                    if dictionary.isBusy || !dictionary.status.isEmpty {
                        Text(dictionary.status.isEmpty ? "Working..." : dictionary.status)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Pronunciation dictionary")
                }

                if OutputSampleRate.available || ToneSetting.available || PauseSetting.available {
                    Section {
                        if OutputSampleRate.available {
                            Picker("Sample rate", selection: Binding(
                                get: { sampleRate },
                                set: { hz in sampleRate = hz; store.sampleRate = hz; Self.rateChanged() })) {
                                ForEach(OutputSampleRate.options, id: \.self) { hz in
                                    Text(OutputSampleRate.label(hz)).tag(hz)
                                }
                            }
                        }
                        if ToneSetting.available {
                            Picker("Equalizer", selection: Binding(
                                get: { tone },
                                set: { t in tone = t; store.tone = t })) {
                                ForEach(ToneSetting.allCases) { t in Text(t.title).tag(t) }
                            }
                            if tone == .custom {
                                // Shown only for Custom, as "Check for updates" is only while it does something.
                                trebleSlider
                            }
                            if sampleRate >= ToneSetting.mellowFromHz {
                                // Mellow does nothing below 16 kHz, so it is not offered there.
                                Toggle("Mellow mode", isOn: Binding(
                                    get: { mellow },
                                    set: { on in mellow = on; store.mellow = on }))
                            }
                        }
                        if PauseSetting.available {
                            Picker("Shorten pauses", selection: Binding(
                                get: { shortenPauses },
                                set: { p in shortenPauses = p; store.shortenPauses = p })) {
                                ForEach(PauseSetting.allCases) { p in Text(p.title).tag(p) }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Phrase prediction", isOn: Binding(
                        get: { phrasePrediction },
                        set: { on in phrasePrediction = on; store.phrasePredictionEnabled = on }))
                }

                Section {
                    Toggle("Enable backquote voice tags", isOn: Binding(
                        get: { voiceTags },
                        set: { on in voiceTags = on; store.voiceTagsEnabled = on }))
                }

                Section("This build") {
                    Text(EloquenceEngine.enginePresent
                         ? "Speech engine: \(EloquenceEngine.engineDescription)."
                         : "No speech engine. Engine: \(EloquenceEngine.engineDescription).")
                        .font(.footnote)
                    if !store.isShared {
                        Text("Settings can't be shared with the voices.")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("ReLoq Apple")
        }
        .macFrame(minWidth: 480, minHeight: 600)
        .onChange(of: settings) { _, new in
            guard !loading else { return }
            store.save(new, for: voice)
            isCustomised = true
        }
        .onChange(of: dictionary.status) { _, new in
            // The status line changes while nothing has focus on it: say it, so a finished (or failed)
            // download is heard without hunting for the line.
            if !new.isEmpty { AccessibilityNotification.Announcement(new).post() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { dictionary.appBecameActive() }
        }
        .onAppear {
#if os(iOS)
            if SelfTest.handleSetRateArgument() { return }   // development only: -evSetRate <hz>, nothing else runs
#endif
            loadVoice()
            store.removeOldSampleRateSetting()   // the Output picker is gone; its saved value too
            loading = false
            dictionary.appBecameActive()   // tidy old downloads; auto-update check if due (off by default)
            // Tell the system the extension's voice list may have changed so it shows up in Settings.
            AVSpeechSynthesisProviderVoice.updateSpeechVoices()
#if os(iOS)
            if SelfTest.isRequested { SelfTest.run() }   // development only: -evSelfTest launch argument
#endif
        }
    }

    // MARK: - Controls

    /// One engine dial: a Slider VoiceOver can adjust, announcing the real number.
    private func dial(_ label: String, _ value: Binding<Int>, max: Int = VoiceSettings.dialMax, step: Int = 5) -> some View {
        let binding = Binding<Double>(get: { Double(value.wrappedValue) },
                                      set: { value.wrappedValue = Int($0.rounded()) })
        return VStack(alignment: .leading, spacing: 2) {
            Slider(value: binding, in: 0...Double(max), step: Double(step)) {
                Text(label)
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("\(max)")
            }
            .accessibilityValue("\(value.wrappedValue) of \(max)")
            Text("\(label): \(value.wrappedValue) of \(max)")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// The Custom equalizer's treble, -12 to +12 dB in 1 dB steps; VoiceOver hears "plus 4 decibels".
    private var trebleSlider: some View {
        let binding = Binding<Double>(get: { Double(trebleDB) },
                                      set: { v in trebleDB = Int(v.rounded()); store.trebleDB = trebleDB })
        let r = ToneSetting.trebleRange
        return VStack(alignment: .leading, spacing: 2) {
            Slider(value: binding, in: Double(r.lowerBound)...Double(r.upperBound), step: 1) {
                Text("Treble")
            } minimumValueLabel: {
                Text("\(r.lowerBound) dB")
            } maximumValueLabel: {
                Text("+\(r.upperBound) dB")
            }
            .accessibilityValue(Self.decibels(trebleDB))
            Text("Treble: \(trebleDB > 0 ? "+" : "")\(trebleDB) dB")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    static func decibels(_ db: Int) -> String {
        db > 0 ? "plus \(db) decibels" : db < 0 ? "minus \(-db) decibels" : "0 decibels"
    }

    // MARK: - Actions

    private func loadVoice() {
        loading = true
        settings = store.settings(for: voice)
        isCustomised = store.customSettings(for: voice) != nil
        text = Self.sample(for: voice)
        DispatchQueue.main.async { loading = false }
    }

    /// A first sentence in the voice's own language.
    static func sample(for v: EloquenceVoiceDef) -> String {
        let n = VoiceCatalog.shortName(v)
        switch v.language.code {
        case "engb": return "This is \(n), speaking British English."
        case "eses", "esus": return "Hola, soy \(n). Esta es mi voz en español."
        case "frfr", "frca": return "Bonjour, je m'appelle \(n). Voici ma voix en français."
        case "dede": return "Hallo, ich bin \(n). Das ist meine deutsche Stimme."
        case "itit": return "Ciao, sono \(n). Questa è la mia voce italiana."
        case "plpl": return "Dzień dobry, jestem \(n). To jest mój polski głos."
        case "ptbr": return "Olá, eu sou \(n). Esta é a minha voz em português."
        case "fifi": return "Hei, olen \(n). Tämä on suomenkielinen ääneni."
        case "elgr": return "Γεια σας, είμαι ο \(n). Αυτή είναι η ελληνική μου φωνή."
        case "zhcn": return "你好，这是中文的声音。"
        case "jajp": return "こんにちは。日本語の声です。"
        case "kokr": return "안녕하세요. 한국어 목소리입니다."
#if os(macOS)
        default: return "This is \(n), natively on the Mac."
#else
        default: return "This is \(n), natively on iOS."
#endif
        }
    }

    /// A new sample rate: the system is told the voices changed, so it can make a new audio unit (the
    /// rate an existing one plays at cannot change while the host has it running; EloquenceVoicesProvider).
    static func rateChanged() {
        // off the main thread: on the iPhone Air (2026-11-19) the self-test's main thread stopped inside this
        // call once, right after a rate change, and a frozen picker must not be what the user gets
        DispatchQueue.global(qos: .utility).async { AVSpeechSynthesisProviderVoice.updateSpeechVoices() }
    }

    private func resetVoice() {
        store.reset(for: voice)
        loadVoice()
    }

    private func preview() {
        isBusy = true
        status = ""
        let t = text, v = voice, hz = store.sampleRate     // the preview at the rate VoiceOver will get
        let request = EloquenceEngine.request(settings: settings,
                                              speedFactor: SpeechRate.speedFactor(fromFraction: previewRate),
                                              sampleRate: hz)
        DispatchQueue.global(qos: .userInitiated).async {
            PronunciationDictionary.configureEngine()   // the preview says words as VoiceOver will
            let samples = EloquenceEngine.shared.synthesize(text: t, voice: v, request: request)
            DispatchQueue.main.async {
                isBusy = false
                guard let samples else {
                    status = "Synthesis failed."
                    return
                }
                guard !samples.isEmpty else {
                    status = "Nothing to speak."
                    return
                }
                play(samples, sampleRate: hz)
            }
        }
    }

    private func play(_ samples: [Int16], sampleRate: Int) {
        do {
            try Playback.activate()
            player?.stop()
            let p = try AVAudioPlayer(data: WAVFile.data(samples, sampleRate: sampleRate))
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            status = "Playback error: \(error.localizedDescription)"
        }
    }
}
