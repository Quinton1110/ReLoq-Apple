//
//  PhoneticRespelling.swift
//  Eloquence's phoneme code (`[.2e.1ra.0nXk] - the annotation the community dictionary uses for ~69,000
//  entries) as a respelling a person can read, dictionary style: syllables joined by hyphens, the
//  stressed one in capitals - "air-RAH-nihk" (2026-09-24: VoiceOver reading the raw code out is no
//  use to anyone).
//
//  The symbols are the engine's own US English set (openevv lang/enus; checked against what the engine
//  itself answers for known words): vowels i I e E A a c o U u H x X R Y W O, syllabic N M, consonants
//  p b t d k g f v T D s z S Z h m n G l r w y C J, the flap F and the glottal stop ?; a syllable is
//  `.` + stress (1 primary, 2 secondary, 0 none) + its phonemes.
//
//  The spelling of each sound was chosen so that the respelling, READ ALOUD BY ELOQUENCE ITSELF (which is
//  how a listener hears it), comes back as the same sounds: Tests/userdict measures that over real entries.
//
//  Anything that cannot be converted cleanly gives nil, and the caller says "phonetic entry" instead -
//  never the symbols. Pure Swift, no dependencies (compiled by `make userdict-test`).
//

import Foundation

enum PhoneticRespelling {
    /// What the editor shows / VoiceOver reads for a dictionary replacement: plain words as they are;
    /// phoneme codes as a respelling; "phonetic entry" when a code cannot be converted cleanly.
    static func display(_ replacement: String) -> String {
        guard replacement.contains("`") else { return replacement }
        return respell(replacement) ?? "phonetic entry"
    }

    /// The same for VoiceOver: all small, because Eloquence SPELLS a short word in capitals ("KAHK" is
    /// read "K A H K" - measured), with the stressed syllable said after it: "air-rah-nihk, stress on
    /// rah". Plain words are returned as they are.
    static func spoken(_ replacement: String) -> String {
        guard replacement.contains("`") else { return replacement }
        guard let r = respell(replacement) else { return "phonetic entry" }
        let stressed = r.split(whereSeparator: { $0 == "-" || $0 == " " })
            .first { $0.contains(where: \.isLetter) && $0 == $0.uppercased() && $0 != $0.lowercased() }
        return r.lowercased() + (stressed.map { ", stress on " + $0.lowercased() } ?? "")
    }

    /// Whether a replacement is (or contains) a phoneme code.
    static func isPhonetic(_ replacement: String) -> Bool { replacement.contains("`[") }

    /// The whole replacement respelled: plain words kept, each `[...] converted, other annotations
    /// (`1, `ts0 ...) dropped. nil if any code is malformed or holds a symbol not in the set.
    static func respell(_ replacement: String) -> String? {
        var words: [String] = []
        for token in replacement.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let t = String(token)
            if t.hasPrefix("`[") {
                guard t.hasSuffix("]"), let w = respellCode(String(t.dropFirst(2).dropLast())) else { return nil }
                words.append(w)
            } else if t.hasPrefix("`") {
                continue                                  // another annotation: not something said
            } else if t.contains("`") || t.contains("[") || t.contains("]") {
                return nil
            } else {
                words.append(t)
            }
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: - One code

    private static let vowels: Set<Character> = ["i", "I", "e", "E", "A", "a", "c", "o", "U", "u", "H", "x", "X", "R", "Y", "W", "O", "N", "M"]
    private static let consonants: [Character: String] = [
        "p": "p", "b": "b", "t": "t", "d": "d", "k": "k", "g": "g", "f": "f", "v": "v",
        "T": "th", "D": "th", "s": "s", "z": "z", "S": "sh", "Z": "zh", "h": "h",
        "m": "m", "n": "n", "G": "ng", "l": "l", "r": "r", "w": "w", "y": "y",
        "C": "ch", "J": "j", "F": "t", "?": "t",
    ]

    /// The body of one `[...]: ".2e.1ra.0nXk" -> "air-RAH-nihk". nil if malformed.
    static func respellCode(_ body: String) -> String? {
        // Syllables: "." then an optional stress digit, then phonemes up to the next ".".
        var syllables: [(stress: Int, phones: [Character])] = []
        var current: [Character]? = nil
        var stress = 0
        var chars = Array(body)
        if chars.first != "." { chars.insert(".", at: 0) }       // a code with no syllable marks at all
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                if let cur = current { syllables.append((stress, cur)) }
                current = []
                stress = 0
                if i + 1 < chars.count, let d = chars[i + 1].wholeNumberValue {
                    guard (0...2).contains(d) else { return nil }
                    stress = d
                    i += 1
                }
            } else if vowels.contains(c) || consonants[c] != nil {
                current?.append(c)
            } else {
                return nil
            }
            i += 1
        }
        if let cur = current { syllables.append((stress, cur)) }
        syllables.removeAll { $0.phones.isEmpty }
        // A syllable with no vowel (".0dw" in some entries) would be read letter by letter: its
        // consonants join the syllable before (or, for the first, the one after).
        var merged: [(stress: Int, phones: [Character])] = []
        var carry: [Character] = []
        for s in syllables {
            if !s.phones.contains(where: { vowels.contains($0) }) {
                if merged.isEmpty { carry += s.phones } else { merged[merged.count - 1].phones += s.phones }
            } else {
                merged.append((s.stress, carry + s.phones))
                carry = []
            }
        }
        guard !merged.isEmpty, carry.isEmpty else { return nil }
        syllables = merged

