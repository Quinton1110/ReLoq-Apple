//
//  Voices.swift
//  The voices this app registers with iOS. Shared by the app (preview) and the extension.
//
//  Eight voices, one per preset of the Eloquence-style engine (ReLoq C; before it, openevv). The engine numbers
//  its presets 1 to 8 - Adult Male 1, Adult Female 1, Child 1, Adult Male 2, Adult Male 3, Adult
//  Female 2, Elderly Female 1, Elderly Male 1 (include/eci.h) - and these are the names those eight
//  are known by in Apple's and NVDA's Eloquence: Reed, Shelley, Bobby, Rocko, Glen, Sandy, Grandma,
//  Grandpa, in that order. Of the eight, only "Reed = voice 1" is written down in the openevv tree
//  (docs/notes/apple-eloquence.md: "Apple's Reed preset -- which is voice 1"); the other seven follow
//  the same order. Confirm each against the real engine's eciGetVoiceName once it is dropped in.
//
//  Display names end with "(ReLoq)" (the engine's name; "(Eloquence)" until 2026-11-19, when the app
//  became ReLoq Apple): iOS ships Apple's own Eloquence voices under the bare names (Reed, Shelley, ...)
//  and two of the same name in VoiceOver's list would be indistinguishable.
//  Display names may change - SLUGS MAY NOT.
//
//  ⚠️ The slugs are part of the system voice identifiers VoiceOver stores. NEVER rename or reuse one.
//     (ClassicVoices discipline: identifier = prefix + "." + slug; iOS re-prefixes it with the
//     extension's bundle id, so match on the LAST dot component, never the whole string.)
//

import AVFoundation

/// A language the engine speaks (ev_bridge.h "LANGUAGES": ReLoq C's fourteen; Polish is listed for its
/// permanent slug and folder, from the openevv engine this app used before, and is filtered out).
struct EloquenceLanguage: Hashable, Identifiable, Sendable {
    let code: String            // the tag the slugs and folders use: "enus", "engb" ... (permanent)
    let bcp47: String           // what iOS files the voices under: "en-US", "en-GB" ...
    let eci: Int32              // the engine's language/dialect number
    let name: String            // shown in the app
    let slugSuffix: String      // "" for US English (its slugs predate the others and are permanent)
    /// The community dictionary file prefix for this language (ENUmain.dic ...), if any source may have files for it
    /// (eigencrow v26.11: ENU and DEU only; ENG is asked for in case a source ever publishes UK English).
    let communityPrefix: String?
    /// Other BCP-47 tags the voices are offered for besides `bcp47` (Chinese: ReLoq's one Mandarin
    /// module reads Simplified and Traditional text alike; its NVDA driver lists it once for both).
    var alsoFor: [String] = []
    /// The files to use when a source has none of this language's own (UK English: the US ones, which the bridge
    /// adapts for a UK voice - ev_bridge.h "UK ENGLISH AND THE US FILES").
    var communityFallbackPrefix: String? = nil
    var id: String { code }
}

/// Every language either engine has, in the order the app lists them. Codes and slug suffixes are
/// PERMANENT (they are inside VoiceOver's stored voice identifiers and the dictionary folders).
private let ALL_KNOWN_LANGUAGES: [EloquenceLanguage] = [
    EloquenceLanguage(code: "enus", bcp47: "en-US", eci: 0x10000, name: "English (United States)", slugSuffix: "", communityPrefix: "ENU"),
    EloquenceLanguage(code: "engb", bcp47: "en-GB", eci: 0x10001, name: "English (United Kingdom)", slugSuffix: "_engb", communityPrefix: "ENG",
                      communityFallbackPrefix: "ENU"),
    EloquenceLanguage(code: "eses", bcp47: "es-ES", eci: 0x20000, name: "Spanish (Spain)", slugSuffix: "_eses", communityPrefix: nil),
    EloquenceLanguage(code: "esus", bcp47: "es-MX", eci: 0x20001, name: "Spanish (Latin America)", slugSuffix: "_esus", communityPrefix: nil),
    EloquenceLanguage(code: "frfr", bcp47: "fr-FR", eci: 0x30000, name: "French (France)", slugSuffix: "_frfr", communityPrefix: nil),
    EloquenceLanguage(code: "frca", bcp47: "fr-CA", eci: 0x30001, name: "French (Canada)", slugSuffix: "_frca", communityPrefix: nil),
    EloquenceLanguage(code: "dede", bcp47: "de-DE", eci: 0x40000, name: "German", slugSuffix: "_dede", communityPrefix: "DEU"),
    EloquenceLanguage(code: "itit", bcp47: "it-IT", eci: 0x50000, name: "Italian", slugSuffix: "_itit", communityPrefix: nil),
    EloquenceLanguage(code: "ptbr", bcp47: "pt-BR", eci: 0x70000, name: "Portuguese (Brazil)", slugSuffix: "_ptbr", communityPrefix: nil),
    EloquenceLanguage(code: "fifi", bcp47: "fi-FI", eci: 0x90000, name: "Finnish", slugSuffix: "_fifi", communityPrefix: nil),
    EloquenceLanguage(code: "elgr", bcp47: "el-GR", eci: 0x120000, name: "Greek", slugSuffix: "_elgr", communityPrefix: nil),
    EloquenceLanguage(code: "plpl", bcp47: "pl-PL", eci: 0x110000, name: "Polish", slugSuffix: "_plpl", communityPrefix: nil),
    EloquenceLanguage(code: "zhcn", bcp47: "zh-CN", eci: 0x60000, name: "Chinese (Mandarin)", slugSuffix: "_zhcn", communityPrefix: nil,
                      alsoFor: ["zh-TW"]),
    EloquenceLanguage(code: "jajp", bcp47: "ja-JP", eci: 0x80000, name: "Japanese", slugSuffix: "_jajp", communityPrefix: nil),
    EloquenceLanguage(code: "kokr", bcp47: "ko-KR", eci: 0xa0000, name: "Korean", slugSuffix: "_kokr", communityPrefix: nil),
]

