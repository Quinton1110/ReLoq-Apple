//
//  VoiceSettings.swift
//  The engine's eight voice parameters as the app edits them and the extension reads them, plus the
//  output sample rate. Shared by both targets through the app group, because iOS runs the speech
//  provider in its own process (and instantiates a fresh audio unit per utterance): the app writes,
//  the extension reads at every request.
//
//  Units are the engine's own (include/eci.h ECIVoiceParam): gender 0/1, speed 0...250, everything
//  else 0...100. A preset is just a starting point on these dials (a requirement from the start, 2026-09-22);
//  the values here are what is passed to eciSetVoiceParam on voice 0 after eciCopyVoice(preset, 0).
//
//  ❓ Open design question (NOT built): should a modified preset be saveable as a voice of its
//  own ("Reed, deeper")? It would need a new slug per saved voice (slugs are permanent identifiers
//  in VoiceOver's list), a name, and a way to delete one without stranding a VoiceOver selection.
//  For now each preset keeps ONE set of user settings, restorable with "Reset to preset".
//

import Foundation

// The app group both targets share is `AppGroup.id` (AppGroup.swift): the entitlements' group for a copy installed
// directly, the re-signed one for a copy installed through AltStore or SideStore.

struct VoiceSettings: Codable, Equatable {
    var gender: Int          // 0 male, 1 female
    var headSize: Int        // 0...100
    var pitch: Int           // 0...100  pitch baseline
    var pitchRange: Int      // 0...100  pitch fluctuation ("inflection")
    var roughness: Int       // 0...100
    var breathiness: Int     // 0...100
    var speed: Int           // 0...250
    var volume: Int          // 0...100

    static let dialMax = Int(EV_DIAL_MAX)
    static let speedMax = Int(EV_SPEED_MAX)
    /// The speed dial's starting value for EVERY voice (see ev_bridge.h EV_STANDARD_SPEED): the speed
    /// the voice has when VoiceOver's rate is at its default. Glen's and Sandy's presets ship at 70
    /// (1.5x) - kept for display, never as the starting dial, so selecting them does not change speed.
    static let standardSpeed = Int(EV_STANDARD_SPEED)

    init(gender: Int, headSize: Int, pitch: Int, pitchRange: Int, roughness: Int, breathiness: Int,
         speed: Int, volume: Int) {
        self.gender = gender; self.headSize = headSize; self.pitch = pitch; self.pitchRange = pitchRange
        self.roughness = roughness; self.breathiness = breathiness; self.speed = speed; self.volume = volume
    }

    init(_ c: ev_voice_params) {
        self.init(gender: Int(c.gender), headSize: Int(c.head_size), pitch: Int(c.pitch_baseline),
                  pitchRange: Int(c.pitch_fluctuation), roughness: Int(c.roughness),
                  breathiness: Int(c.breathiness), speed: Int(c.speed), volume: Int(c.volume))
    }

    /// The C struct the bridge takes, in the engine's own order.
    var cParams: ev_voice_params {
        let s = clamped()
        return ev_voice_params(gender: Int32(s.gender), head_size: Int32(s.headSize),
                               pitch_baseline: Int32(s.pitch), pitch_fluctuation: Int32(s.pitchRange),
                               roughness: Int32(s.roughness), breathiness: Int32(s.breathiness),
                               speed: Int32(s.speed), volume: Int32(s.volume))
    }

    func clamped() -> VoiceSettings {
        func d(_ v: Int) -> Int { min(Self.dialMax, max(0, v)) }
        return VoiceSettings(gender: gender == 0 ? 0 : 1, headSize: d(headSize), pitch: d(pitch),
                             pitchRange: d(pitchRange), roughness: d(roughness), breathiness: d(breathiness),
                             speed: min(Self.speedMax, max(0, speed)), volume: d(volume))
    }

    /// One line for logs and the self-test - values only, never text.
    var summary: String {
        "gender=\(gender) head=\(headSize) pitch=\(pitch) range=\(pitchRange) rough=\(roughness) breath=\(breathiness) speed=\(speed) vol=\(volume)"
    }
}

/// The output sample rate (2026-11-19, the ReLoq port; ReLoq's Android app has always offered it). ReLoq C SYNTHESISES at each of the seven ECI
/// rates (its own Klatt renderer at that rate, not the 11,025 Hz voice resampled), so the setting is real:
/// 8,000 is narrower, 16,000 and up carry sound above 5.5 kHz that 11,025 cannot. Offered only when the
/// engine really makes those rates (`available`): the openevv engine this app used before ReLoq C only
/// resampled above 11,025, which is why the old picker was removed on 2026-09-24. Stored in the app group; the extension
/// reads it when an audio unit is made and at every request (EloquenceVoicesProvider: when it lands).
enum OutputSampleRate {
    static let native = Int(EV_NATIVE_SAMPLE_RATE)
    /// The key the removed 2026-09 "Output" picker stored under; cleared once by the app, never read.
    static let removedKey = "output.sampleRate"
    /// Where the setting lives now (a new key, so nothing the old picker saved comes back to life).
    static let key = "output.rateHz"
    static let options: [Int] = [8000, 11025, 16000, 22050, 32000, 44100, 48000]

