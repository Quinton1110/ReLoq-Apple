//
//  PronunciationDictionary.swift
//  The community pronunciation dictionary, OPT-IN (off by default), from ONE source at a time
//  (Shared/DictionarySource.swift, "Dictionary source"): by default IBMTTSDictionaries by eigencrow and
//  contributors, github.com/eigencrow/IBMTTSDictionaries, licence CC0-1.0 (public domain). Up to three
//  files per language - ENUmain.dic (whole words), ENURoot.dic (word roots, which also cover their
//  inflections: "iphone" fixes "iPhones"), ENUabbr.dic (abbreviations) - Windows-1252 text, one
//  "key TAB replacement" per line. Nothing is bundled: the app downloads a release into the app-group
//  container (Library/Dictionaries/<folder>/, always under those names) and both processes read it from there.
//
//  Shared by both targets: the settings (in the app-group defaults, like the voice settings) and
//  `configureEngine()`, which each process calls before speaking so the bridge loads the files when
//  the switch is on and drops them when it is off (ev_bridge.h "THE COMMUNITY PRONUNCIATION
//  DICTIONARY" says how, and why the root file is handed over word by word).
//
//  Also offered, as an opt-in source the user picks and downloads from GitHub on their own device:
//  github.com/Mohamed00/AltIBMTTSDictionaries. It carries no licence at all, so it is NEVER bundled with the
//  app or hosted anywhere by us; nothing is fetched from it unless the user chooses it. Or any GitHub
//  repository the user links to ("Custom").
//

import Foundation

enum PronunciationDictionary {
    static let mainFile = "ENUmain.dic"
    static let rootFile = "ENURoot.dic"
    static let abbrFile = "ENUabbr.dic"
    /// The US English files, as installed: a set is installed when at least one of these is there (a source need
    /// not publish all three - AltIBMTTSDictionaries has no abbreviations; the other languages are optional).
    static let files = [mainFile, rootFile, abbrFile]

    /// Every language the project publishes files for, and the three names of each.
    static var communityLanguages: [EloquenceLanguage] { ELOQUENCE_LANGUAGES.filter { $0.communityPrefix != nil } }
    static func files(for lang: EloquenceLanguage) -> [String] {
        guard let p = lang.communityPrefix else { return [] }
        return DictionaryKind.allCases.map { $0.communityFile(prefix: p) }
    }

    /// <app group>/Library/Dictionaries - nil when the group container cannot be opened.
    static var baseURL: URL? {
        AppGroup.containerURL.map(DictionaryLocations.community(in:))
    }

    /// The installed release's folder, if there is one, it came from the source now chosen, and it has at least
    /// one US English file. A set from another source is not used: one source at a time, and a switch that has
    /// not finished downloading leaves no community dictionary in force rather than the old one.
    static func installedFolder(_ store: VoiceSettingsStore = .shared) -> URL? {
        guard let name = store.dictionaryFolder, !name.isEmpty, let base = baseURL else { return nil }
        return DictionaryCopies.folderInForce(base: base, folder: name,
                                              installedSource: store.installedDictionarySource,
                                              chosen: store.dictionarySource?.id, files: files)
    }

    /// The installed release's files for one language, [main, root, abbr] with nil for a kind it does not have;
    /// nil when it has none of them. A language with a fallback (UK English) uses its own files when the release has
    /// any, and otherwise the fallback language's (the US ones, which the bridge adapts for it).
    static func installedFiles(for lang: EloquenceLanguage, _ store: VoiceSettingsStore = .shared) -> [URL?]? {
        guard let dir = installedFolder(store) else { return nil }
        for prefix in [lang.communityPrefix, lang.communityFallbackPrefix].compactMap({ $0 }) {
            let urls: [URL?] = DictionaryKind.allCases.map { kind in
                let u = dir.appendingPathComponent(kind.communityFile(prefix: prefix))
                return FileManager.default.fileExists(atPath: u.path) ? u : nil
            }
            if urls.contains(where: { $0 != nil }) { return urls }
        }
        return nil
    }

