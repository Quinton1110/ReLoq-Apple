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
//    Each source keeps its own downloaded copy (Shared/DictionaryCopies.swift): switching to a source already
//    downloaded uses its copy at once, with no download; switching to one not downloaded yet downloads its latest
//    release, and until that is in no community set is in force (one source at a time). The copies not in use are
//    listed under "Downloaded dictionaries", each with a Remove button. The user's own entries are untouched by all
//    of this.
//  - A download goes into a fresh folder of its own. It is validated (every file non-empty and parsed by
//    the bridge into entries) BEFORE the settings are pointed at it, so the
//    previous copy stays in use until the new one is complete; a failed or partial download is deleted
//    and the old copy is untouched. An update replaces only that source's older copy, which is removed at the
//    next launch or return to the app, not at the moment of switching, so the extension is never reading a file
//    that has just been deleted.
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
    /// "Downloaded dictionaries": the copies on disk not in use (DictionaryCopies.listed).
    @Published private(set) var downloaded: [DownloadedDictionary] = []
    /// Development only (SelfTest -evDictCopiesSelfTest): how many times GitHub was asked for a release.
    private(set) var checks = 0

    private let store = VoiceSettingsStore.shared

    private init() { refreshInstalled() }

    // MARK: - What the UI shows

    /// Also: gives a copy from before sidecars its sidecar, and when nothing is in force for the chosen source but a
    /// copy of it is on disk, makes that copy the one in force (a switch back to a source downloaded before).
    func refreshInstalled() {
        if let base = PronunciationDictionary.baseURL {
            DictionaryCopies.migrate(base: base, state: store)
            DictionaryCopies.activateKeptCopy(chosen: store.dictionarySource?.id, base: base, state: store,
                                              files: PronunciationDictionary.files)
        }
        refreshDownloaded()
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
    static func versionText(_ tag: String) -> String { DictionaryCopies.versionText(tag) }

    private func refreshDownloaded() {
        guard let base = PronunciationDictionary.baseURL else { downloaded = []; return }
        downloaded = DictionaryCopies.listed(DictionaryCopies.scan(base),
                                             inUse: PronunciationDictionary.installedFolder(store)?.lastPathComponent,
                                             active: store.dictionaryFolder)
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

    /// The "Dictionary source" picker. A source downloaded before is used at once from its copy; one not downloaded
    /// yet is downloaded at once when the dictionary is on (else when it is switched on); Custom waits for a link.
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
        refreshInstalled()          // a repository downloaded before: its copy, then the check below says if it is current
        status = ""
        Task { await update(reason: .source) }      // a link given is a request to fetch it, on or off
    }

    /// A "Downloaded dictionaries" row's Remove button: its folder and its sidecar go.
    func remove(_ d: DownloadedDictionary) {
        guard !isBusy else { return }
        guard let base = PronunciationDictionary.baseURL else {
            status = "Couldn't remove: " + Self.describe(DictionarySourceError.noContainer)
            return
        }
        do {
            try DictionaryCopies.remove(d.id, base: base, state: store,
                                        inUse: PronunciationDictionary.installedFolder(store)?.lastPathComponent)
            status = d.removedStatus
        } catch {
            status = "Couldn't remove \(d.isKnown ? d.name : "unknown dictionary")."
        }
        refreshInstalled()
    }

    /// "Update now".
    func updateNow() {
        Task { await update(reason: .manual) }
    }

    /// App launch / coming forward: remove a source's superseded copies; if auto-update is on and the last
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
            // The source was changed while this one was downloading: fetch the one now chosen, unless its copy from
            // before is already in force (setSource made it so).
            refreshInstalled()
            if let now = store.dictionarySource, now != source, store.dictionaryEnabled,
               PronunciationDictionary.installedFolder(store) == nil {
                Task { await update(reason: .source) }
            }
        }
        status = "Checking..."
        checks += 1
        do {
            let snap = try await fetcher.latest(source)
            store.dictionaryLastCheck = Date()
            // Layout 2 (2026-09-24) also carries the other languages' files: an install from before is
            // fetched again once, even at the same tag, so German arrives without waiting for a release.
            if snap.version == store.dictionaryTag, PronunciationDictionary.installedFolder(store) != nil,
               store.dictionaryLayout >= 2 {
                status = "Up to date."
                return
            }
            status = "Downloading \(Self.versionText(snap.version))..."
            let inForce = try await install(snap)
            refreshInstalled()
            if inForce {
                status = "Updated to \(Self.versionText(snap.version))."
                    + (store.dictionaryEnabled ? "" : " Dictionary is off.")
            } else {
                // Another source was chosen while this one downloaded: kept as a copy, not used.
                status = "Downloaded \(DictionarySource.displayName(snap.source.id)) \(Self.versionText(snap.version))."
            }
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

    /// Downloads the snapshot's files into a new folder with its sidecar, validates them (each parses into entries),
    /// then, when its source is still the one chosen, points the settings at it. Returns whether it did (false: the
    /// user chose another source meanwhile, and the copy is kept for when they come back to this one).
    private func install(_ snap: DictionarySnapshot) async throws -> Bool {
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
            var counts: [String: [Int]] = [:]
            for lang in langs {
                if let c = lang.communityPrefix.flatMap({ got[$0.uppercased()] }) { counts[lang.code] = c }
            }
            let info = DictionaryCopies.info(for: snap, counts: counts, layout: 2)
            try DictionaryCopies.write(info, to: incoming)
            let final = base.appendingPathComponent(folder, isDirectory: true)
            try fm.moveItem(at: incoming, to: final)
            // Only now does anything point at the new copy (and only if its source is still the chosen one). The
            // source's older copy stays until cleanUp, at the next launch or return to the app.
            guard let chosen = store.dictionarySource, DictionaryCopies.sameSource(chosen.id, snap.source.id) else {
                return false
            }
            DictionaryCopies.activate(DictionaryCopy(folder: folder, info: info, bytes: 0), as: chosen.id, state: store)
            return true
        } catch {
            try? fm.removeItem(at: incoming)
            throw error
        }
    }

    /// A source's older copies and a crashed download's leftovers (never while a download runs). The copies of other
    /// sources stay: they are listed under "Downloaded dictionaries" for the user to keep or remove.
    private func removeUnusedFolders() {
        guard let base = PronunciationDictionary.baseURL else { return }
        DictionaryCopies.cleanUp(base: base, state: store, downloading: isBusy)
    }
}
