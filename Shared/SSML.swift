//
//  SSML.swift
//  What the extension takes from the SSML that VoiceOver (and other speech clients) send: the text,
//  cut into segments at every pause the markup asks for, plus the prosody rate, pitch, pitch range
//  and volume.
//
//  Carried over from ClassicVoices (the author's own generic SSML handling, nothing engine-specific),
//  including its pause lessons:
//   - VoiceOver sends the parts of an element - label, trait, value - as ADJACENT <s> SENTENCES with
//     nothing between them: <s>Speech</s><s>Button</s>. Turning every tag into a space runs them
//     together ("Speech button"). An <s> or <p> boundary therefore ends a segment, and the gap is
//     real silence of a calibrated length (below).
//   - <break time="..."/> / strength="...": explicit pauses.
//   - Commas and full stops inside a text are left to the engine (Eloquence pauses there itself).
//  Each segment is spoken by its own engine call; the pause is the silence computed here. A boundary
//  before the first or after the last text adds nothing, and neighbouring segments that are only
//  digits stay one engine call.
//
//  Added here: `range` (pitch fluctuation) and `volume` prosody attributes, since the Eloquence engine
//  has controls for both (eciPitchFluctuation, eciVolume).
//

import Foundation

enum SSML {
    /// Where a segment ends. Element boundaries: VoiceOver's label | trait | value separator.
    enum Boundary: Int, Comparable {
        case none = 0, sentence, paragraph
        static func < (a: Boundary, b: Boundary) -> Bool { a.rawValue < b.rawValue }
    }

    /// Everything that separates a segment from the next one.
    struct Pause: Equatable {
        /// <break time="..."/>: exact milliseconds (each break capped at 2 s), never scaled with the rate.
        var timeMs = 0
        /// <break strength="..."/> or a bare <break/>: milliseconds at natural speed, scaled with the rate.
        var strengthMs = 0
        /// any <break> at all - then the breaks decide and an element boundary adds nothing
        var hasBreak = false
        /// <s> / <p> element boundary
        var boundary: Boundary = .none

        var isEmpty: Bool { !hasBreak && boundary == .none }
    }

    /// The prosody in force for a stretch of text, from the <prosody> elements it sits inside (nested
    /// ones combined). Everything relative to the voice's own dials: 0 / 1 / 1 = unchanged.
    struct Prosody: Equatable {
        /// pitch shift in semitones (-12 ... 12)
        var semitones = 0.0
        /// x the voice's pitch range (0.5 ... 2)
        var range = 1.0
        /// x the voice's volume (0 ... 1)
        var volume = 1.0

        static let neutral = Prosody()
    }

    struct Segment: Equatable {
        let text: String
        /// the pause after this segment
        var pause: Pause
        /// This segment's pitch, range and volume, from the <prosody> it sits inside (scoped, not the
        /// first one in the request - see segments(_:)).
        var prosody: Prosody

        /// This segment's pitch shift in semitones.
        var semitones: Double { prosody.semitones }

        init(text: String, pause: Pause = Pause(), prosody: Prosody = .neutral) {
            self.text = text
            self.pause = pause
            self.prosody = prosody
        }

        /// Milliseconds of silence after this segment when the voice speaks at `speed` x its natural rate.
        func silenceMs(speed: Double) -> Int { SSML.silenceMs(pause, after: text, speed: speed) }
    }

    // MARK: - Segments

