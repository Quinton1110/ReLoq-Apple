// Mac test of the extension's SSML handling (Shared/SSML.swift, the same file the iOS targets compile):
// segments and pauses, the SCOPED prosody (pitch / range / volume from the <prosody> each piece of text
// sits in - ported from ClassicVoices dd4c520, 2026-09-24) and the privacy of the diagnostic shape line.
// `make ssml-test` (also part of `make test`).

import Foundation

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if ok { passes += 1 } else { failures += 1 }
}

func texts(_ segs: [SSML.Segment]) -> [String] { segs.map(\.text) }
func gaps(_ segs: [SSML.Segment], speed: Double = 1) -> [Int] { segs.map { $0.silenceMs(speed: speed) } }
func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
func pitches(_ segs: [SSML.Segment]) -> [Double] { segs.map { r2($0.prosody.semitones) } }
func ranges(_ segs: [SSML.Segment]) -> [Double] { segs.map { r2($0.prosody.range) } }
func volumes(_ segs: [SSML.Segment]) -> [Double] { segs.map { r2($0.prosody.volume) } }
let low = r2(12 * log2(0.85))          // "-15%" and "low" both come to this
let plus20 = r2(12 * log2(1.2))
let minus3dB = r2(pow(10, -3.0 / 20))

// MARK: - Segments and pauses (behaviour carried over unchanged)

