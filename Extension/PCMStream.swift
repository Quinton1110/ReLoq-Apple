//
//  PCMStream.swift
//  Hand-off between the synthesis thread (producer) and the audio unit's render block (consumer),
//  so audio starts playing while the rest of the utterance is still being synthesized.
//  (Carried over from ClassicVoices; the pause handling below is ours.)
//
//  Every utterance gets a generation number. Cancelling bumps it, which makes the producer's next
//  append fail (so the engine stops within one chunk) and lets the render block report completion.
//
//  PAUSES (2026-11-19). While the host pulls audio, the engine stays at most
//  20 s ahead of playback. It used to give up on a producer whose host had not pulled for 15 s, and
//  then the render block played what was buffered and reported the utterance complete: a long read
//  paused for 15 s or more stopped about 20 s after it was resumed, mid-word (measured on the Mac:
//  pauses up to 14 s heard the whole 149 s, 15.5-60 s heard 20.1 s). Now, once the host has not
//  pulled for 2 s (a pause), the run-ahead limit is lifted and the engine makes the REST of the
//  utterance into memory, then finishes and gives its thread back to the pool, so a pause can last
//  as long as the host keeps the utterance. Bounds:
//   - one utterance holds at most 13.2 MB of audio (16-bit: 10 minutes at 11,025 Hz, 2 min 18 s at
//     48 kHz), all of them together 26.5 MB (the extension normally weighs 9-19 MB, its limit on iOS is
//     about 160 MB) - the ceilings are MEMORY, so a higher sample rate holds fewer seconds;
//   - at a ceiling the engine waits for playback, and gives up only after 10 minutes without a pull;
//   - while every engine thread is busy, the producer whose host has gone longest without pulling (at
//     least 1 s) gives its thread up (`yieldLongestPaused`) - at once if a request is waiting, and ahead
//     of time otherwise, so the next request finds a free thread instead of waiting for the yielded
//     engine to finish its sentence: new speech is never held behind a parked pause;
//   - cancel, a new request on the same audio unit, or the audio unit going away free the held audio
//     at once (page-backed blocks, so the memory goes back to the system, not to malloc's free lists).
//  Every pause is written to the status file when it starts and when it ends (resumed, cancelled,
//  replaced, audio unit released, or our own give-up, each with how long it lasted), so the phone's
//  engine-status.txt shows how long VoiceOver really keeps a paused utterance.
//

import Foundation

/// 16-bit audio in page-backed blocks. mmap'd rather than malloc'd so that freeing a block gives its
/// memory back to the system at once (malloc may keep freed blocks in its zones, and the extension's
/// memory limit would go on counting them).
private final class Chunk {
    static let samples = 65536                                   // 128 KB, ~5.9 s at 11025 Hz
    static let bytes = samples * MemoryLayout<Int16>.size
    let p: UnsafeMutablePointer<Int16>
    var count = 0
    init?() {
        let raw = mmap(nil, Self.bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let raw, raw != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        p = raw.bindMemory(to: Int16.self, capacity: Self.samples)
    }
    deinit { munmap(p, Self.bytes) }
}

final class PCMStream {
    /// While the host pulls, keep at most this much unread audio; the engine is far faster than real time.
    static let runAheadSeconds: Double = 20
    /// No pull for this long = a pause: the engine may make the rest of the utterance into memory.
    static let pauseAfter: TimeInterval = 2
    /// The most audio one paused utterance may hold, as seconds AT 11,025 Hz: the ceilings bound memory
    /// (samples), not time, so at a higher sample rate they hold proportionally fewer seconds.
    static let utteranceCeilingSeconds: Double = 600
    /// The most audio every stream in the process may hold together (seconds at 11,025 Hz).
    static let processCeilingSeconds: Double = 1200
    static let ceilingRate: Double = 11025
    /// At a ceiling, a host that has not pulled for this long is given up on (what is held stays playable).
    static let giveUpAfter: TimeInterval = 600
    /// When every engine thread is busy, a producer whose host has not pulled for this long may be asked
    /// to give its thread up.
    static let yieldAfter: TimeInterval = 1

    private let cond = NSCondition()
    private var chunks: [Chunk] = []
    private var headPos = 0              // read position in chunks[0]
    private var queued = 0               // unread samples
    private var gen: UInt64 = 0
    private var finished = true          // the producer is done (or nothing queued): a render completes when drained
    private var playing = false          // an utterance begun and neither completed nor cancelled
    private var lastPull = Date()
    private var producing: UInt64 = 0    // the generation whose producer holds an engine thread
    private var yieldGen: UInt64 = 0     // asked to give that thread up
    private var label = ""
    // the pause in progress, if any (reset by every pull)
    private var pauseNoted = false
    private var aheadNoted = false
    private var ceilingNoted = false