    /// A community entry's reading as the language's voices get it (the bridge's rule, ev_dict_adapt_value): UK English
    /// leaves out a US entry its engine cannot say and turns an unstressed R into a schwa; every other language takes it
    /// as it is. nil = left out.
    static func adapted(_ replacement: String, for lang: EloquenceLanguage) -> String? {
        guard lang.communityFallbackPrefix != nil else { return replacement }
        var out = [CChar](repeating: 0, count: replacement.utf8.count + 1)
        let r = replacement.withCString { ev_dict_adapt_value(lang.eci, $0, &out, Int32(out.count)) }
        switch r {
        case 1: return String(cString: out)
        case 0: return nil
        default: return replacement
        }
    }

    /// The user's own entries of one language (UserDictionary.swift; US English in
    /// <group>/Library/UserDictionary as it always was, the others beside it). Never under
    /// Library/Dictionaries, whose folders the updater replaces and cleans up.
    static func userDirectoryURL(for lang: EloquenceLanguage = ELOQUENCE_US_ENGLISH) -> URL? {
        AppGroup.containerURL.map { DictionaryLocations.user(in: $0, language: lang.code) }
    }

    static func userStore(for lang: EloquenceLanguage = ELOQUENCE_US_ENGLISH) -> UserDictionaryStore? {
        userDirectoryURL(for: lang).map { UserDictionaryStore(directory: $0) }
    }

    /// US English's (kept for the callers that predate languages).
    static var userStore: UserDictionaryStore? { userStore(for: ELOQUENCE_US_ENGLISH) }

    /// Every entry of the installed community release for one language, one per key (empty when there is
    /// none). US English is about 70,000 lines: call it off the main thread.
    static func communityEntries(for lang: EloquenceLanguage = ELOQUENCE_US_ENGLISH,
                                 _ store: VoiceSettingsStore = .shared) -> [DictionaryEntry] {
        guard let urls = installedFiles(for: lang, store) else { return [] }
        let all = zip(DictionaryKind.allCases, urls).flatMap { kind, url in url.map { DictionaryFile.load($0, kind: kind) } ?? [] }
        guard lang.communityFallbackPrefix != nil else { return all }
        // as the voices get them (UK English: the US entries, adapted)
        return all.compactMap { e in adapted(e.replacement, for: lang).map { var a = e; a.replacement = $0; return a } }
    }

    /// For a preview in the app process only: one language's community files on or off regardless of the
    /// switch, and the user's entries from `userPaths` (three paths, "" for none). configureEngine() puts
    /// the real configuration back.
    static func configureEngineForPreview(language lang: EloquenceLanguage = ELOQUENCE_US_ENGLISH, community: Bool,
                                          userPaths: [String], _ store: VoiceSettingsStore = .shared) {
        ev_set_voice_tags(store.voiceTagsEnabled ? 1 : 0)
        ev_set_phrase_prediction(store.phrasePredictionEnabled ? 1 : 0)
        store.applyTone()
        store.applyPauses()
        ev_dict_set_listen(lang.eci, nil, 0)
        if userPaths.count == 3 { ev_dict_configure_user_lang(lang.eci, userPaths[0], userPaths[1], userPaths[2]) }
        else { ev_dict_configure_user_lang(lang.eci, nil, nil, nil) }
        if community, let u = installedFiles(for: lang, store) {
            ev_dict_configure_lang(lang.eci, u[0]?.path, u[1]?.path, u[2]?.path)
        } else {
            ev_dict_configure_lang(lang.eci, nil, nil, nil)
        }
    }