/// The languages THIS build's engine speaks (ev_lang_index): ReLoq C has no Polish. A voice of a language the engine lacks is simply not
/// offered (its saved settings and dictionary folder stay where they are).
let ELOQUENCE_LANGUAGES: [EloquenceLanguage] = ALL_KNOWN_LANGUAGES.filter { ev_lang_index($0.eci) >= 0 }

let ELOQUENCE_US_ENGLISH = ELOQUENCE_LANGUAGES[0]

struct EloquenceVoiceDef: Hashable {
    let slug: String        // stable identifier suffix - permanent
    let display: String     // shown in VoiceOver's voice list and in the app
    let preset: Int32       // the engine's own voice number, 1...8 (eciCopyVoice(h, preset, 0))
    let female: Bool
    let child: Bool
    /// Stub only: the tone the placeholder engine hums for this voice, in hertz, so the eight are
    /// distinguishable by ear before the real engine arrives. Ignored once ELOQUENCE_ENGINE is on.
    let stubHz: Double
    var language: EloquenceLanguage = ELOQUENCE_US_ENGLISH

    var identifier: String { ELOQUENCE_VOICE_ID_PREFIX + "." + slug }
    var gender: AVSpeechSynthesisVoiceGender { female ? .female : .male }
}

let ELOQUENCE_VOICE_ID_PREFIX = "com.quinton.eloquencevoices"

/// In the engine's own preset order (voice 1 first). Slugs are permanent.
let ELOQUENCE_VOICES: [EloquenceVoiceDef] = [
    EloquenceVoiceDef(slug: "reed",    display: "Reed (ReLoq)",    preset: 1, female: false, child: false, stubHz: 130),
    EloquenceVoiceDef(slug: "shelley", display: "Shelley (ReLoq)", preset: 2, female: true,  child: false, stubHz: 210),
    EloquenceVoiceDef(slug: "bobby",   display: "Bobby (ReLoq)",   preset: 3, female: false, child: true,  stubHz: 260),
    EloquenceVoiceDef(slug: "rocko",   display: "Rocko (ReLoq)",   preset: 4, female: false, child: false, stubHz: 110),
    EloquenceVoiceDef(slug: "glen",    display: "Glen (ReLoq)",    preset: 5, female: false, child: false, stubHz: 150),
    EloquenceVoiceDef(slug: "sandy",   display: "Sandy (ReLoq)",   preset: 6, female: true,  child: false, stubHz: 240),
    EloquenceVoiceDef(slug: "grandma", display: "Grandma (ReLoq)", preset: 7, female: true,  child: false, stubHz: 190),
    EloquenceVoiceDef(slug: "grandpa", display: "Grandpa (ReLoq)", preset: 8, female: false, child: false, stubHz: 120),
]

/// Every voice of every language: the eight presets in each, slug = the English slug + the language's
/// suffix ("reed_engb"; US English keeps the bare slugs it shipped with). No dots in a slug: iOS matches on
/// the last dot component.
let ALL_ELOQUENCE_VOICES: [EloquenceVoiceDef] = ELOQUENCE_LANGUAGES.flatMap { lang in
    ELOQUENCE_VOICES.map { v in
        EloquenceVoiceDef(slug: v.slug + lang.slugSuffix, display: v.display, preset: v.preset, female: v.female,
                          child: v.child, stubHz: v.stubHz, language: lang)
    }
}

enum VoiceCatalog {
    static func voices(for lang: EloquenceLanguage) -> [EloquenceVoiceDef] {
        ALL_ELOQUENCE_VOICES.filter { $0.language == lang }
    }

    /// iOS hands the extension identifiers re-prefixed with the extension's bundle id
    /// (com.quinton.eloquencevoices.Extension.com.quinton.eloquencevoices.reed), so only the slug
    /// at the end is stable enough to match on.
    static func def(forIdentifier id: String) -> EloquenceVoiceDef {
        let slug = id.split(separator: ".").last.map(String.init) ?? ""
        return ALL_ELOQUENCE_VOICES.first(where: { $0.slug == slug }) ?? ELOQUENCE_VOICES[0]
    }

    /// "Reed", "Grandma" ... for the sample sentence.
    static func shortName(_ def: EloquenceVoiceDef) -> String {
        def.display.replacingOccurrences(of: " (ReLoq)", with: "")
    }
}