    /// The rate of the utterance in progress (each `begin` may set another: the output sample-rate
    /// setting, 2026-11-19); run-ahead and silences are timed with it.
    private(set) var sampleRate: Double
    private var runAhead: Int
    private let utteranceCeiling: Int
    private let processCeiling: Int
    private let note: (String) -> Void

    /// `note` receives one status line per pause event (no spoken content) the moment it happens, with this
    /// stream's lock held: it must not call back into the stream (the provider's logs and queues the line).
    init(sampleRate: Double, note: @escaping (String) -> Void = { _ in }) {
        self.sampleRate = sampleRate
        self.runAhead = Int(sampleRate * Self.runAheadSeconds)
        self.utteranceCeiling = Int(Self.ceilingRate * Self.utteranceCeilingSeconds)
        self.processCeiling = Int(Self.ceilingRate * Self.processCeilingSeconds)
        self.note = note
        Self.register(self)
    }

    deinit {
        Self.addHeld(-queued, sampleRate)
    }

    // MARK: - Producer

    /// Starts a new utterance, discarding anything left of the previous one. `sampleRate` (nil = as before)
    /// is the rate this utterance's samples are made at.
    func begin(label: String = "", sampleRate rate: Double? = nil) -> UInt64 {
        cond.lock()
        let ending = pauseEnding("replaced by a new request")
        gen &+= 1
        dropAll()
        if let ending { say(ending) }        // after the free, so its heldS= is what is left
        if let rate, rate > 0, rate != sampleRate {
            sampleRate = rate
            runAhead = Int(rate * Self.runAheadSeconds)
        }
        finished = false
        playing = true
        lastPull = Date()
        self.label = label
        cond.broadcast()
        let g = gen
        cond.unlock()
        Self.kickMonitor()
        return g
    }

    /// The producer of utterance `g` has an engine thread (until `producerEnded`).
    func producerStarted(_ g: UInt64) {
        cond.lock(); producing = g; cond.unlock()
    }

    func producerEnded(_ g: UInt64) {
        cond.lock(); if producing == g { producing = 0 }; cond.unlock()
    }

    /// Appends engine PCM. Returns false once this utterance is cancelled or superseded, or its producer
    /// has to give up (yielded its thread, or a ceiling outlasted the pause).
    func append(_ g: UInt64, _ pcm: UnsafeBufferPointer<Int16>) -> Bool {
        guard let base = pcm.baseAddress, pcm.count > 0 else { return isLive(g) }
        return admit(g) { write(base, pcm.count) }
    }

    /// Appends `ms` of silence (for SSML breaks and the short end pad).
    @discardableResult
    func appendSilence(_ g: UInt64, ms: Int) -> Bool {
        let n = Int(Double(ms) / 1000.0 * sampleRate)
        guard n > 0 else { return isLive(g) }
        return admit(g) { write(nil, n) }
    }

    /// false once utterance `g` is cancelled or superseded (nothing it made would be heard).
    func isLive(_ g: UInt64) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return g == gen && !finished
    }

    func finish(_ g: UInt64) {
        cond.lock(); defer { cond.unlock() }
        if g == gen { finished = true }
        cond.broadcast()
    }

    enum Ending: String {
        case cancelled = "cancelled"
        case released = "audio unit released"
    }

    /// Stops whatever is playing or being synthesized, and frees what was held for it.
    func cancel(_ why: Ending = .cancelled) {
        cond.lock(); defer { cond.unlock() }
        let ending = pauseEnding(why.rawValue)
        gen &+= 1
        dropAll()
        if let ending { say(ending) }
        finished = true
        playing = false
        cond.broadcast()
    }

    /// Blocks (bounded) until the utterance has audio or is over.
    func waitForAudio(_ g: UInt64, timeout: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        cond.lock(); defer { cond.unlock() }
        while g == gen && !finished && queued == 0 {
            if !cond.wait(until: deadline) { break }
        }
    }