var s = SSML.segments("<speak><s>Speech</s><s>button</s></speak>")
check(texts(s) == ["Speech", "button"] && gaps(s) == [SSML.phraseGapMs, 0], "<s>Speech</s><s>button</s> -> two segments \(gaps(s))")
s = SSML.segments(#"<speak><prosody rate="100.0%" pitch="+0%"><s><lang xml:lang="en-US">Speech</lang></s><s><lang xml:lang="en-US">Button</lang></s></prosody></speak>"#)
check(texts(s) == ["Speech", "Button"] && pitches(s) == [0, 0], "VoiceOver shape with <prosody>/<lang> -> Speech | Button at pitch 0")
check(SSML.ratePercent(#"<prosody rate="130.0%">x</prosody>"#) == 130, "rate still read from <prosody>")
s = SSML.segments("Speech, button")
check(texts(s) == ["Speech, button"] && gaps(s) == [0], "plain text with a comma stays one segment")
s = SSML.segments(#"<speak>Speech<break time="300ms"/>button</speak>"#)
check(texts(s) == ["Speech", "button"] && gaps(s) == [300, 0] && gaps(s, speed: 3) == [300, 0], "break time=300ms exact at any speed")
s = SSML.segments("<speak><s>5</s><s>0</s><s>3</s></speak>")
check(texts(s) == ["5 0 3"], "digit-only sentences stay one engine call \(texts(s))")
s = SSML.segments("")
check(s.isEmpty, "empty request -> no segments")
s = SSML.segments(#"<speak><say-as interpret-as="characters">abc</say-as></speak>"#)
check(texts(s) == ["a, b, c"], "say-as characters spelled out \(texts(s))")
s = SSML.segments("<speak>a &lt;b&gt; &amp; c</speak>")
check(texts(s) == ["a <b> & c"], "entities decoded \(texts(s))")

// MARK: - Scoped pitch (the ClassicVoices captures, 2026-09-24)

s = SSML.segments(#"<speak><prosody rate="160%" volume="-3dB"><s><lang xml:lang="en-US"><prosody pitch="-14.999996%">Message header</prosody></lang></s><s><lang xml:lang="en-US">From Maybe Shaf - 12 minutes ago</lang></s></prosody></speak>"#)
check(texts(s) == ["Message header", "From Maybe Shaf - 12 minutes ago"] && pitches(s) == [low, 0],
      "no outer pitch: only the label is lowered \(pitches(s))")
check(volumes(s) == [minus3dB, minus3dB], "the outer volume=-3dB reaches both segments \(volumes(s))")
s = SSML.segments(#"<speak><prosody pitch="+0.0%" rate="130%"><s><lang xml:lang="en-US"><prosody pitch="-14.999996%">Message content</prosody></lang></s><s><lang xml:lang="en-US">The rest reads normally.</lang></s></prosody></speak>"#)
check(texts(s) == ["Message content", "The rest reads normally."] && pitches(s) == [low, 0],
      "outer pitch first (the old first-match trap): the label is still lowered \(pitches(s))")
s = SSML.segments(#"<speak><s><prosody pitch="-15%">Dock</prosody>, Messages</s></speak>"#)
check(texts(s) == ["Dock", ", Messages"] && pitches(s) == [low, 0] && gaps(s) == [0, 0],
      "pitch change inside a sentence: split with no pause \(texts(s)) \(pitches(s))")
s = SSML.segments(#"<speak><prosody pitch="+20%">typed</prosody></speak>"#)
check(texts(s) == ["typed"] && pitches(s) == [plus20], "whole-request pitch still applies \(pitches(s))")
s = SSML.segments(#"<speak><prosody pitch="+2st"><prosody pitch="-1st">a</prosody> b</prosody> c</speak>"#)
check(texts(s) == ["a", "b", "c"] && pitches(s) == [1, 2, 0], "nested relative pitch adds, and ends with its element \(pitches(s))")
s = SSML.segments(#"<speak><prosody pitch="+2st"><prosody pitch="low">a</prosody></prosody></speak>"#)
check(pitches(s) == [low], "absolute pitch inside relative replaces it \(pitches(s))")
s = SSML.segments(#"<speak><prosody pitch="+10st"><prosody pitch="+10st">a</prosody></prosody></speak>"#)
check(pitches(s) == [12], "nested pitch is clamped to an octave \(pitches(s))")
s = SSML.segments(#"<speak><s><prosody pitch="-15%">5</prosody></s><s>0</s></speak>"#)
check(texts(s) == ["5", "0"], "digits at different pitches are not merged \(texts(s))")
s = SSML.segments(#"<speak><prosody pitch="-15%"/>after</speak>"#)
check(pitches(s) == [0], "a self-closing <prosody/> scopes nothing \(pitches(s))")
s = SSML.segments(#"<speak>a</prosody> b</speak>"#)
check(texts(s) == ["a b"] && pitches(s) == [0], "a stray </prosody> does not underflow the stack")

// MARK: - Scoped range and volume (they had the same first-match flaw)

s = SSML.segments(#"<speak><prosody range="+50%">wide</prosody> plain</speak>"#)
check(texts(s) == ["wide", "plain"] && ranges(s) == [1.5, 1], "range scoped to its element \(ranges(s))")
s = SSML.segments(#"<speak><prosody range="x-low"><prosody range="+12st">a</prosody></prosody></speak>"#)
check(ranges(s) == [1.4], "nested relative range multiplies (0.7 x 2) \(ranges(s))")
s = SSML.segments(#"<speak><prosody volume="50%">quiet</prosody> <prosody volume="+6dB">loud</prosody> plain</speak>"#)
check(texts(s) == ["quiet", "loud plain"] && volumes(s) == [0.5, 1], "volume scoped; +6dB never above the voice's own, so it joins the plain text \(texts(s)) \(volumes(s))")
s = SSML.segments(#"<speak><prosody volume="-6dB"><prosody volume="-50%">a</prosody> b</prosody></speak>"#)
check(volumes(s) == [r2(pow(10, -6.0 / 20) * 0.5), r2(pow(10, -6.0 / 20))], "nested relative volume multiplies \(volumes(s))")
s = SSML.segments(#"<speak><prosody volume="-6dB"><prosody volume="soft">a</prosody></prosody></speak>"#)
check(volumes(s) == [0.5], "absolute volume inside relative replaces it \(volumes(s))")
s = SSML.segments(#"<speak><prosody volume="silent">a</prosody></speak>"#)
check(volumes(s) == [0], "silent -> 0")

// MARK: - The first-match helpers (kept for callers without segments)

check(r2(SSML.pitchSemitones(#"<prosody pitch="-15%">a</prosody>"#)) == low, "pitchSemitones reads a relative percent")
check(SSML.pitchSemitones("<speak>a</speak>") == 0, "pitchSemitones absent -> 0")
check(r2(SSML.rangeMultiple(#"<prosody range="+50%">a</prosody>"#)) == 1.5, "rangeMultiple +50% -> 1.5")
check(r2(SSML.volumeMultiple(#"<prosody volume="-3dB">a</prosody>"#)) == minus3dB, "volumeMultiple -3dB -> \(minus3dB)")
check(SSML.volumeMultiple(#"<prosody volume="+6dB">a</prosody>"#) == 1, "volumeMultiple never above 1")

// MARK: - The diagnostic shape line: structure and numbers, never words

let secret = "Zebrafish Quixotic 4471"
let shape = SSML.prosodyShape(#"<speak><prosody pitch="+0.0%" rate="130%" volume="-3dB"><s><prosody pitch="-14.999996%">"# + secret + #"</prosody></s><s>"# + secret + #"<break time="200ms"/></s></prosody></speak>"#)
check(shape == "P0{pitch=+0.0% volume=-3dB rate=130%} S P1{pitch=-14.999996%} /P S B /P", "shape: \(shape)")
let skel = SSML.textSkeleton(SSML.segments("<speak><s>KNIGHT MANAGER, Grouped, 1 hour ago, \u{1F4EF} Announcement from Maximilian , The Bone \u{200E}Forest (Yellow Zone).</s><s>Zebrafish 4471</s></speak>"))
check(skel == "a_a,_a,_9_a_a,_*_a_a_a_,_a_a_*a_(a_a).|a_9", "text skeleton: \(skel)")
check(!skel.contains("Zebrafish") && !skel.contains("4471") && !skel.contains("KNIGHT"), "the skeleton carries none of the words or numbers")
check(!shape.contains("Zebrafish") && !shape.contains("Quixotic") && !shape.contains("4471"), "shape carries none of the spoken words")
let hostile = SSML.prosodyShape(#"<prosody pitch="say my secret words out loud please">x</prosody>"#)
check(hostile == "P0{pitch=saymysecretwords} /P", "attribute values are filtered and cut to 16 characters: \(hostile)")
check(SSML.prosodyShape("just words") == "none", "no markup -> none")

// MARK: - VoiceOver pauses (SSML.BoundaryPauses, 2026-11-22): only the <s>/<p> boundary silences scale

func vgaps(_ segs: [SSML.Segment], _ b: SSML.BoundaryPauses, speed: Double = 1) -> [Int] {
    segs.map { SSML.silenceMs($0.pause, after: $0.text, speed: speed, boundaries: b) }
}
let finder = SSML.segments("<speak><s>Finder</s><s>Desktop</s><s>Macintosh HD</s><s>selected</s></speak>")
check(vgaps(finder, .normal) == [150, 150, 150, 0], "VoiceOver pauses Normal: Finder | Desktop | Macintosh HD | selected \(vgaps(finder, .normal))")
check(vgaps(finder, .short) == [75, 75, 75, 0], "Short: half \(vgaps(finder, .short))")
check(vgaps(finder, .minimal) == [38, 38, 38, 0], "Minimal: a quarter \(vgaps(finder, .minimal))")
check(vgaps(finder, .short, speed: 2) == [40, 40, 40, 0] && vgaps(finder, .minimal, speed: 2) == [30, 30, 30, 0],
      "at 2x speed: Short \(vgaps(finder, .short, speed: 2)), Minimal held at the 30 ms floor \(vgaps(finder, .minimal, speed: 2))")
let paras = SSML.segments("<speak><p><s>Mail.</s><s>Inbox</s></p><p><s>3 unread messages.</s></p></speak>")
check(vgaps(paras, .normal) == [380, 450, 0] && vgaps(paras, .short) == [190, 225, 0] && vgaps(paras, .minimal) == [95, 113, 0],
      "sentence and paragraph boundaries scale too: \(vgaps(paras, .normal)) \(vgaps(paras, .short)) \(vgaps(paras, .minimal))")
let breaks = SSML.segments(#"<speak><s>a</s><break time="300ms"/><s>b</s><break strength="strong"/><s>c</s></speak>"#)
check(vgaps(breaks, .minimal) == vgaps(breaks, .normal) && vgaps(breaks, .short, speed: 1.7) == vgaps(breaks, .normal, speed: 1.7),
      "explicit <break> time and strength keep their length at every option: \(vgaps(breaks, .minimal))")
var same = true
for sp in stride(from: 0.25, through: 4.0, by: 0.05) {
    for seg in finder + paras + breaks + SSML.segments("<speak><s>One.</s><s>two</s><p>three</p></speak>") {
        if SSML.silenceMs(seg.pause, after: seg.text, speed: sp, boundaries: .normal) != seg.silenceMs(speed: sp) { same = false }
    }
}
check(same, "Normal is exactly the old silence at every speed 0.25x-4x (byte-identical output)")
check(SSML.BoundaryPauses.allCases.map(\.title) == ["Normal", "Short", "Minimal"] && SSML.BoundaryPauses.key == "engine.voiceOverPauses",
      "titles and the stored key")

print("\(passes) ok, \(failures) failed")
exit(failures == 0 ? 0 : 1)