    /// Tells the bridge what to load for one language (nil = every language): the user's own entries
    /// whenever there are any (whatever the switch says - they are the user's own list), and the
    /// language's community files when the switch is on and the installed release has them. Cheap to call
    /// before every request (the bridge acts only on a change, and re-reads a user file only when it
    /// changed). Also hands the bridge the "Enable backquote voice tags" and "Phrase prediction" switches, the tone
    /// controls (equalizer, treble, Mellow) and "Shorten pauses", and - given the request's
    /// text - applies a Listen marker the dictionary editor left (ListenMarker below). Returns whether a
    /// COMMUNITY dictionary is configured for the language (US English for nil).
    @discardableResult
    static func configureEngine(language: EloquenceLanguage? = nil, requestText: String? = nil,
                                _ store: VoiceSettingsStore = .shared) -> Bool {
        ev_set_voice_tags(store.voiceTagsEnabled ? 1 : 0)
        ev_set_phrase_prediction(store.phrasePredictionEnabled ? 1 : 0)
        store.applyTone()
        store.applyPauses()
        var configured = false
        for lang in language.map({ [$0] }) ?? ELOQUENCE_LANGUAGES {
            if let paths = userStore(for: lang)?.bridgePaths, paths.count == 3 {
                ev_dict_configure_user_lang(lang.eci, paths[0], paths[1], paths[2])
            } else {
                ev_dict_configure_user_lang(lang.eci, nil, nil, nil)
            }
            if store.dictionaryEnabled, let u = installedFiles(for: lang, store) {
                ev_dict_configure_lang(lang.eci, u[0]?.path, u[1]?.path, u[2]?.path)
                if lang == (language ?? ELOQUENCE_US_ENGLISH) { configured = true }
            } else {
                ev_dict_configure_lang(lang.eci, nil, nil, nil)
            }
            if let m = ListenMarker.take(language: lang, requestText: requestText, store) {
                ev_dict_set_listen(lang.eci, m.word, m.communityOff ? 1 : 0)
            } else {
                ev_dict_set_listen(lang.eci, nil, 0)
            }
        }
        return configured
    }
}

extension ListenMarker {
    static func post(_ m: ListenMarker, _ store: VoiceSettingsStore = .shared) {
        if let d = try? JSONEncoder().encode(m) { store.groupDefaults.set(d, forKey: key) }
    }

    /// The marker to apply to this request, if any (and marks it used).
    static func take(language lang: EloquenceLanguage, requestText: String?, _ store: VoiceSettingsStore = .shared,
                     now: Date = Date()) -> ListenMarker? {
        guard let text = requestText,
              let d = store.groupDefaults.data(forKey: key),
              let m = try? JSONDecoder().decode(ListenMarker.self, from: d) else { return nil }
        return take(m, language: lang.code, requestText: text, now: now)
    }
}

// MARK: - Settings (app-group defaults; the app writes, the extension reads)

extension VoiceSettingsStore {
    private enum DictKey {
        static let enabled = "dict.enabled"
        static let autoUpdate = "dict.autoUpdate"
        static let folder = "dict.folder"
        static let tag = "dict.tag"
        static let published = "dict.published"
        static let lastCheck = "dict.lastCheck"
        static let counts = "dict.counts"
        static let frequency = "dict.frequency"
        static let source = "dict.source"
        static let customSource = "dict.customSource"
        static let installedSource = "dict.installedSource"
        static let layout = "dict.layout"
        static let voiceTags = "engine.voiceTags"
        static let phrasePrediction = "engine.phrasePrediction"
    }

    /// Entry counts of another language's installed files: [main, root, abbr], empty when none.
    func dictionaryCounts(for lang: EloquenceLanguage) -> [Int] {
        lang == ELOQUENCE_US_ENGLISH ? dictionaryCounts
            : (groupDefaults.array(forKey: "dict.counts." + lang.code) as? [Int] ?? [])
    }

    func setDictionaryCounts(_ c: [Int], for lang: EloquenceLanguage) {
        if lang == ELOQUENCE_US_ENGLISH { dictionaryCounts = c } else { groupDefaults.set(c, forKey: "dict.counts." + lang.code) }
    }

    /// How often "Update automatically" checks: Daily, Weekly or Monthly (default Monthly).
    var dictionaryUpdateFrequency: DictionaryUpdateFrequency {
        get { DictionaryUpdateFrequency(stored: groupDefaults.string(forKey: DictKey.frequency)) }
        set { groupDefaults.set(newValue.rawValue, forKey: DictKey.frequency) }
    }

    /// "Enable backquote voice tags" - OFF by default, as in NVDA's IBMTTS driver (ev_bridge.h).
    var voiceTagsEnabled: Bool {
        get { groupDefaults.bool(forKey: DictKey.voiceTags) }
        set { groupDefaults.set(newValue, forKey: DictKey.voiceTags) }
    }

    /// "Phrase prediction" - ON by default (the engine's own default; unset = on), ev_bridge.h.
    var phrasePredictionEnabled: Bool {
        get { groupDefaults.object(forKey: DictKey.phrasePrediction) as? Bool ?? true }
        set { groupDefaults.set(newValue, forKey: DictKey.phrasePrediction) }
    }

