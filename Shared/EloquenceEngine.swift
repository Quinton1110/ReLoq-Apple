//
//  EloquenceEngine.swift
//  Swift side of the C bridge (Shared/Bridge/ev_bridge.c), shared by the app and the speech-provider
//  extension. The bridge and the engine are one framework both load (EloquenceEngine.framework, embedded
//  once in the app; project.yml). The engine (ReLoq C) sits behind
//  ev_bridge.h; nothing here knows which.
//
//  Voice handles are not reentrant, so a small process-wide pool hands each utterance its own handle
//  and keeps a few warm for the next one. iOS creates a fresh audio unit for every utterance, so
//  nothing per-voice may live on the audio unit itself (ClassicVoices lesson).
//
//  Privacy: this is a screen-reader voice. Nothing here logs or stores the text it speaks.
//

import Foundation

final class EloquenceEngine {
    static let shared = EloquenceEngine()

    static let nativeSampleRate: Double = Double(EV_NATIVE_SAMPLE_RATE)
    static var enginePresent: Bool { ev_engine_present() != 0 }
    static var engineDescription: String { String(cString: ev_engine_description()) }

    /// This process's phys_footprint in MB - the number iOS counts against an extension's memory
    /// limit (the same measurement openevv's tools/ios/speak.c reports). -1 if unavailable.
    static func processFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private let lock = NSLock()
    private var idle: [(slug: String, handle: OpaquePointer)] = []   // most recently used last
    private let maxIdle = 3
    private var lastDictReport = ev_dict_report(in_force: 0, main_rc: -1, abbr_rc: -1, root_added: 0, user_added: 0)
    private var lastError: (code: Int32, stage: Int32)?

    /// When the engine refused the most recent utterance (ReLoq C: its error code and stage), for the status
    /// line; nil when it did not.
    var lastEngineError: (code: Int32, stage: Int32)? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    /// What the dictionaries did on the most recent utterance, for the log (numbers only, no words):
    /// the community files' load answers, root entries handed over, the user's own entries.
    var dictionarySummary: String {
        lock.lock(); let r = lastDictReport; lock.unlock()
        guard r.in_force != 0 else { return "dict=off" }
        return "dict=on main=\(r.main_rc) abbr=\(r.abbr_rc) rootAdded=\(r.root_added) rootTable=\(ev_dict_root_entries()) user=\(ev_dict_user_entries()) userAdded=\(r.user_added)"
    }

    private init() {}

    // MARK: - Handle pool

    private func checkout(_ def: EloquenceVoiceDef) -> OpaquePointer? {
        lock.lock()
        if let i = idle.lastIndex(where: { $0.slug == def.slug }) {
            let h = idle.remove(at: i).handle
            lock.unlock()
            return h
        }
        lock.unlock()
        return ev_voice_open_lang(Int32(def.preset), def.language.eci)
    }

    private func checkin(_ def: EloquenceVoiceDef, _ h: OpaquePointer) {
        lock.lock()
        idle.append((def.slug, h))
        while idle.count > maxIdle {
            let old = idle.removeFirst()
            ev_voice_close(old.handle)
        }
        lock.unlock()
    }

    /// Drops every warm handle (the next utterance of each voice starts from a fresh engine).
    func releaseIdle() {
        lock.lock()
        let all = idle
        idle.removeAll()
        lock.unlock()
        for h in all { ev_voice_close(h.handle) }
    }

    // MARK: - Presets

    /// The preset's own eight, as the engine (or the stub's copy of its table) reports them.
    func presetSettings(for def: EloquenceVoiceDef) -> VoiceSettings {
        guard let h = checkout(def) else {
            return VoiceSettings(gender: def.female ? 1 : 0, headSize: 50, pitch: 65, pitchRange: 30,
                                 roughness: 0, breathiness: 0, speed: 50, volume: 92)
        }
        var p = ev_voice_params()
        let rc = ev_voice_preset_params(h, &p)
        checkin(def, h)
        return rc == 0 ? VoiceSettings(p) : VoiceSettings(gender: def.female ? 1 : 0, headSize: 50, pitch: 65,
                                                           pitchRange: 30, roughness: 0, breathiness: 0,
                                                           speed: 50, volume: 92)
    }

    /// The preset's name as the engine itself calls it (for checking the Reed...Grandpa mapping).
    func engineVoiceName(for def: EloquenceVoiceDef) -> String {
        guard let h = checkout(def) else { return "" }
        var buf = [CChar](repeating: 0, count: 64)
        ev_voice_engine_name(h, &buf, Int32(buf.count))
        checkin(def, h)
        return String(cString: buf)
    }

    // MARK: - Requests

    /// Builds the request the bridge takes: the voice's settings, what this utterance asks for on
    /// top, and the output rate.
    static func request(settings: VoiceSettings, speedFactor: Double = 1, semitones: Double = 0,
                        range: Double = 1, volume: Double = 1, sampleRate: Int) -> ev_request {
        ev_request(voice: settings.cParams,
                   prosody: ev_prosody(speed: speedFactor, pitch_st: semitones, range: range, volume: volume),
                   sample_rate: Int32(sampleRate))
    }