    /// Splits at <break> tags and at <s> / <p> element boundaries. Text is cleaned (tags become
    /// spaces, entities decoded, whitespace collapsed).
    ///
    /// ⛔ PROSODY IS SCOPED, NOT PER REQUEST (ported from ClassicVoices dd4c520, 2026-09-24). With "Use
    /// Pitch Changes" on, VoiceOver lowers only a container's name:
    /// <s><prosody pitch="-15%">Message header</prosody></s><s>...content...</s>, "Dock" in "Dock,
    /// Messages". The old code took the FIRST pitch attribute in the whole request and applied it to
    /// everything, so a request whose first pitch was the label's read the whole line low, and one with an
    /// outer pitch="+0.0%" first ignored the nested one. Each segment now carries the pitch, range and
    /// volume of the <prosody> it sits in (relative values combine with the enclosing element, absolute
    /// ones replace it), and a change of any of them mid-sentence starts a new segment with no pause.
    static func segments(_ ssml: String) -> [Segment] {
        let s = spellOutSayAs(ssml)
        var out: [Segment] = []
        var raw = ""               // this segment's text, tags already turned into spaces, entities not yet decoded
        var hasText = false        // raw holds something other than whitespace
        var pending = Pause()      // pause signals seen since the last text
        var stack: [Prosody] = [.neutral]   // in force, one entry per open <prosody>
        var segProsody = Prosody.neutral    // the prosody of the segment being collected (set at its first text)

        func close() {
            out.append(Segment(text: clean(raw), pause: pending, prosody: segProsody))
            raw = ""
            hasText = false
            pending = Pause()
        }

        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "<", let end = tagEnd(s, from: i) {
                let tag = parseTag(s[s.index(after: i)..<end])
                switch tag.name {
                case "break" where !tag.isEnd:
                    pending.hasBreak = true
                    if let ms = breakTimeMs(tag.attrs) { pending.timeMs += ms }
                    else { pending.strengthMs += breakStrengthMs(tag.attrs) }
                case "s", "p":
                    pending.boundary = max(pending.boundary, tag.name == "p" ? .paragraph : .sentence)
                    raw.append(" ")
                case "prosody":
                    if tag.isEnd {
                        if stack.count > 1 { stack.removeLast() }
                    } else {
                        let p = scoped(tag.attrs, inside: stack.last ?? .neutral)
                        // a self-closing <prosody .../> scopes nothing
                        if !tag.attrs.trimmingCharacters(in: .whitespaces).hasSuffix("/") { stack.append(p) }
                    }
                    raw.append(" ")
                default:
                    raw.append(" ")
                }
                i = s.index(after: end)
                continue
            }
            if !c.isWhitespace {
                let prosody = stack.last ?? .neutral
                if pending.hasBreak {
                    close()                        // (text-less when the breaks came first: leading silence)
                } else if pending.boundary != .none {
                    if hasText { close() } else { pending = Pause() }   // no pause before the first text
                } else if hasText && prosody != segProsody {
                    close()                        // prosody changes mid-sentence: new segment, no pause
                }
                if !hasText { segProsody = prosody }
                hasText = true
            }
            raw.append(c)
            i = s.index(after: i)
        }
        pending.boundary = .none                   // no pause after the last text either
        if hasText || pending.hasBreak { close() }
        return mergingDigitRuns(out)
    }

    /// Neighbouring digit-only segments split by an element boundary stay one engine call (digits
    /// typed or read one at a time must stay snappy).
    private static func mergingDigitRuns(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for seg in segs {
            if let last = out.last, !last.pause.hasBreak, last.pause.boundary != .none,
               last.prosody == seg.prosody, isDigitsOnly(last.text), isDigitsOnly(seg.text) {
                out[out.count - 1] = Segment(text: last.text + " " + seg.text, pause: seg.pause, prosody: seg.prosody)
            } else {
                out.append(seg)
            }
        }
        return out
    }

    static func isDigitsOnly(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isNumber || $0 == " ") }
    }

    // MARK: - Pause lengths

    /// "VoiceOver pauses": how long the silences at VoiceOver's <s> / <p> element boundaries are (the gaps between
    /// "Finder", "Desktop", "Macintosh HD", "selected"). Only those: an explicit <break> keeps its length, and the
    /// pauses the engine adds itself are "Shorten pauses" (PauseSetting), a separate setting. Normal is today's
    /// length exactly; the others scale the whole boundary silence (its minimum included). Asked for by Fubsepude
    /// (Mastodon, 2026-11-22): long gaps inside VoiceOver phrases even with Shorten pauses on Always.
    enum BoundaryPauses: String, CaseIterable, Identifiable {
        case normal, short, minimal
        var id: String { rawValue }
        static let key = "engine.voiceOverPauses"
        var title: String {
            switch self {
            case .normal: return "Normal"
            case .short: return "Short"
            case .minimal: return "Minimal"
            }
        }
        /// Never less than this at a boundary when shortened: at 2x speed Minimal alone would be 20 ms and the words
        /// begin to run together (measured with ReLoq C, 2026-11-22).
        static let floorMs = 30
        /// The share of the Normal boundary silence that is inserted. Measured with ReLoq C on VoiceOver's
        /// <s>Finder</s><s>Desktop</s><s>Macintosh HD</s><s>selected</s> at natural speed with Shorten pauses on
        /// Always (which removes the engine's own ~400 ms end-of-text pause after each part): about 150 ms between the
        /// words at Normal, 75 ms at Short, 40 ms at Minimal.
        var factor: Double {
            switch self {
            case .normal: return 1
            case .short: return 0.5
            case .minimal: return 0.25
            }
        }
    }

    /// Silence at an element boundary at natural speed. ClassicVoices calibrated these on 2026-09-22
    /// against Apple's voices rendering VoiceOver's <s>label</s><s>trait</s> shape (Samantha 240-275 ms
    /// at natural speed). Re-measure with the real Eloquence engine: its own trailing silence adds to
    /// whatever is inserted here.
    static let phraseGapMs = 150
    /// ...after a segment that ends a sentence (. ! ?).
    static let sentenceGapMs = 380
    static let paragraphGapMs = 450
    /// Shortest boundary pause at the fastest rates.
    static let minPhraseGapMs = 50
    static let minSentenceGapMs = 90

    static func silenceMs(_ p: Pause, after text: String, speed: Double, boundaries: BoundaryPauses = .normal) -> Int {
        if p.hasBreak { return p.timeMs + scaled(p.strengthMs, speed: speed) }   // explicit breaks: never scaled
        let gap: Int
        switch p.boundary {
        case .none:
            return 0
        case .sentence:
            gap = endsSentence(text) ? max(minSentenceGapMs, scaled(sentenceGapMs, speed: speed))
                                     : max(minPhraseGapMs, scaled(phraseGapMs, speed: speed))
        case .paragraph:
            gap = max(minSentenceGapMs, scaled(paragraphGapMs, speed: speed))
        }
        if boundaries == .normal { return gap }
        return max(BoundaryPauses.floorMs, Int((Double(gap) * boundaries.factor).rounded()))
    }

    /// A pause at natural speed, at `speed` x natural: shrinks a little slower than the speech itself
    /// when faster (x speed^-0.9), grows much slower than the speech when slower (x speed^-0.4).
    static func scaled(_ ms: Int, speed: Double) -> Int {
        guard ms > 0 else { return 0 }
        let s = speed.isFinite && speed > 0 ? speed : 1
        if s == 1 { return ms }
        return Int((Double(ms) * pow(s, s > 1 ? -0.9 : -0.4)).rounded())
    }

    /// Ends with . ! ? or an ellipsis, allowing closing quotes and brackets after it.
    static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]
        guard let last = text.reversed().first(where: { !$0.isWhitespace && !closers.contains($0) }) else { return false }
        return ".!?\u{2026}".contains(last)
    }

    // MARK: - Text

    /// Strip tags, decode entities, collapse whitespace.
    static func plainText(_ ssml: String) -> String {
        clean(ssml.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
    }

    /// Decode entities, collapse whitespace, trim (text whose tags are already spaces).
    static func clean(_ text: String) -> String {
        decodeEntities(text).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// <say-as interpret-as="characters">abc</say-as> -> "a, b, c".
    static func spellOutSayAs(_ ssml: String) -> String {
        let pattern = #"<say-as\b[^>]*interpret-as\s*=\s*["'](?:characters|spell-out|letters)["'][^>]*>(.*?)</say-as>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return ssml }
        let ns = ssml as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: ssml, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let inner = decodeEntities(ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression))
            let chars = inner.filter { !$0.isWhitespace }.map { String($0) }
            result += " " + escape(chars.joined(separator: ", ")) + " "
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var s = input
        let named = ["&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]{1,6});") {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) != ""
                let digits = ns.substring(with: m.range(at: 2))
                if let v = UInt32(digits, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) {
                    out.unicodeScalars.append(u)
                }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")   // last, so "&amp;lt;" stays "&lt;"
    }

    // MARK: - Tags

    /// The '>' that ends the tag starting at `start` (a '<'): the end of "-->" for a comment, else the
    /// next '>'. nil = no tag here, the '<' is text.
    static func tagEnd(_ s: String, from start: String.Index) -> String.Index? {
        if s[start...].hasPrefix("<!--") {
            return s[start...].range(of: "-->").map { s.index(before: $0.upperBound) }
        }
        return s[s.index(after: start)...].firstIndex(of: ">")
    }

    struct Tag {
        let name: String        // lowercased local name ("" for comments, <?...?>, <!...>)
        let isEnd: Bool
        let attrs: Substring
    }

    /// `body` is what is between '<' and '>'.
    static func parseTag(_ body: Substring) -> Tag {
        var b = body.drop(while: { $0.isWhitespace })
        if b.first == "!" || b.first == "?" { return Tag(name: "", isEnd: false, attrs: b) }
        let isEnd = b.first == "/"
        if isEnd { b = b.dropFirst() }
        let nameEnd = b.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? b.endIndex
        var name = b[..<nameEnd].lowercased()
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        return Tag(name: name, isEnd: isEnd, attrs: b[nameEnd...])
    }

    /// The time attribute in milliseconds (capped at 2 s); nil when absent or unreadable.
    static func breakTimeMs(_ attrs: Substring) -> Int? {
        func cap(_ ms: Double) -> Int { max(0, min(Int(ms.rounded()), 2000)) }
        guard let t = attribute("time", in: String(attrs))?.lowercased().trimmingCharacters(in: .whitespaces)
        else { return nil }
        if t.hasSuffix("ms"), let n = Double(t.dropLast(2)) { return cap(n) }
        if t.hasSuffix("s"), let n = Double(t.dropLast(1)) { return cap(n * 1000) }
        if let n = Double(t) { return cap(n) }
        return nil
    }

    /// The strength attribute (or a bare <break/>) in milliseconds at natural speed.
    static func breakStrengthMs(_ attrs: Substring) -> Int {
        switch attribute("strength", in: String(attrs))?.lowercased() {
        case "none": return 0
        case "x-weak": return 100
        case "weak": return 200
        case "medium": return 350
        case "strong": return 500
        case "x-strong": return 800
        default: return 300
        }
    }

    static func attribute(_ name: String, in attrs: String) -> String? {
        firstMatch(in: attrs, pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']")
    }

    // MARK: - Prosody

    /// VoiceOver sends rate as a float percentage, e.g. rate="130.0%". nil when absent.
    static func ratePercent(_ ssml: String) -> Double? {
        guard let r = firstMatch(in: ssml, pattern: "\\brate\\s*=\\s*[\"']([0-9]+(?:\\.[0-9]+)?)%") else { return nil }
        return Double(r)
    }

    /// The prosody an opening <prosody> tag puts in force inside `parent`. Relative values ("+20%",
    /// "-3dB", "+2st") combine with the parent's, absolute ones ("120%", "x-low", "50%" volume) replace
    /// it; an attribute that is absent or unreadable leaves the parent's value.
    static func scoped(_ attrs: Substring, inside parent: Prosody) -> Prosody {
        let a = String(attrs)
        var p = parent
        if let v = attribute("pitch", in: a), let (st, relative) = pitchValue(v) {
            p.semitones = min(12, max(-12, relative ? parent.semitones + st : st))
        }
        if let v = attribute("range", in: a), let (st, relative) = pitchValue(v) {
            let m = pow(2.0, st / 12.0)
            p.range = min(2, max(0.5, relative ? parent.range * m : m))
        }
        if let v = attribute("volume", in: a), let (m, relative) = volumeValue(v) {
            p.volume = min(1, max(0, relative ? parent.volume * m : m))
        }
        return p
    }

    /// Pitch as a shift in semitones (0 = unchanged). Accepts "120%" (of normal), "+20%" / "-10%"
    /// (relative), "+2st", and the SSML names x-low ... x-high.
    /// Only the FIRST pitch in the request: kept for callers without segments. Segments carry their own
    /// scoped pitch (see segments(_:)); the extension uses those.
    static func pitchSemitones(_ ssml: String) -> Double {
        guard let raw = attributeValue("pitch", in: ssml), let (st, _) = pitchValue(raw) else { return 0 }
        return min(12, max(-12, st))
    }

    /// Pitch range (fluctuation) as a multiple of the voice's own (1.0 = unchanged): same forms as
    /// pitch, so "+50%" is 1.5, "x-low" 0.7, "-6st" about 0.71. First in the request only (as above).
    static func rangeMultiple(_ ssml: String) -> Double {
        guard let raw = attributeValue("range", in: ssml), let (st, _) = pitchValue(raw) else { return 1 }
        return min(2, max(0.5, pow(2.0, st / 12.0)))
    }

    /// Volume as a multiple of the voice's own (1.0 = unchanged). First in the request only (as above).
    static func volumeMultiple(_ ssml: String) -> Double {
        guard let raw = attributeValue("volume", in: ssml), let (m, _) = volumeValue(raw) else { return 1 }
        return min(1, max(0, m))
    }

    /// One pitch (or range) attribute value as semitones, and whether it is relative to the enclosing
    /// value ("+20%", "-10%", "+2st") rather than absolute ("120%", "x-low" ... "x-high", "medium").
    /// nil when empty or unreadable.
    static func pitchValue(_ value: String) -> (Double, Bool)? {
        let raw = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { return nil }
        func st(_ mult: Double) -> Double {
            let m = min(2.0, max(0.5, mult))
            return 12.0 * log2(m)
        }
        switch raw {
        case "x-low": return (st(0.7), false)
        case "low": return (st(0.85), false)
        case "medium", "default": return (0, false)
        case "high": return (st(1.15), false)
        case "x-high": return (st(1.3), false)
        default: break
        }
        let signed = raw.hasPrefix("+") || raw.hasPrefix("-")
        // semitones are always a change from the enclosing pitch
        if raw.hasSuffix("st"), let n = Double(raw.dropLast(2)) { return (min(12, max(-12, n)), true) }
        if raw.hasSuffix("%"), let n = Double(raw.dropLast()) {
            if signed { return (st(1.0 + n / 100.0), true) }
            return (n <= 0 ? 0 : st(n / 100.0), false)
        }
        return nil
    }

    /// One volume attribute value as a multiple, and whether it is relative to the enclosing volume:
    /// "+6dB" / "-3dB" and "+10%" / "-50%" are relative; "50%", a bare 0...100, silent, x-soft, soft,
    /// medium, loud, x-loud are absolute. Not clamped here (the caller clamps the combined value 0...1:
    /// nothing here can make the engine louder than its own dial). nil when empty or unreadable.
    static func volumeValue(_ value: String) -> (Double, Bool)? {
        let raw = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { return nil }
        switch raw {
        case "silent": return (0, false)
        case "x-soft": return (0.25, false)
        case "soft": return (0.5, false)
        case "medium", "default", "loud", "x-loud": return (1, false)
        default: break
        }
        let signed = raw.hasPrefix("+") || raw.hasPrefix("-")
        if raw.hasSuffix("db"), let n = Double(raw.dropLast(2)) { return (pow(10.0, n / 20.0), true) }
        if raw.hasSuffix("%"), let n = Double(raw.dropLast()) {
            return signed ? (max(0, 1.0 + n / 100.0), true) : (max(0, n / 100.0), false)
        }
        if let n = Double(raw) { return (max(0, n / 100.0), false) }   // bare 0...100
        return nil
    }

    /// The first `name="..."` attribute in the document, lowercased and trimmed; nil when absent/empty.
    private static func attributeValue(_ name: String, in ssml: String) -> String? {
        guard let raw = firstMatch(in: ssml, pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']")?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - Diagnostics (structure and numbers only, never words)

    /// The SHAPE of a request's prosody, for the extension's log: every <prosody> start tag in document
    /// order with its nesting depth and its pitch / range / volume / rate values, plus the element
    /// boundaries, e.g. `P0{pitch=+0.0% rate=130%} S P1{pitch=-14.999996%} /P S /P`. No text is ever
    /// included: only tag names and attribute values, and every value is reduced to the characters a
    /// number or an SSML keyword can contain ([0-9A-Za-z.+%-]) and at most 16 of them.
    static func prosodyShape(_ ssml: String) -> String {
        var parts: [String] = []
        var depth = 0
        var i = ssml.startIndex
        while i < ssml.endIndex {
            if ssml[i] == "<", let end = tagEnd(ssml, from: i) {
                let tag = parseTag(ssml[ssml.index(after: i)..<end])
                switch tag.name {
                case "prosody":
                    if tag.isEnd {
                        depth = max(0, depth - 1)
                        parts.append("/P")
                    } else {
                        let a = String(tag.attrs)
                        let vals = ["pitch", "range", "volume", "rate"].compactMap { name in
                            attribute(name, in: a).map { "\(name)=\(safeValue($0))" }
                        }
                        parts.append("P\(depth){\(vals.joined(separator: " "))}")
                        if !a.trimmingCharacters(in: .whitespaces).hasSuffix("/") { depth += 1 }
                    }
                case "s" where !tag.isEnd: parts.append("S")
                case "p" where !tag.isEnd: parts.append("Para")
                case "break" where !tag.isEnd: parts.append("B")
                default: break
                }
                i = ssml.index(after: end)
            } else {
                i = ssml.index(after: i)
            }
        }
        // cap the line: a long page read in one request can carry many elements
        if parts.count > 40 { parts = Array(parts.prefix(40)) + ["...+\(parts.count - 40)"] }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }

    /// The punctuation SKELETON of the segments the engine is handed, for the log: every run of letters
    /// is `a`, every run of digits `9`, every run of whitespace `_`, anything outside ASCII (an emoji, a
    /// direction mark) `*`, ASCII punctuation as it is; segments joined by `|`, cut at 120 characters.
    /// No word can be read back from it - it says where the commas and segment boundaries fall, which is
    /// what "is there a pause after Grouped?" needs (2026-09-24): "KNIGHT MANAGER, Grouped, 1 hour" is
    /// `a_a,_a,_9_a`.
    static func textSkeleton(_ segments: [Segment]) -> String {
        var out = ""
        for (n, seg) in segments.enumerated() {
            if n > 0 { out += "|" }
            var last: Character = "\0"
            for u in seg.text.unicodeScalars {
                let c: Character
                if CharacterSet.letters.contains(u) && u.isASCII { c = "a" }
                else if u.properties.numericType != nil && u.isASCII { c = "9" }
                else if CharacterSet.whitespacesAndNewlines.contains(u) { c = "_" }
                else if u.isASCII && CharacterSet.punctuationCharacters.union(.symbols).contains(u) { c = Character(u) }
                else if u.isASCII { c = "?" }
                else { c = "*" }
                if (c == "a" || c == "9" || c == "_" || c == "*") && c == last { continue }
                out.append(c)
                last = c
            }
        }
        if out.count > 120 { out = String(out.prefix(120)) + "..." }
        return out.isEmpty ? "none" : out
    }

    private static func safeValue(_ v: String) -> String {
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+%-")
        let kept = String(v.filter { allowed.contains($0) }.prefix(16))
        return kept.isEmpty ? "?" : kept
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