    /// "Dictionary source": which repository (DictionarySourceChoice; unset = IBMTTSDictionaries by eigencrow).
    var dictionarySourceChoice: DictionarySourceChoice {
        get { DictionarySourceChoice(stored: groupDefaults.string(forKey: DictKey.source)) }
        set {
            if newValue == .eigencrow { groupDefaults.removeObject(forKey: DictKey.source) }
            else { groupDefaults.set(newValue.rawValue, forKey: DictKey.source) }
        }
    }

    /// The Custom source's link as the user gave it ("" when none).
    var dictionaryCustomLink: String {
        get { groupDefaults.string(forKey: DictKey.customSource) ?? "" }
        set { groupDefaults.set(newValue, forKey: DictKey.customSource) }
    }

    /// The repository chosen now; nil for Custom without a valid link.
    var dictionarySource: DictionarySource? {
        dictionarySourceChoice.source(custom: dictionaryCustomLink)
    }

    /// "owner/repo" of the installed set. A set installed before sources existed has none recorded: it is
    /// eigencrow's, which is all the app could download then.
    var installedDictionarySource: String {
        get { groupDefaults.string(forKey: DictKey.installedSource) ?? DictionarySource.eigencrow.id }
        set { groupDefaults.set(newValue, forKey: DictKey.installedSource) }
    }

    /// "Use community dictionary" - OFF by default.
    var dictionaryEnabled: Bool {
        get { groupDefaults.bool(forKey: DictKey.enabled) }
        set { groupDefaults.set(newValue, forKey: DictKey.enabled) }
    }

    /// "Update automatically" - OFF by default.
    var dictionaryAutoUpdate: Bool {
        get { groupDefaults.bool(forKey: DictKey.autoUpdate) }
        set { groupDefaults.set(newValue, forKey: DictKey.autoUpdate) }
    }

    /// Folder name under Library/Dictionaries of the release in use.
    var dictionaryFolder: String? {
        get { groupDefaults.string(forKey: DictKey.folder) }
        set { groupDefaults.set(newValue, forKey: DictKey.folder) }
    }

    /// The installed release's tag ("v26.09") and GitHub publication date.
    var dictionaryTag: String? {
        get { groupDefaults.string(forKey: DictKey.tag) }
        set { groupDefaults.set(newValue, forKey: DictKey.tag) }
    }

    var dictionaryPublished: Date? {
        get { groupDefaults.object(forKey: DictKey.published) as? Date }
        set { groupDefaults.set(newValue, forKey: DictKey.published) }
    }

    /// When the app last asked GitHub for the latest release (auto-update checks at most about daily).
    var dictionaryLastCheck: Date? {
        get { groupDefaults.object(forKey: DictKey.lastCheck) as? Date }
        set { groupDefaults.set(newValue, forKey: DictKey.lastCheck) }
    }

    /// Entry counts of the installed files as the bridge parses them: [main, root, abbr].
    var dictionaryCounts: [Int] {
        get { groupDefaults.array(forKey: DictKey.counts) as? [Int] ?? [] }
        set { groupDefaults.set(newValue, forKey: DictKey.counts) }
    }

    /// The installed copy's file layout (2 since 2026-09-24: every language's files, not only US English's).
    var dictionaryLayout: Int {
        get { groupDefaults.integer(forKey: DictKey.layout) }
        set { groupDefaults.set(newValue, forKey: DictKey.layout) }
    }
}

/// What DictionaryCopies (Shared/DictionaryCopies.swift) reads and writes when a copy becomes the one in force: the same
/// keys as always, so the extension reads them as it always has.
extension VoiceSettingsStore: DictionaryActiveState {
    var communityCounts: [String: [Int]] {
        get {
            var out: [String: [Int]] = [:]
            for lang in PronunciationDictionary.communityLanguages where !dictionaryCounts(for: lang).isEmpty {
                out[lang.code] = dictionaryCounts(for: lang)
            }
            return out
        }
        set {
            for lang in PronunciationDictionary.communityLanguages { setDictionaryCounts(newValue[lang.code] ?? [], for: lang) }
        }
    }
}