    /// The engine synthesises at every offered rate (ReLoq: yes; openevv: no - then there is no setting).
    static var available: Bool { options.allSatisfy { ev_sample_rate_native(Int32($0)) != 0 } }

    static func label(_ hz: Int) -> String {
        switch hz {
        case 8000: return "8 kHz"
        case 11025: return "11 kHz, classic"
        case 16000: return "16 kHz"
        case 22050: return "22 kHz"
        case 32000: return "32 kHz"
        case 44100: return "44.1 kHz"
        case 48000: return "48 kHz"
        default: return "\(hz) Hz"
        }
    }
}

/// The tone controls (2026-11-19): ReLoq C's output equaliser
/// and Mellow mode, as its Android app offers them. One setting for every voice, in the app group; handed to the
/// bridge in configureEngine() before every request, so the next thing any synthesizer says has it. The defaults
/// (equalizer off, treble 0 dB, Mellow off) are ReLoq's own and are stored as NO value: with them the engine is
/// never told anything (ev_set_tone). Offered only with ReLoq (`available`); openevv has no such controls.
enum ToneSetting: String, CaseIterable, Identifiable {
    /// Off: flat, ReLoq's default.
    case off
    /// Android's "Bright" preset (VoiceSettings.EQ_PRESETS[2] in ReLoq's android/): bass -1, midrange 0, treble +4 dB.
    case bright
    /// Treble from the slider, bass and midrange flat.
    case custom
    var id: String { rawValue }

    static let key = "tone.equalizer"
    static let trebleKey = "tone.trebleDB"
    static let mellowKey = "tone.mellow"
    static let trebleRange = -12...12
    /// Mellow does something only at 16 kHz and above (ReLoq: "reduce periodic presence from 16 kHz").
    static let mellowFromHz = 16000

    static var available: Bool { ev_tone_available() != 0 }

    var title: String {
        switch self {
        case .off: return "Off"
        case .bright: return "Bright"
        case .custom: return "Custom"
        }
    }

    /// Bass, midrange, treble in dB.
    func bands(treble: Int) -> (Int32, Int32, Int32) {
        switch self {
        case .off: return (0, 0, 0)
        case .bright: return (-1, 0, 4)
        case .custom: return (0, 0, Int32(treble))
        }
    }
}

/// "Shorten pauses": ReLoq C's pause policy (RELOQ_ECI_PAUSE_MODE), named and worded as its NVDA add-on has it
/// ("Never", "Only at text end", "Always"). It changes only the pauses the engine adds itself; a pause the text asks
/// for keeps its length. One setting for every voice, in the app group, handed to the bridge in configureEngine()
/// before every request like the tone controls. Never (the engine's own pauses) is the default and is stored as NO
/// value: with it the engine is never told anything (ev_set_pause_mode).
enum PauseSetting: String, CaseIterable, Identifiable {
    /// The original pauses (engine value 0).
    case never
    /// Only the final automatic pause of the text is shortened (1).
    case end
    /// Every automatic pause is shortened (2).
    case always
    var id: String { rawValue }

    static let key = "engine.shortenPauses"

    static var available: Bool { ev_pause_mode_available() != 0 }

    var title: String {
        switch self {
        case .never: return "Never"
        case .end: return "Only at end of text"
        case .always: return "Always"
        }
    }

    /// The engine's value.
    var mode: Int32 {
        switch self {
        case .never: return 0
        case .end: return 1
        case .always: return 2
        }
    }
}

final class VoiceSettingsStore {
    static let shared = VoiceSettingsStore()

    private let defaults: UserDefaults
    /// The same app-group defaults, for settings kept in other files (PronunciationDictionary.swift).
    var groupDefaults: UserDefaults { defaults }
    /// false = the app group could not be opened and this process fell back to its own defaults
    /// (then the extension cannot see the app's changes - shown in the app's "This build" section).
    /// UserDefaults(suiteName:) gives a defaults object even for a group this copy is not granted (a file of
    /// this process's own), so the group counts as shared only when its container opens too.
    let isShared: Bool

    init() {
        if let d = AppGroup.makeDefaults() {
            defaults = d
            isShared = AppGroup.containerURL != nil
        } else {
            defaults = .standard
            isShared = false
        }
    }

    private func key(_ def: EloquenceVoiceDef) -> String { "voice." + def.slug }

    /// The user's settings for this voice, or nil when it has never been changed from its preset.
    func customSettings(for def: EloquenceVoiceDef) -> VoiceSettings? {
        guard let data = defaults.data(forKey: key(def)),
              let s = try? JSONDecoder().decode(VoiceSettings.self, from: data) else { return nil }
        return s.clamped()
    }

