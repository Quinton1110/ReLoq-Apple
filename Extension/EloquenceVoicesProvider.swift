//
//  EloquenceVoicesProvider.swift
//  AVSpeechSynthesisProviderAudioUnit that speaks VoiceOver (and any other speech client) with the
//  Eloquence voices - through the bridge in Shared/Bridge, which in this build is the STUB tone
//  generator and later the real engine (nothing in this file changes for that).
//
//  synthesizeSpeechRequest() starts the engine on its own thread (EngineThread) and returns once the
//  first audio exists; the PCM streams through PCMStream into the render block while the rest of
//  the utterance is still being made. Output is Float32 non-interleaved mono at the app's sample-rate
//  setting (OutputSampleRate; 11025 Hz unless chosen otherwise), the rate the engine SYNTHESISES at.
//
//  Lessons carried over from the author's earlier speech extensions (ClassicVoices, NeuralVoice, DECtalk):
//   - iOS creates a FRESH audio unit per utterance: no per-instance counters or remembered state;
//     anything that must persist (the per-voice rate) is static.
//   - VoiceOver omits the rate on some announcements (voice switching), so the fallback is that
//     VOICE's last rate, not a global one.
//   - The pauses VoiceOver asks for (<s> boundaries between label, trait and value, <break>s) are
//     put back as real silence of a calibrated length (SSML.swift).
//   - Nothing is ever spoken for an empty request (no sample text injection).
//   - No logging of spoken text: this is a screen reader voice. The log line carries the voice
//     slug, the segment count and the numbers the engine is told.
//

import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.quinton.eloquencevoices", category: "Provider")

/// Every engine call this extension makes runs on threads of its OWN, made once and never let go: at most
/// `maxThreads` of them, in the order the requests came (2026-11-19). openevv takes a 4 MB frame stack from
/// its fixed 256 MB region for each thread that runs its rules, and an interrupted utterance runs them on the
/// CALLER's thread. The requests used to go to `DispatchQueue.global`, which retires idle threads after a few
/// seconds and makes new ones, so every VoiceOver cut-off on a fresh thread kept 4 MB: after about 62 of them
/// the engine said nothing at all (rc 0, no samples) for the life of the process, until VoiceOver was turned
/// off and on. The engine now gives a caller thread's frames back when the thread ends (openevv 4a90a86 and
/// its Darwin fix on fix/junction-pauses); these threads are the backstop, so thread churn cannot matter
/// again whatever the engine does: four threads can hold 16 MB of the region at most, for good.
///
/// Why not ONE thread: measured on the Mac, an interrupted utterance takes 6-28 ms to finish silently (the
/// engine cannot abandon the message it is on), and on one thread the next utterance waits for that - about
/// 15-22 ms more from a cut-off to the next speech. A second idle thread takes the next request at once, as
/// GCD did. `maxThreads = 1` is the single serial thread.
///
/// A paused long read no longer parks a thread (2026-11-19): after 2 s without a pull its producer makes the
/// rest of the utterance into memory and lets the thread go (PCMStream). And while every thread is busy, the
/// producer whose host has gone longest without pulling (at least 1 s) gives its thread up
/// (`PCMStream.yieldLongestPaused`): at once if a request is waiting, and ahead of time otherwise, because a
/// request that has to wait for a yielded thread also waits for that engine to finish its sentence silently
/// (measured 27-60 ms instead of ~17). So new speech never waits behind a pause.
final class EngineThread {
    static let shared = EngineThread()
    static let maxThreads = 4
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []
    private var threads = 0     // started, never ended
    private var waiting = 0     // of those, the ones idle in cond.wait()

    func async(_ job: @escaping () -> Void) {
        cond.lock()
        jobs.append(job)
        if jobs.count > waiting && threads < Self.maxThreads {
            threads += 1
            let t = Thread { self.loop() }
            t.name = "com.quinton.eloquencevoices.engine.\(threads)"
            t.qualityOfService = .userInteractive     // what the global queue was asked for
            t.start()
        }
        let starved = threads >= Self.maxThreads && jobs.count > waiting
        cond.signal()
        cond.unlock()
        // Every thread is busy: a paused utterance's producer gives its thread to this request (never with
        // this lock held - PCMStream takes its own locks).
        if starved {
            PCMStream.yieldLongestPaused()
            PCMStream.kickMonitor()
        }
    }

    /// Requests waiting with no thread to run them (every thread busy).
    var queuedWithoutThread: Int {
        cond.lock(); defer { cond.unlock() }
        return threads >= Self.maxThreads ? max(0, jobs.count - waiting) : 0
    }

