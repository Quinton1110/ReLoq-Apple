//
//  DictionaryUpdater.swift
//  Downloads, validates and installs the community pronunciation dictionary (see
//  Shared/PronunciationDictionary.swift) into the app-group container, and keeps it up to date when the
//  user asks it to. App only: the extension just reads what is installed.
//
//  - The latest release comes from the GitHub releases API
//    (api.github.com/repos/eigencrow/IBMTTSDictionaries/releases/latest -> tag_name, published_at);
//    the three .dic files are downloaded AT THAT TAG from raw.githubusercontent.com.
//  - A download goes into a fresh folder of its own. It is validated (every file non-empty and parsed by
//    the bridge into at least a sane number of entries) BEFORE the settings are pointed at it, so the
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
    /// Smallest believable file, in entries (v26.09 has 1,233 / 68,414 / 84): a file that parses into
    /// fewer is an error page or a truncated download, not a dictionary.
    static let minimumEntries = [PronunciationDictionary.mainFile: 50,
                                 PronunciationDictionary.rootFile: 1000,
                                 PronunciationDictionary.abbrFile: 10]

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

    /// The "Use community dictionary" switch. Turning it on with nothing installed downloads the latest.
    func setEnabled(_ on: Bool) {
        store.dictionaryEnabled = on
        if on && installedTag == nil {
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

    enum Reason { case manual, enable, automatic }

    private struct Release { let tag: String; let published: Date? }

    private func update(reason: Reason) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Checking..."
        do {
            let release = try await latestRelease()
            store.dictionaryLastCheck = Date()
            // Layout 2 (2026-09-24) also carries the other languages' files: an install from before is
            // fetched again once, even at the same tag, so German arrives without waiting for a release.
            if release.tag == store.dictionaryTag, PronunciationDictionary.installedFolder(store) != nil,
               store.groupDefaults.integer(forKey: "dict.layout") >= 2 {
                status = "Up to date."
                return
            }
            status = "Downloading \(Self.versionText(release.tag))..."
            _ = try await install(release)
            refreshInstalled()
            status = "Updated to \(Self.versionText(release.tag))."
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

    enum UpdateError: Error {
        case badResponse(Int)
        case noTag
        case emptyFile(String)
        case doesNotParse(String, Int)
        case noContainer
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError {
            switch e {
            case .badResponse(let code): return "GitHub error \(code)."
            case .noTag: return "no release found."
            case .emptyFile(let f): return "\(f) came back empty."
            case .doesNotParse(let f, _): return "\(f) is not a valid dictionary."
            case .noContainer: return "storage unavailable."
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

    private func latestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(PronunciationDictionary.owner)/\(PronunciationDictionary.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("EloquenceVoices-iOS", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.badResponse(code) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { throw UpdateError.noTag }
        let published = (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(tag: tag, published: published)
    }

    /// Downloads the three files at `release.tag` into a new folder, validates them, then points the
    /// settings at it. Returns the entry counts [main, root, abbr].
    private func install(_ release: Release) async throws -> [Int] {
        guard let base = PronunciationDictionary.baseURL else { throw UpdateError.noContainer }
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTag = String(release.tag.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }.prefix(24))
        let folder = "\(safeTag.isEmpty ? "release" : safeTag)-\(Int(Date().timeIntervalSince1970))"
        let incoming = base.appendingPathComponent(".incoming-" + folder, isDirectory: true)
        try? fm.removeItem(at: incoming)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            var counts: [Int] = []
            for name in PronunciationDictionary.files {
                let tag = release.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? release.tag
                let url = URL(string: "https://raw.githubusercontent.com/\(PronunciationDictionary.owner)/\(PronunciationDictionary.repo)/\(tag)/\(name)")!
                var req = URLRequest(url: url)
                req.setValue("EloquenceVoices-iOS", forHTTPHeaderField: "User-Agent")
                let (tmp, resp) = try await session.download(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw UpdateError.badResponse(code) }
                let dest = incoming.appendingPathComponent(name)
                try fm.moveItem(at: tmp, to: dest)
                let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw UpdateError.emptyFile(name) }
                let n = Int(ev_dict_count_entries(dest.path))
                guard n >= Self.minimumEntries[name, default: 1] else { throw UpdateError.doesNotParse(name, max(0, n)) }
                counts.append(n)
            }
            // The other languages the project publishes (v26.09: German). Optional: a language whose
            // files are missing or do not read as a dictionary is left out, and US English still installs.
            var extra: [String: [Int]] = [:]
            for lang in PronunciationDictionary.communityLanguages where lang != ELOQUENCE_US_ENGLISH {
                var got: [Int] = []
                var names: [URL] = []
                for name in PronunciationDictionary.files(for: lang) {
                    let tag = release.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? release.tag
                    let url = URL(string: "https://raw.githubusercontent.com/\(PronunciationDictionary.owner)/\(PronunciationDictionary.repo)/\(tag)/\(name)")!
                    var req = URLRequest(url: url)
                    req.setValue("EloquenceVoices-iOS", forHTTPHeaderField: "User-Agent")
                    guard let (tmp, resp) = try? await session.download(for: req),
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { break }
                    let dest = incoming.appendingPathComponent(name)
                    try? fm.removeItem(at: dest)
                    guard (try? fm.moveItem(at: tmp, to: dest)) != nil else { break }
                    let n = Int(ev_dict_count_entries(dest.path))
                    guard n >= 1 else { break }
                    got.append(n)
                    names.append(dest)
                }
                if got.count == 3 {
                    extra[lang.code] = got
                } else {
                    for u in names { try? fm.removeItem(at: u) }
                }
            }
            let final = base.appendingPathComponent(folder, isDirectory: true)
            try fm.moveItem(at: incoming, to: final)
            // Only now does anything point at the new copy.
            store.dictionaryFolder = folder
            store.dictionaryTag = release.tag
            store.dictionaryPublished = release.published
            store.dictionaryCounts = counts
            store.groupDefaults.set(2, forKey: "dict.layout")
            for lang in PronunciationDictionary.communityLanguages where lang != ELOQUENCE_US_ENGLISH {
                store.setDictionaryCounts(extra[lang.code] ?? [], for: lang)
            }
            return counts
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