    private func admit(_ g: UInt64, _ body: () -> Bool) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard waitForRoom(g) else { return false }
        let ok = body()
        cond.broadcast()
        return ok
    }

    // caller holds the lock
    private func waitForRoom(_ g: UInt64) -> Bool {
        while g == gen && !finished {
            let idle = Date().timeIntervalSince(lastPull)
            if yieldGen == g {
                say(String(format: "pause gave up making the rest after %.1fs: every engine thread was busy, it gave its own up for new speech (%.1fs held)",
                                    idle, seconds(queued)))
                return false
            }
            if queued <= runAhead { return true }
            if idle >= Self.pauseAfter {
                if !pauseNoted { pauseNoted = true; say(startText(idle)) }
                if queued < utteranceCeiling && Self.heldSamples < processCeiling {
                    if !aheadNoted {
                        aheadNoted = true
                        say(String(format: "pause: making the rest of the utterance into memory (%.0fs ahead, ceiling %.0fs)",
                                    seconds(queued), seconds(utteranceCeiling)))
                    }
                    return true
                }
                if !ceilingNoted {
                    ceilingNoted = true
                    say(String(format: "pause: memory ceiling reached (%.1fs held here, %.1fs in all); waiting for playback",
                                seconds(queued), Self.heldSeconds))
                }
                if idle >= Self.giveUpAfter {
                    say(String(format: "pause gave up making the rest after %.1fs at the memory ceiling (%.1fs held)",
                                idle, seconds(queued)))
                    return false
                }
            }
            _ = cond.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
        return false
    }

    // caller holds the lock. src nil = silence.
    private func write(_ src: UnsafePointer<Int16>?, _ n: Int) -> Bool {
        var off = 0
        defer { queued += off; Self.addHeld(off, sampleRate) }
        while off < n {
            if chunks.isEmpty || chunks[chunks.count - 1].count == Chunk.samples {
                guard let c = Chunk() else { return false }
                chunks.append(c)
            }
            let c = chunks[chunks.count - 1]
            let take = min(Chunk.samples - c.count, n - off)
            if let src { (c.p + c.count).update(from: src + off, count: take) }
            else { (c.p + c.count).update(repeating: 0, count: take) }
            c.count += take
            off += take
        }
        return true
    }

    // caller holds the lock
    private func dropAll() {
        chunks.removeAll()
        headPos = 0
        Self.addHeld(-queued, sampleRate)
        queued = 0
        pauseNoted = false; aheadNoted = false; ceilingNoted = false
    }

    // caller holds the lock: the utterance in progress is ending; if its host had stopped pulling, how long for
    private func pauseEnding(_ how: String) -> String? {
        guard playing else { return nil }
        let idle = Date().timeIntervalSince(lastPull)
        guard idle >= Self.pauseAfter else { return nil }
        return String(format: "pause ended: %@ after %.1fs (%.1fs of audio freed)", how, idle, seconds(queued))
    }

    private func startText(_ idle: TimeInterval) -> String {
        String(format: "pause started: no pull for %.1fs, %.1fs unread, engine %@", idle, seconds(queued),
               producing == gen && !finished ? "still making the utterance" : "done with it")
    }

    // caller holds the lock: one status line, now, labelled with the voice
    private func say(_ s: String) { note("voice=\(label) \(s)") }
    private func seconds(_ samples: Int) -> Double { Double(samples) / sampleRate }

    // MARK: - Consumer (render block)

    /// Copies up to `frames` samples into `out`. Waits (at most `maxWait`) if the producer has not
    /// caught up yet. `done` = the utterance is over and everything has been handed out.
    func read(into out: UnsafeMutablePointer<Float32>, frames: Int, maxWait: TimeInterval) -> (count: Int, done: Bool) {
        cond.lock()
        let now = Date()
        let gap = now.timeIntervalSince(lastPull)
        let resumed = playing && gap >= Self.pauseAfter
        if resumed {
            say(String(format: "pause ended: resumed after %.1fs (%.1fs unread)", gap, seconds(queued)))
        }
        lastPull = now
        pauseNoted = false; aheadNoted = false; ceilingNoted = false
        // Wait for a WHOLE buffer (or the end), not just for anything: a render call has to fill all `frames`
        // unless the utterance is over, and a host treats a short buffer as full - the iPhone's system path played
        // the zero-filled rest, ~130 inserted gaps of 1-3 ms in one sentence at 22 and 48 kHz, where the engine
        // makes audio closer to the speed the offline host pulls it (measured 2026-11-19, iPhone Air). At 11025 Hz
        // the engine was always far enough ahead, which is why it never showed.
        if !finished && queued < frames {
            let deadline = Date(timeIntervalSinceNow: maxWait)
            while !finished && queued < frames {
                if !cond.wait(until: deadline) { break }
            }
        }
        var n = min(queued, frames)
        if n > 0 {
            n = copyOut(out, n)
            cond.broadcast()   // room for a producer waiting on the run-ahead limit
        }
        let done = finished && queued == 0
        if done {
            chunks.removeAll()
            headPos = 0
            playing = false
        }
        cond.unlock()
        if resumed { Self.kickMonitor() }   // it may pause again
        return (n, done)
    }

    // caller holds the lock; n <= queued. Returns the samples copied (n).
    private func copyOut(_ out: UnsafeMutablePointer<Float32>, _ n: Int) -> Int {
        let scale: Float32 = 1.0 / 32768.0
        var done = 0
        while done < n, let c = chunks.first {
            let take = min(c.count - headPos, n - done)
            if take <= 0 { break }               // cannot happen: queued counts what the blocks hold
            let src = c.p + headPos
            for i in 0..<take { out[done + i] = Float32(src[i]) * scale }
            done += take
            headPos += take
            // a block read to its end goes back to the system, unless the producer is still filling it
            if headPos == c.count && (chunks.count > 1 || c.count == Chunk.samples) {
                chunks.removeFirst()
                headPos = 0
            }
        }
        queued -= done
        Self.addHeld(-done, sampleRate)
        return done
    }

    // MARK: - Process-wide: memory held, the pause monitor, giving a thread up

    private static let heldLock = NSLock()
    private static var held = 0          // unread samples in every stream
    private static var heldSec = 0.0     // the same in seconds, each stream at its own rate
    private static func addHeld(_ n: Int, _ rate: Double) {
        if n != 0 { heldLock.lock(); held += n; heldSec = max(0, heldSec + Double(n) / rate); if held == 0 { heldSec = 0 }; heldLock.unlock() }
    }
    static var heldSamples: Int { heldLock.lock(); defer { heldLock.unlock() }; return held }
    /// Every stream's unread audio in seconds (each at its own sample rate).
    static var heldSeconds: Double { heldLock.lock(); defer { heldLock.unlock() }; return heldSec }

    private final class Weak { weak var s: PCMStream?; init(_ s: PCMStream) { self.s = s } }
    private static let registryLock = NSLock()
    private static var registry: [Weak] = []
    private static var monitorScheduled = false
    private static var monitorKicked = false
    private static let monitorQueue = DispatchQueue(label: "com.quinton.eloquencevoices.pause-monitor", qos: .utility)

    private static func register(_ s: PCMStream) {
        registryLock.lock()
        registry.removeAll { $0.s == nil }
        registry.append(Weak(s))
        registryLock.unlock()
    }

    private static func streams() -> [PCMStream] {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry.compactMap { $0.s }
    }

    /// Watches every utterance in progress every 0.5 s while one could still start a pause, and every 0.1 s
    /// while every engine thread is busy: writes the start of a pause whose producer is not there to see it
    /// (the utterance was already fully made), and asks a paused producer to give its thread up when needed.
    /// No engine work happens here, so a GCD queue is fine.
    static func kickMonitor() {
        registryLock.lock()
        monitorKicked = true
        let start = !monitorScheduled
        monitorScheduled = true
        registryLock.unlock()
        if start { monitorQueue.asyncAfter(deadline: .now() + 0.5) { monitorTick() } }
    }

    private static func monitorTick() {
        registryLock.lock()
        monitorKicked = false
        registry.removeAll { $0.s == nil }
        registryLock.unlock()
        var again = false
        for s in streams() where s.watch() { again = true }
        let busy = EngineThread.shared.queuedWithoutThread > 0 || EngineThread.shared.isFull
        if busy { yieldLongestPaused(); again = true }
        registryLock.lock()
        again = again || monitorKicked
        monitorScheduled = again
        registryLock.unlock()
        if again { monitorQueue.asyncAfter(deadline: .now() + (busy ? 0.1 : 0.5)) { monitorTick() } }
    }

    /// Monitor: writes a pause's start. true = this stream still needs watching.
    private func watch() -> Bool {
        cond.lock(); defer { cond.unlock() }
        let idle = Date().timeIntervalSince(lastPull)
        if playing && !pauseNoted && idle >= Self.pauseAfter {
            pauseNoted = true
            say(startText(idle))
        }
        return playing && !pauseNoted
    }

    private static let yieldLock = NSLock()

    /// Every engine thread is busy: the producer whose host has gone longest without pulling (at least
    /// `yieldAfter`) gives its thread up - its next append fails, so the engine stops as on a cancel, and what it
    /// had made stays playable. At most one per waiting request, or one in all when none is waiting yet.
    static func yieldLongestPaused() {
        yieldLock.lock(); defer { yieldLock.unlock() }
        var wanted = EngineThread.shared.queuedWithoutThread
        if wanted == 0 && EngineThread.shared.isFull { wanted = 1 }
        guard wanted > 0 else { return }
        let now = Date()
        var pending = 0
        var best: (s: PCMStream, g: UInt64, idle: TimeInterval)?
        for s in streams() {
            s.cond.lock()
            if s.producing != 0 && s.yieldGen == s.producing {
                pending += 1                     // asked already, its thread not back yet
            } else if s.producing != 0 && s.producing == s.gen && !s.finished {
                let idle = now.timeIntervalSince(s.lastPull)
                if idle >= yieldAfter && idle > (best?.idle ?? -1) { best = (s, s.gen, idle) }
            }
            s.cond.unlock()
        }
        guard pending < wanted, let b = best else { return }
        b.s.cond.lock()
        if b.s.gen == b.g && b.s.producing == b.g && !b.s.finished {
            b.s.yieldGen = b.g
            b.s.cond.broadcast()
        }
        b.s.cond.unlock()
    }
}