    /// (threads started, of those idle, requests queued) - for the Mac harness.
    var snapshot: (threads: Int, idle: Int, queued: Int) {
        cond.lock(); defer { cond.unlock() }
        return (threads, waiting, jobs.count)
    }

    /// Every thread there may be is running a request (none idle).
    var isFull: Bool {
        cond.lock(); defer { cond.unlock() }
        return threads >= Self.maxThreads && waiting == 0
    }

    private func loop() {
        cond.lock()
        while true {
            while jobs.isEmpty { waiting += 1; cond.wait(); waiting -= 1 }
            let job = jobs.removeFirst()
            let full = threads >= Self.maxThreads && waiting == 0
            cond.unlock()
            if full { PCMStream.kickMonitor() }      // keep a thread free for the next request (PCMStream)
            autoreleasepool { job() }
            cond.lock()
        }
    }
}

public final class EloquenceVoicesProvider: AVSpeechSynthesisProviderAudioUnit {
    private let outputBus: AUAudioUnitBus
    private var _outputBusses: AUAudioUnitBusArray!
    private let stream: PCMStream
    /// The rate this audio unit's output bus declares, which is the rate every sample it hands out is made
    /// at: the app's setting (OutputSampleRate) when the audio unit was made, or when it last changed while
    /// the host had no render resources allocated (`syncRateToSetting`). Never a rate the bus does not say.
    private var outputRate: Int
    private let rateLock = NSLock()

    /// Which audio unit of this process this is (1, 2 ...), when it was made, and how often the host has
    /// allocated its render resources - in every status line, so the phone's engine-status.txt shows how
    /// often VoiceOver really makes a new audio unit (which is when a changed sample rate can land).
    private static var instancesMade = 0
    private static let instanceLock = NSLock()
    private let instance: Int
    private let madeAt = Date()
    private var allocations = 0