    /// `base` with one segment's scoped prosody on top (pitch adds, range and volume multiply).
    static func request(_ base: ev_request, with p: SSML.Prosody) -> ev_request {
        var r = base
        r.prosody.pitch_st = max(-12, min(12, base.prosody.pitch_st + p.semitones))
        r.prosody.range = max(0.5, min(2, base.prosody.range * p.range))
        r.prosody.volume = max(0, min(1, base.prosody.volume * p.volume))
        return r
    }

    /// The eight the engine will be told for this request (after prosody and clamping).
    static func effectiveSettings(_ req: ev_request) -> VoiceSettings {
        var r = req
        var out = ev_voice_params()
        withUnsafePointer(to: &r.voice) { vp in
            withUnsafePointer(to: &r.prosody) { pp in
                ev_apply_prosody(vp, pp, &out)
            }
        }
        return VoiceSettings(out)
    }

    /// How fast the voice really speaks at a requested factor (the engine's speed dial stops at 250).
    /// Pauses between segments scale with this, so they keep pace with the speech.
    static func effectiveSpeed(settings: VoiceSettings, factor: Double) -> Double {
        var p = settings.cParams
        return ev_effective_speed(&p, factor)
    }

    // MARK: - Speaking

    private final class Sink {
        let body: (UnsafeBufferPointer<Int16>) -> Bool
        init(_ body: @escaping (UnsafeBufferPointer<Int16>) -> Bool) { self.body = body }
    }

    private static let onPCM: ev_pcm_fn = { pcm, n, user in
        guard let pcm, let user else { return 1 }
        let s = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
        return s.body(UnsafeBufferPointer(start: pcm, count: Int(n))) ? 0 : 1
    }

    /// Speaks `text` (plain text, no markup), streaming Int16 PCM at `request.sample_rate` to `onPCM`
    /// as the engine produces it. `onPCM` returns false to stop. Returns 0 done, 1 stopped, -1 error.
    @discardableResult
    func speak(text: String, voice def: EloquenceVoiceDef, request: ev_request,
               onPCM: @escaping (UnsafeBufferPointer<Int16>) -> Bool) -> Int32 {
        guard let h = checkout(def) else { return -1 }
        let sink = Sink(onPCM)
        let ctx = Unmanaged.passUnretained(sink).toOpaque()
        var req = request
        let rc: Int32 = withExtendedLifetime(sink) {
            text.withCString { cText in
                ev_voice_speak(h, cText, &req, Self.onPCM, ctx)
            }
        }
        var report = ev_dict_report()
        ev_voice_dict_report(h, &report)
        var code: Int32 = 0, stage: Int32 = 0
        ev_voice_engine_error(h, &code, &stage)
        lock.lock(); lastDictReport = report; lastError = code != 0 ? (code, stage) : nil; lock.unlock()
        if rc < 0 {
            ev_voice_close(h)      // a failed engine is not handed out again
        } else {
            // Cut off: ReLoq would make this handle's NEXT utterance pay a ~10 ms reset first; pay it now, here
            // on the engine thread, so the next request on it starts at once (ev_voice_prime, measured 10.6 -> 0.3 ms).
            if rc == 1 { ev_voice_prime(h) }
            checkin(def, h)
        }
        return rc
    }

    /// Speaks SSML segments the way the extension does: each segment is its own engine call, and every
    /// pause is real silence - an explicit <break> at once, an element boundary just before the next
    /// segment's first audio (so a segment that turns out silent, or the end of the request, never
    /// leaves a gap). `onPCM` / `silence(ms)` return false to stop. Returns 0 done, 1 stopped, -1 if
    /// an engine call failed (the other segments still speak).
    /// Each segment speaks with its OWN pitch, range and volume (SSML.Segment.prosody, scoped to the
    /// <prosody> it sits in) on top of `request`'s; only the speed is one value for the whole request.
    @discardableResult
    func speak(segments: [SSML.Segment], voice def: EloquenceVoiceDef, settings: VoiceSettings,
               request: ev_request,
               onPCM: @escaping (UnsafeBufferPointer<Int16>) -> Bool,
               silence: @escaping (Int) -> Bool) -> Int32 {
        let speed = Self.effectiveSpeed(settings: settings, factor: request.prosody.speed)
        var pendingMs = 0          // boundary pause owed before the next audio
        var failed = false
        for seg in segments {
            if !seg.text.isEmpty {
                var ok = true
                let rc = speak(text: seg.text, voice: def, request: Self.request(request, with: seg.prosody)) { pcm in
                    if pendingMs > 0 {
                        let ms = pendingMs
                        pendingMs = 0
                        if !silence(ms) { ok = false; return false }
                    }
                    if !onPCM(pcm) { ok = false; return false }
                    return true
                }
                if rc == 1 || !ok { return 1 }
                if rc < 0 { failed = true }
            }
            let ms = seg.silenceMs(speed: speed)
            if seg.pause.hasBreak {
                if ms > 0 && !silence(ms) { return 1 }
            } else if ms > 0 {
                pendingMs = ms
            }
        }
        return failed ? -1 : 0
    }

    /// Whole-utterance synthesis for the app's Preview button.
    func synthesize(text: String, voice def: EloquenceVoiceDef, request: ev_request) -> [Int16]? {
        var out: [Int16] = []
        let rc = speak(text: text, voice: def, request: request) { buf in
            out.append(contentsOf: buf)
            return true
        }
        return rc < 0 ? nil : out
    }
}