    /// What this voice starts from: the preset's own seven, with the speed dial at the standard 50
    /// (VoiceSettings.standardSpeed) rather than the preset's own value.
    func defaultSettings(for def: EloquenceVoiceDef) -> VoiceSettings {
        var s = EloquenceEngine.shared.presetSettings(for: def)
        s.speed = VoiceSettings.standardSpeed
        return s
    }

    /// What this voice speaks with: the user's settings if any, else the defaults above.
    func settings(for def: EloquenceVoiceDef) -> VoiceSettings {
        customSettings(for: def) ?? defaultSettings(for: def)
    }

    func save(_ s: VoiceSettings, for def: EloquenceVoiceDef) {
        if let data = try? JSONEncoder().encode(s.clamped()) {
            defaults.set(data, forKey: key(def))
        }
    }

    func reset(for def: EloquenceVoiceDef) {
        defaults.removeObject(forKey: key(def))
    }

    /// Removes what the old sample-rate picker saved (the app calls this at launch).
    func removeOldSampleRateSetting() {
        defaults.removeObject(forKey: OutputSampleRate.removedKey)
    }

    /// The equalizer (ToneSetting): the stored one, else Off. Off is stored as no value.
    var tone: ToneSetting {
        get { defaults.string(forKey: ToneSetting.key).flatMap(ToneSetting.init(rawValue:)) ?? .off }
        set {
            if newValue == .off { defaults.removeObject(forKey: ToneSetting.key) }
            else { defaults.set(newValue.rawValue, forKey: ToneSetting.key) }
        }
    }

    /// The Custom treble in dB, -12...12; 0 (the default) is stored as no value.
    var trebleDB: Int {
        get { min(max(defaults.integer(forKey: ToneSetting.trebleKey), ToneSetting.trebleRange.lowerBound),
                  ToneSetting.trebleRange.upperBound) }
        set {
            let v = min(max(newValue, ToneSetting.trebleRange.lowerBound), ToneSetting.trebleRange.upperBound)
            if v == 0 { defaults.removeObject(forKey: ToneSetting.trebleKey) }
            else { defaults.set(v, forKey: ToneSetting.trebleKey) }
        }
    }

    /// Mellow mode; off (the default) is stored as no value.
    var mellow: Bool {
        get { defaults.bool(forKey: ToneSetting.mellowKey) }
        set {
            if newValue { defaults.set(true, forKey: ToneSetting.mellowKey) }
            else { defaults.removeObject(forKey: ToneSetting.mellowKey) }
        }
    }

    /// Hands the tone controls to the bridge (configureEngine calls this before every request).
    func applyTone() {
        let (b, m, t) = tone.bands(treble: trebleDB)
        ev_set_tone(b, m, t, mellow ? 1 : 0)
    }

    /// "Shorten pauses" (PauseSetting): the stored one, else Never. Never is stored as no value.
    var shortenPauses: PauseSetting {
        get { defaults.string(forKey: PauseSetting.key).flatMap(PauseSetting.init(rawValue:)) ?? .never }
        set {
            if newValue == .never { defaults.removeObject(forKey: PauseSetting.key) }
            else { defaults.set(newValue.rawValue, forKey: PauseSetting.key) }
        }
    }

    /// "VoiceOver pauses" (SSML.BoundaryPauses): the stored one, else Normal. Normal is stored as no value. The
    /// extension reads it for every request (EloquenceVoicesProvider) and passes it to the segment loop.
    var voiceOverPauses: SSML.BoundaryPauses {
        get { defaults.string(forKey: SSML.BoundaryPauses.key).flatMap(SSML.BoundaryPauses.init(rawValue:)) ?? .normal }
        set {
            if newValue == .normal { defaults.removeObject(forKey: SSML.BoundaryPauses.key) }
            else { defaults.set(newValue.rawValue, forKey: SSML.BoundaryPauses.key) }
        }
    }

    /// Hands "Shorten pauses" to the bridge (configureEngine calls this before every request).
    func applyPauses() {
        ev_set_pause_mode(shortenPauses.mode)
    }

    /// The output sample rate in hertz: the stored one when the engine really makes it, else the native
    /// 11,025 (also what an unset value means).
    var sampleRate: Int {
        get {
            let v = defaults.integer(forKey: OutputSampleRate.key)
            guard OutputSampleRate.available, OutputSampleRate.options.contains(v) else { return OutputSampleRate.native }
            return v
        }
        set {
            if newValue == OutputSampleRate.native || !OutputSampleRate.options.contains(newValue) {
                defaults.removeObject(forKey: OutputSampleRate.key)
            } else {
                defaults.set(newValue, forKey: OutputSampleRate.key)
            }
        }
    }
}