        // Only one syllable carries capitals: the first primary one (a code with no primary stress is
        // written all small).
        let primary = syllables.firstIndex { $0.stress == 1 }
        var out: [String] = []
        for (n, s) in syllables.enumerated() {
            let next = n + 1 < syllables.count ? syllables[n + 1].phones.first : nil
            guard let spelled = spell(s.phones, stressed: s.stress == 1, nextSyllableStart: next) else { return nil }
            out.append(n == primary ? spelled.uppercased() : spelled)
        }
        return out.joined(separator: "-")
    }

    /// The r-coloured spelling of a vowel followed by r, or nil when the vowel has none.
    private static func rColoured(_ v: Character) -> String? {
        switch v {
        case "a": return "ar"
        case "c", "o": return "or"
        case "e", "E": return "air"
        case "i", "I": return "eer"
        case "u", "U": return "oor"
        case "Y": return "ire"
        default: return nil
        }
    }

    /// A vowel's spelling. `onset`: something is written before it in this syllable; `coda`: the
    /// phonemes after it in this syllable. Each choice was checked by having the engine read it back
    /// (2026-09-24): "fow" is read "foe" but "fau" and "out" are right; "fyve" is read with a short i but
    /// "fighv" is right; "buuk" becomes "byoo-uk" but "ook" is right; "kyoo" is "kigh-oo" but "kew" is
    /// right; a lone "a" is the letter A.
    private static func vowelSpelling(_ v: Character, stressed: Bool, onset: Bool, coda: ArraySlice<Character>) -> String? {
        switch v {
        case "i": return "ee"
        case "I", "X": return "ih"
        case "e": return "ay"
        case "E": return "eh"
        case "A": return "a"
        case "a": return "ah"
        case "c": return "aw"
        case "o": return "oh"
        case "U": return coda.first == "k" ? "oo" : "oo"
        case "u": return "oo"
        case "H", "x": return "uh"
        case "R": return stressed ? "ur" : "er"
        case "Y": return onset ? "igh" : "eye"
        case "W": return !coda.isEmpty ? "ou" : (onset ? "au" : "ow")
        case "O": return "oy"
        case "N": return "uhn"
        case "M": return "uhm"
        default: return nil
        }
    }

    /// One syllable's phonemes, left to right. A vowel followed by r (in this syllable, or starting the
    /// next when the vowel ends this one) takes its r-coloured spelling; the r of this syllable is then
    /// not written again.
    private static func spell(_ p: [Character], stressed: Bool, nextSyllableStart: Character?) -> String? {
        var s = ""
        var k = 0
        while k < p.count {
            let c = p[k]
            if vowels.contains(c) {
                let followedByR = (k + 1 < p.count && p[k + 1] == "r")
                let endsBeforeR = (k + 1 == p.count && nextSyllableStart == "r")
                if (followedByR || endsBeforeR), let rc = rColoured(c) {
                    s += rc
                    k += followedByR ? 2 : 1
                    continue
                }
                // "yoo" after a consonant is read "kigh-oo": /ju/ there is "ew" ("kew", "fewt")
                if c == "u", k >= 2, p[k - 1] == "y", !vowels.contains(p[k - 2]), s.hasSuffix("y") {
                    s.removeLast()
                    s += "ew"
                    k += 1
                    continue
                }
                guard var v = vowelSpelling(c, stressed: stressed, onset: !s.isEmpty, coda: p[(k + 1)...]) else { return nil }
                // /ae/ ending a syllable: a lone "a" is the letter; borrow the next syllable's first
                // consonant ("at-tihk"), as a dictionary does
                if c == "A", k + 1 == p.count, let n = nextSyllableStart, let cons = consonants[n] {
                    v += cons
                }
                // /U/ before k is "ook" ("book"); elsewhere "oo" (nothing reads as /U/ on its own)
                s += v
            } else if let cons = consonants[c] {
                s += cons
            } else {
                return nil
            }
            k += 1
        }
        return s
    }
}
