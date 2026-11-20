//
//  DictionaryUpdater.swift
//  Downloads, validates and installs the community pronunciation dictionary (see
//  Shared/PronunciationDictionary.swift) into the app-group container, and keeps it up to date when the
//  user asks it to. App only: the extension just reads what is installed.
//
//  - From the source chosen under "Dictionary source" (Shared/DictionarySource.swift): its latest release
//    (api.github.com/repos/<owner>/<repo>/releases/latest -> tag_name, published_at; with no release, the
//    default branch's latest commit), the .dic files found at that tag in any folder and any case
//    (DictionaryLayout), downloaded from raw.githubusercontent.com and installed under the app's own names.
//    Switching the source downloads the new one's latest release; until that is in, no community set is in
//    force (one source at a time). The user's own entries are untouched by all of this.
//  - A download goes into a fresh folder of its own. It is validated (every file non-empty and parsed by
//    the bridge into entries) BEFORE the settings are pointed at it, so the
//    previous copy stays in use until the new one is complete; a failed or partial download is deleted
//    and the old copy is untouched. Folders no longer in use are removed at the next launch, not at the
//    moment of switching, so the extension is never reading a file that has just been deleted.
//  - Auto-update (off by default): Daily, Weekly or Monthly as the user chooses (default Monthly,
//    Shared/DictionarySchedule.swift decides), checked when the app launches or comes forward.
//

import Foundation

@MainActor
final class DictionaryUpdater: ObservableObject {
    static let shared = DictionaryUpdater()

    @Published private(set) var isBusy = false
    /// One plain sentence about the last thing that happened (VoiceOver reads it as it is).
    @Published private(set) var status = ""
    @Published private(set) var installedTag: String?
    @Published private(set) var installedPublished: Date?
    @Published private(set) var counts: [Int] = []

    private let store = VoiceSettingsStore.shared

    private init() { refreshInstalled() }

    // MARK: - What the UI shows

    func refreshInstalled() {
        if PronunciationDictionary.installedFolder(store) != nil {
            installedTag = store.dictionaryTag
            installedPublished = store.dictionaryPublished
            counts = store.dictionaryCounts
        } else {
            installedTag = nil
            installedPublished = nil
            counts = []
        }
    }

    /// Short on purpose: "Version 26.09, September 3." - the year only when it
    /// is not the current one, no entry counts.
    var installedDescription: String {
        guard let tag = installedTag else { return "Not downloaded." }
        var s = "Version \(Self.versionText(tag))"
        if let d = installedPublished { s += ", \(Self.dateText(d))" }
        return s + "."
    }

    /// A release tag as the main screen shows it: "v26.09" -> "26.09".
    static func versionText(_ tag: String) -> String {
        var version = tag
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        return version
    }

    static func dateText(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdy")
        return f.string(from: d)
    }

    // MARK: - Actions

    /// The "Use community dictionary" switch. Turning it on with nothing installed from the chosen source
    /// downloads that source's latest.
    func setEnabled(_ on: Bool) {
        store.dictionaryEnabled = on
        if on && installedTag == nil && store.dictionarySource != nil {
            Task { await update(reason: .enable) }
        } else {
            status = ""      // the switch itself says on / off; a status line saying it again is noise
        }
    }

    func setAutoUpdate(_ on: Bool) {
        store.dictionaryAutoUpdate = on
        if on { Task { await checkIfDue() } }
    }

    /// The Daily / Weekly / Monthly picker. A shorter period may make a check due at once.
    func setFrequency(_ f: DictionaryUpdateFrequency) {
        store.dictionaryUpdateFrequency = f
        Task { await checkIfDue() }
    }

    /// The "Dictionary source" picker. A different source is downloaded at once when the dictionary is on (else
    /// when it is switched on); Custom waits for a link.
    func setSource(_ choice: DictionarySourceChoice) {
        store.dictionarySourceChoice = choice
        refreshInstalled()
        status = ""
        if store.dictionaryEnabled, store.dictionarySource != nil, installedTag == nil {
            Task { await update(reason: .source) }
        }
    }

    /// The Custom link, given with "Use this link" or Return. Says so when it is not a GitHub repository.
    func setCustomLink(_ text: String) {
        guard let source = DictionarySource.parse(text) else {
            status = Self.describe(DictionarySourceError.notALink)
            return
        }
        store.dictionaryCustomLink = source.id
        store.dictionarySourceChoice = .custom
        refreshInstalled()
        status = ""
        Task { await update(reason: .source) }      // a link given is a request to fetch it, on or off
    }

    /// "Update now".
    func updateNow() {
        Task { await update(reason: .manual) }
    }

    /// App launch / coming forward: remove folders no longer used; if auto-update is on and the last
    /// check was long enough ago, check for a newer release.
    func appBecameActive() {
        removeUnusedFolders()
        refreshInstalled()
        Task { await checkIfDue() }
    }

