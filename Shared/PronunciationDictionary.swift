//
//  PronunciationDictionary.swift
//  The community pronunciation dictionary, OPT-IN (off by default): IBMTTSDictionaries by eigencrow
//  and contributors, github.com/eigencrow/IBMTTSDictionaries, licence CC0-1.0 (public domain). Three
//  files per release - ENUmain.dic (whole words), ENURoot.dic (word roots, which also cover their
//  inflections: "iphone" fixes "iPhones"), ENUabbr.dic (abbreviations) - Windows-1252 text, one
//  "key TAB replacement" per line. Nothing is bundled: the app downloads a release into the app-group
//  container (Library/Dictionaries/<folder>/) and both processes read it from there.
//
//  Shared by both targets: the settings (in the app-group defaults, like the voice settings) and
//  `configureEngine()`, which each process calls before speaking so the bridge loads the files when
//  the switch is on and drops them when it is off (ev_bridge.h "THE COMMUNITY PRONUNCIATION
//  DICTIONARY" says how, and why the root file is handed over word by word).
//
//  NOT used, deliberately: github.com/Mohamed00/AltIBMTTSDictionaries, an alternative set that carries
//  no licence at all.
//

import Foundation

enum PronunciationDictionary {
    static let owner = "eigencrow"
    static let repo = "IBMTTSDictionaries"
    static let mainFile = "ENUmain.dic"
    static let rootFile = "ENURoot.dic"
    static let abbrFile = "ENUabbr.dic"
    /// The US English files: a release is installed when these are there (the other languages' files are
    /// optional - v26.09 has German too, nothing else).
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

    /// The installed release's folder, if there is one and its US English files are there.
    static func installedFolder(_ store: VoiceSettingsStore = .shared) -> URL? {
        guard let name = store.dictionaryFolder, !name.isEmpty, let base = baseURL else { return nil }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        for f in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) { return nil }
        return dir
    }

    /// The installed release's three files for one language, or nil when it has none.
    static func installedFiles(for lang: EloquenceLanguage, _ store: VoiceSettingsStore = .shared) -> [URL]? {
        guard let dir = installedFolder(store) else { return nil }
        let names = files(for: lang)
        guard names.count == 3 else { return nil }
        let urls = names.map { dir.appendingPathComponent($0) }
        for u in urls where !FileManager.default.fileExists(atPath: u.path) { return nil }
        return urls
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
        return zip(DictionaryKind.allCases, urls).flatMap { DictionaryFile.load($1, kind: $0) }
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
            ev_dict_configure_lang(lang.eci, u[0].path, u[1].path, u[2].path)
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
                ev_dict_configure_lang(lang.eci, u[0].path, u[1].path, u[2].path)
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
}