    static func outputFormat(_ hz: Int) throws -> AVAudioFormat {
        let asbd = AudioStreamBasicDescription(
            mSampleRate: Double(hz),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return AVAudioFormat(cmAudioFormatDescription: try CMAudioFormatDescription(audioStreamBasicDescription: asbd))
    }

    @objc override init(componentDescription: AudioComponentDescription,
                        options: AudioComponentInstantiationOptions) throws {
        let rate = VoiceSettingsStore.shared.sampleRate      // the app's setting; 11025 unless chosen otherwise
        self.outputRate = rate
        self.stream = PCMStream(sampleRate: Double(rate), note: Self.pauseNote)
        self.outputBus = try AUAudioUnitBus(format: try Self.outputFormat(rate))
        Self.instanceLock.lock(); Self.instancesMade += 1; self.instance = Self.instancesMade; Self.instanceLock.unlock()
        try super.init(componentDescription: componentDescription, options: options)
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        log.notice("audio unit \(self.instance) made hz=\(rate)")
        Self.appendStatus(String(format: "%@ au=%d made: setting=%d bus=%d", ISO8601DateFormatter().string(from: Date()),
                                 instance, rate, rate))
    }

    deinit {
        stream.cancel(.released)   // frees what it held, and releases a producer that may still be making it
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    public override func allocateRenderResources() throws {
        // The host is about to size its buffers from the bus format: the last moment a changed setting can
        // go onto the bus of an audio unit that already exists.
        let busBefore = Int(outputBus.format.sampleRate)
        let hz = syncRateToSetting(why: "allocate")
        try super.allocateRenderResources()
        rateLock.lock(); allocations += 1; let n = allocations; rateLock.unlock()
        Self.appendStatus(String(format: "%@ au=%d allocate %d: bus before=%d setting=%d -> bus=%d", ISO8601DateFormatter().string(from: Date()),
                                 instance, n, busBefore, VoiceSettingsStore.shared.sampleRate, hz))
    }

    /// Puts the app's current sample-rate setting on the output bus, but ONLY while the host has no render
    /// resources allocated: once it has, it renders at the format it was given, and samples at another rate
    /// would play at the wrong speed. Then the change waits for the next audio unit (or allocation), and the
    /// status line says so (wantHz=). Returns the rate in force.
    @discardableResult
    private func syncRateToSetting(why: String) -> Int {
        let want = VoiceSettingsStore.shared.sampleRate
        rateLock.lock(); defer { rateLock.unlock() }
        // The bus's own format is the truth: if the HOST put another format on it, that is the rate the host will
        // play, so that is the rate the engine must make.
        let bus = Int(outputBus.format.sampleRate)
        if bus != outputRate && bus > 0 {
            log.notice("audio unit \(self.instance) bus set to \(bus) by the host (was \(self.outputRate))")
            Self.appendStatus(String(format: "%@ au=%d the host set the bus to %d (it was %d)",
                                     ISO8601DateFormatter().string(from: Date()), instance, bus, outputRate))
            outputRate = bus
        }
        guard want != outputRate, !renderResourcesAllocated else { return outputRate }
        do {
            try outputBus.setFormat(try Self.outputFormat(want))
            log.notice("audio unit \(self.instance) rate \(self.outputRate) -> \(want) (\(why, privacy: .public))")
            outputRate = want
        } catch {
            log.error("audio unit \(self.instance) could not take rate \(want): \(error.localizedDescription, privacy: .public)")
        }
        return outputRate
    }

    /// "au=3 auAgeS=12.5 alloc=1" (+ " wantHz=22050" while the setting differs from what this audio unit makes).
    private func auSummary(hz: Int) -> String {
        rateLock.lock(); let a = allocations; rateLock.unlock()
        let want = VoiceSettingsStore.shared.sampleRate
        return String(format: "au=%d auAgeS=%.1f alloc=%d", instance, Date().timeIntervalSince(madeAt), a)
            + (want != hz ? " wantHz=\(want)" : "")
    }

    // MARK: - Render (drains the stream)

    public override var internalRenderBlock: AUInternalRenderBlock {
        let stream = self.stream
        return { actionFlags, _, frameCount, _, outputAudioBufferList, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outputAudioBufferList)
            guard let raw = abl[0].mData else { return noErr }
            let out = raw.assumingMemoryBound(to: Float32.self)
            let frames = Int(frameCount)
            out.update(repeating: 0, count: frames)

            let (n, done) = stream.read(into: out, frames: frames, maxWait: 0.25)
            if n < frames && !done {
                // The engine has not caught up within 0.25 s (never expected: it runs far faster than real time).
                // The buffer is full-length either way - a host plays a short one as if it were, zeros and all - so
                // say so: what is missing is heard as silence rather than stalling the host.
                abl[0].mDataByteSize = UInt32(frames * MemoryLayout<Float32>.size)
                return noErr
            }
            abl[0].mDataByteSize = UInt32(n * MemoryLayout<Float32>.size)
            if done { actionFlags.pointee = .offlineUnitRenderAction_Complete }
            return noErr
        }
    }

    // MARK: - Speech requests

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        let ssml = speechRequest.ssmlRepresentation
        let def = VoiceCatalog.def(forIdentifier: speechRequest.voice.identifier)
        let (fraction, rateSource) = Self.rateFraction(fromSSML: ssml, voiceSlug: def.slug)
        let hz = syncRateToSetting(why: "request")      // the rate this request is made and played at
        let settings = VoiceSettingsStore.shared.settings(for: def)
        // Pitch, range and volume come from EACH SEGMENT, scoped to the <prosody> it sits in (SSML.swift),
        // not one value for the whole request; absent means the voice's dials exactly (no memory, no
        // preset leak). Only the rate is one value per request, with a memory (below).
        let request = EloquenceEngine.request(settings: settings,
                                              speedFactor: SpeechRate.speedFactor(fromFraction: fraction),
                                              sampleRate: hz)
        let segments = SSML.segments(ssml)
        // The dictionaries of this voice's language: the user's own always, the community files when the
        // app's switch is on; and, for the dictionary editor's Listen through VoiceOver, one word said
        // without its entry (a marker the app leaves in the app group, used once).
        let plain = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        PronunciationDictionary.configureEngine(language: def.language, requestText: plain)
        // Diagnostics carry no spoken content: the voice, the count, and the numbers the engine is told.
        // `.notice`, not `.info`: the unified log persists notice and above, so `log show` can read this
        // back after a run; info-level lines exist only in memory and only for `log stream`.
        let told = EloquenceEngine.effectiveSettings(request)
        // What VoiceOver asked for, as STRUCTURE and VALUES only (never words): every <prosody> with its
        // pitch / range / volume / rate attributes and nesting depth, the <s>/<break> boundaries, and per
        // segment the semitones it came to and the pitch dial the engine is told. This is how the next
        // typing test shows what typed-text echo really sends.
        let shape = SSML.prosodyShape(ssml)
        let segPitch = Self.segmentPitchSummary(segments, request: request)
        let skel = SSML.textSkeleton(segments)      // punctuation only, no words (SSML.swift)
        log.notice("request voice=\(def.slug, privacy: .public) segments=\(segments.count) rateFraction=\(fraction, format: .fixed(precision: 2)) rateSource=\(rateSource, privacy: .public) hz=\(hz) told: \(told.summary, privacy: .public)")
        log.notice("prosody voice=\(def.slug, privacy: .public) shape=\(shape, privacy: .public) segPitch=\(segPitch, privacy: .public)")

        let stream = self.stream
        let g = stream.begin(label: def.slug, sampleRate: Double(hz))
        let started = Date()
        let au = auSummary(hz: hz)
        EngineThread.shared.async {
            // Cut off while it waited for the engine (VoiceOver moving on quickly): nothing it made would be
            // heard, so the engine goes straight to the request that replaced it.
            guard stream.isLive(g) else {
                log.notice("skipped voice=\(def.slug, privacy: .public): cancelled before the engine was free")
                Self.appendStatus(String(format: "%@ voice=%@ skipped: cancelled before the engine was free %@ engine=%@",
                                         ISO8601DateFormatter().string(from: Date()), def.slug, au,
                                         EloquenceEngine.engineDescription))
                return
            }
            stream.producerStarted(g)
            defer { stream.producerEnded(g) }
            var frames = 0
            let rc = EloquenceEngine.shared.speak(segments: segments, voice: def, settings: settings, request: request,
                                                  boundaries: VoiceSettingsStore.shared.voiceOverPauses,   // "VoiceOver pauses", per request
                                                  onPCM: { pcm in frames += pcm.count; return stream.append(g, pcm) },
                                                  silence: { ms in stream.appendSilence(g, ms: ms) })
            if rc < 0 { log.error("synthesis failed voice=\(def.slug, privacy: .public)") }
            // A short tail so even an empty utterance hands the host a frame and completes.
            if rc != 1 { stream.appendSilence(g, ms: 10) }
            stream.finish(g)
            // Diagnostics, no spoken content: what happened, how long, and what this process weighs.
            let elapsed = Date().timeIntervalSince(started)
            let mb = EloquenceEngine.processFootprintMB()
            log.notice("done voice=\(def.slug, privacy: .public) rc=\(rc) frames=\(frames) elapsed=\(elapsed, format: .fixed(precision: 3))s footprintMB=\(mb, format: .fixed(precision: 1))")
            let dict = EloquenceEngine.shared.dictionarySummary
            log.notice("dictionary voice=\(def.slug, privacy: .public) \(dict, privacy: .public)")
            // ReLoq refused (part of) the text: its error code and stage, no words (ev_voice_engine_error)
            let refused = EloquenceEngine.shared.lastEngineError.map { " engineErr=\($0.code) stage=\($0.stage)" } ?? ""
            Self.appendStatus(String(format: "%@ voice=%@ segments=%d rateSource=%@ hz=%d %@ told: %@ rc=%d%@ frames=%d elapsed=%.3fs footprintMB=%.1f engine=%@ shape=%@ segPitch=%@ skel=%@ %@",
                                     ISO8601DateFormatter().string(from: Date()), def.slug, segments.count, rateSource, hz, au,
                                     told.summary, rc, refused, frames, elapsed, mb, EloquenceEngine.engineDescription,
                                     shape, segPitch, skel, dict))
        }
        // Return once the first audio exists (typically a few milliseconds).
        stream.waitForAudio(g, timeout: 0.3)
    }