    /// Development only (SelfTest -evDictSelfTest): an "Update now" that can be awaited.
    func updateForSelfTest() async -> String {
        await update(reason: .manual)
        return status
    }

    private func checkIfDue() async {
        guard !isBusy,
              DictionarySchedule.isDue(enabled: store.dictionaryEnabled, autoUpdate: store.dictionaryAutoUpdate,
                                       frequency: store.dictionaryUpdateFrequency,
                                       lastCheck: store.dictionaryLastCheck, now: Date()) else { return }
        await update(reason: .automatic)
    }

    enum Reason { case manual, enable, automatic, source }

    private func update(reason: Reason) async {
        guard !isBusy else { return }
        guard let source = store.dictionarySource else {
            if reason == .manual { status = "Enter a GitHub link." }
            return
        }
        isBusy = true
        defer {
            isBusy = false
            // The source was changed while this one was downloading: fetch the one now chosen.
            if let now = store.dictionarySource, now != source, store.dictionaryEnabled {
                Task { await update(reason: .source) }
            }
        }
        status = "Checking..."
        do {
            let snap = try await fetcher.latest(source)
            store.dictionaryLastCheck = Date()
            // Layout 2 (2026-09-24) also carries the other languages' files: an install from before is
            // fetched again once, even at the same tag, so German arrives without waiting for a release.
            if snap.version == store.dictionaryTag, PronunciationDictionary.installedFolder(store) != nil,
               store.groupDefaults.integer(forKey: "dict.layout") >= 2 {
                status = "Up to date."
                return
            }
            status = "Downloading \(Self.versionText(snap.version))..."
            _ = try await install(snap)
            refreshInstalled()
            status = "Updated to \(Self.versionText(snap.version))."
                + (store.dictionaryEnabled ? "" : " Dictionary is off.")
        } catch {
            let why = Self.describe(error)
            if store.dictionaryTag != nil, PronunciationDictionary.installedFolder(store) != nil {
                status = "Couldn't update: \(why)"
            } else {
                status = "Couldn't download: \(why)"
            }
        }
    }

    // MARK: - Network

    static func describe(_ error: Error) -> String {
        if let e = error as? DictionarySourceError {
            switch e {
            case .badResponse(let code): return "GitHub error \(code)."
            case .noRepository: return "that repository wasn't found."
            case .noFiles: return "no dictionary files found in that release."
            case .emptyFile(let f): return "\(f) came back empty."
            case .doesNotParse(let f): return "\(f) is not a valid dictionary."
            case .noContainer: return "storage unavailable."
            case .notALink: return "That isn't a GitHub repository link."
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "no internet connection."
            case .timedOut: return "the connection timed out."
            default: return "a network error (\(u.code.rawValue))."
            }
        }
        return "an unexpected error."
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 180
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private var fetcher: DictionaryFetcher { DictionaryFetcher(session: session, userAgent: "ReLoq-Apple") }

    /// Downloads the snapshot's files into a new folder, validates them (each parses into entries), then points
    /// the settings at it. Returns the US English entry counts [main, root, abbr] (0 = that kind not published).
    private func install(_ snap: DictionarySnapshot) async throws -> [Int] {
        guard let base = PronunciationDictionary.baseURL else { throw DictionarySourceError.noContainer }
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTag = String(snap.version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }.prefix(24))
        let folder = "\(safeTag.isEmpty ? "release" : safeTag)-\(Int(Date().timeIntervalSince1970))"
        let incoming = base.appendingPathComponent(".incoming-" + folder, isDirectory: true)
        try? fm.removeItem(at: incoming)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            let langs = [ELOQUENCE_US_ENGLISH] + PronunciationDictionary.communityLanguages.filter { $0 != ELOQUENCE_US_ENGLISH }
            let prefixes = langs.compactMap { $0.communityPrefix?.uppercased() }
            let got = try await fetcher.download(snap, prefixes: prefixes, into: incoming,
                                                 count: { Int(ev_dict_count_entries($0.path)) })
            let final = base.appendingPathComponent(folder, isDirectory: true)
            try fm.moveItem(at: incoming, to: final)
            // Only now does anything point at the new copy.
            store.dictionaryFolder = folder
            store.installedDictionarySource = snap.source.id
            store.dictionaryTag = snap.version
            store.dictionaryPublished = snap.published
            store.groupDefaults.set(2, forKey: "dict.layout")
            for lang in langs {
                store.setDictionaryCounts(lang.communityPrefix.flatMap { got[$0.uppercased()] } ?? [], for: lang)
            }
            return store.dictionaryCounts
        } catch {
            try? fm.removeItem(at: incoming)
            throw error
        }
    }

    /// Everything under Library/Dictionaries except the folder in use (and a download in progress).
    private func removeUnusedFolders() {
        guard !isBusy, let base = PronunciationDictionary.baseURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        let keep = store.dictionaryFolder
        for n in names where n != keep {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(n))
        }
    }
}