    /// Per segment: semitones asked -> pitch dial told, e.g. "[-2.81>59 0.00>65]" (at most 12 shown).
    static func segmentPitchSummary(_ segments: [SSML.Segment], request: ev_request) -> String {
        let items = segments.prefix(12).map { seg -> String in
            let told = EloquenceEngine.effectiveSettings(EloquenceEngine.request(request, with: seg.prosody))
            var item = String(format: "%.2f>%d", seg.prosody.semitones, told.pitch)
            if seg.prosody.range != 1 { item += String(format: " r%.2f", seg.prosody.range) }
            if seg.prosody.volume != 1 { item += String(format: " v%.2f", seg.prosody.volume) }
            return item
        }
        return "[" + items.joined(separator: " ") + (segments.count > 12 ? " ..." : "") + "]"
    }

    public override func cancelSpeechRequest() {
        stream.cancel(.cancelled)
    }

    // MARK: - Status file (the extension's own Documents; never any spoken text)

    /// One line per request in `Documents/engine-status.txt` of THIS extension's container, so the
    /// numbers can be collected from a phone without the unified log:
    ///   xcrun devicectl device copy from --device <id> --domain-type appDataContainer
    ///     --domain-identifier com.quinton.eloquencevoices.Extension --source Documents/engine-status.txt --destination x.txt
    /// Capped at 64 KB: when it grows past that it starts over. Written on a serial queue of its own (no
    /// engine work there), so neither an engine thread nor the render block ever waits for the file.
    private static let statusLock = NSLock()
    private static let statusQueue = DispatchQueue(label: "com.quinton.eloquencevoices.status", qos: .utility)

    private static func appendStatus(_ line: String) {
        statusQueue.async { appendStatusNow(line) }
    }

    /// A pause event from PCMStream (started / making the rest / ceiling / ended how and after how long /
    /// gave up), already labelled with the voice; no spoken content. May come from the render block, so
    /// everything but the log line happens on the status queue.
    static func pauseNote(_ text: String) {
        log.notice("\(text, privacy: .public)")
        let at = Date()
        let heldS = PCMStream.heldSeconds     // every stream, now, each at its own rate
        statusQueue.async {
            // (no engine= here: that string comes from the engine, and this is not an engine thread)
            appendStatusNow(String(format: "%@ %@ heldS=%.1f footprintMB=%.1f",
                                   ISO8601DateFormatter().string(from: at), text, heldS,
                                   EloquenceEngine.processFootprintMB()))
        }
    }

    private static func appendStatusNow(_ line: String) {
        statusLock.lock(); defer { statusLock.unlock() }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("engine-status.txt")
        let data = (line + "\n").data(using: .utf8)!
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 65536 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Voices

    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            // Every language the engine carries, the eight presets in each, filed under its BCP-47 tag
            // so VoiceOver lists each under its own language.
            ALL_ELOQUENCE_VOICES.map { def in
                let v = AVSpeechSynthesisProviderVoice(
                    name: def.display,
                    identifier: def.identifier,
                    primaryLanguages: [def.language.bcp47],
                    supportedLanguages: [def.language.bcp47] + def.language.alsoFor
                )
                v.gender = def.gender
                return v
            }
        }
        set { }
    }

    // MARK: - Rate: what VoiceOver says wins; its silence is handled on purpose

    // The rate lands on the SAME engine speed for every voice (ev_speed_units from the standard
    // anchor of 50 - a preset's own speed never leaks in), so the fraction is the whole story.
    //
    // THE TRAP (ClassicVoices, measured on the phone 2026-09-21): at VoiceOver's exact DEFAULT rate
    // iOS sends NO rate at all, and VoiceOver also omits it on the voice-name announcement when you
    // switch voices. So "absent" has to mean something chosen, not whatever was last set:
    //   1. a rate in the request           -> that, remembered for this voice and process-wide;
    //   2. none, but this voice was given one within the last few seconds -> that one
    //      (the switched-to voice's announcement, a burst of VoiceOver speech at one setting);
    //   3. none, but ANY voice was, within the same window -> that one (the announcement is usually
    //      the switched-to voice's FIRST utterance, so 2 alone would miss it);
    //   4. otherwise -> 0.5, the default rate, i.e. the voice's own speed dial (50 for every voice).
    // The window is what keeps a slow utterance from some other app from sticking to VoiceOver's
    // next default-rate request for the rest of the process's life (ClassicVoices' open issue).
    // A fresh audio unit per utterance means the memory must be static.
    static let rateMemoryWindow: TimeInterval = 3.0
    private static var lastFractionByVoice: [String: (fraction: Double, at: Date)] = [:]
    private static var lastFractionAny: (fraction: Double, at: Date)?
    private static let rateLock = NSLock()

    /// The fraction to speak at, and where it came from ("ssml", "voiceMemory", "anyMemory", "default").
    static func rateFraction(fromSSML ssml: String, voiceSlug: String, now: Date = Date()) -> (Double, String) {
        rateLock.lock(); defer { rateLock.unlock() }
        if let pct = SSML.ratePercent(ssml) {
            let fraction = SpeechRate.fraction(fromVOProsodyPercent: pct)
            lastFractionByVoice[voiceSlug] = (fraction, now)
            lastFractionAny = (fraction, now)
            return (fraction, "ssml")
        }
        if let m = lastFractionByVoice[voiceSlug], now.timeIntervalSince(m.at) <= rateMemoryWindow {
            return (m.fraction, "voiceMemory")
        }
        if let m = lastFractionAny, now.timeIntervalSince(m.at) <= rateMemoryWindow {
            return (m.fraction, "anyMemory")
        }
        return (0.5, "default")
    }
}
