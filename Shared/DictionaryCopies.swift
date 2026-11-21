//
//  DictionaryCopies.swift
//  Every community dictionary downloaded, one copy per source: switching back to a source already downloaded uses
//  its copy at once (no new download), and the copies not in use are listed under "Downloaded dictionaries" with a
//  Remove button each.
//
//  - Each copy is a folder of its own under Library/Dictionaries (the installed .dic files, as before) with a small
//    sidecar, dictionary-info.json: the source ("owner/repo"), its version, publication date, entry counts per
//    language, when it was installed and the layout number. The sidecar is written into the download folder BEFORE
//    the folder is moved into place, so a copy is either complete with its sidecar or not there at all.
//  - The settings the extension reads are unchanged (dict.folder, dict.installedSource, dict.tag, dict.published,
//    dict.counts, dict.counts.<language>, dict.layout): making a copy active writes them from its sidecar. The
//    extension never reads a sidecar.
//  - One copy per source is kept: the one in use for that source, else the newest. An update of a source leaves its
//    older copy until the next launch or return to the app, when it is removed (cleanUp) - the extension may still
//    be reading it at the moment of the switch. Sources are compared by owner/repo in any case (GitHub's rule).
//  - A copy installed before sidecars existed (the one folder the settings point at) gets its sidecar from the
//    settings (migrate). Any other folder without a readable sidecar is listed as "Unknown dictionary" with its
//    size; it is never removed except by the user.
//  - A download in progress (".incoming-..." folders) is never listed, never removable, and never cleaned up while
//    the download runs.
//
//  Pure Foundation (no bridge, no app group): `make dictcopies-test` compiles it with DictionarySource.swift and
//  tests it on folders of its own. The app's settings conform through VoiceSettingsStore (PronunciationDictionary.swift).
//

import Foundation

/// What the settings say is in force: VoiceSettingsStore in the app and the extension, a plain object in the tests.
protocol DictionaryActiveState: AnyObject {
    var dictionaryFolder: String? { get set }
    var installedDictionarySource: String { get set }
    var dictionaryTag: String? { get set }
    var dictionaryPublished: Date? { get set }
    var dictionaryLayout: Int { get set }
    /// Entry counts per language code ("enus", "dede"): [main, root, abbr]; a language with none is absent.
    var communityCounts: [String: [Int]] { get set }
}

/// A copy's sidecar.
struct DictionaryCopyInfo: Codable, Equatable {
    var source: String
    var tag: String?
    var published: Date?
    var installed: Date
    var layout: Int
    var counts: [String: [Int]]
}

/// One folder under Library/Dictionaries; `info` nil when its sidecar is missing or unreadable.
struct DictionaryCopy: Equatable {
    let folder: String
    let info: DictionaryCopyInfo?
    let bytes: Int64
}

enum DictionaryCopyError: Error, Equatable {
    case inUse
    case notACopy
}

/// A row of "Downloaded dictionaries".
struct DownloadedDictionary: Identifiable, Equatable {
    let id: String              // the folder
    let name: String            // "IBMTTSDictionaries by eigencrow", "Unknown dictionary"
    let version: String?        // "26.11"
    let bytes: Int64
    /// false: the folder's sidecar is missing or unreadable.
    let isKnown: Bool
    private let locale: Locale

    init(_ c: DictionaryCopy, locale: Locale = .current) {
        id = c.folder
        isKnown = c.info != nil
        name = c.info.map { DictionarySource.displayName($0.source) } ?? "Unknown dictionary"
        version = c.info?.tag.flatMap { $0.isEmpty ? nil : DictionaryCopies.versionText($0) }
        bytes = c.bytes
        self.locale = locale
    }

    /// Shown under the name: "Version 26.11, 1.6 MB".
    var detail: String {
        let size = DictionaryCopies.sizeText(bytes, spoken: false, locale: locale)
        return version.map { "Version \($0), \(size)" } ?? size
    }
    /// The row as VoiceOver reads it: "IBMTTSDictionaries by eigencrow, version 26.11, 1.6 megabytes".
    var spokenLabel: String {
        let size = DictionaryCopies.sizeText(bytes, spoken: true, locale: locale)
        return [name, version.map { "version \($0)" }, size].compactMap { $0 }.joined(separator: ", ")
    }
    /// The Remove button: "Remove IBMTTSDictionaries by eigencrow", "Remove unknown dictionary".
    var removeLabel: String { "Remove " + (isKnown ? name : "unknown dictionary") }
    /// The status line after removing it.
    var removedStatus: String { "Removed " + (isKnown ? name : "unknown dictionary") + "." }
}

enum DictionaryCopies {
    static let infoFile = "dictionary-info.json"
    static let incomingPrefix = ".incoming-"

    /// A release tag as the app shows it: "v26.09" -> "26.09".
    static func versionText(_ tag: String) -> String {
        var version = tag
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        return version
    }

    /// Decimal units, as Files and Finder count: "1.6 MB" / "1.6 megabytes", "820 KB" / "820 kilobytes".
    static func sizeText(_ bytes: Int64, spoken: Bool, locale: Locale = .current) -> String {
        let (value, short, long): (Double, String, String) =
            bytes >= 1_000_000_000 ? (Double(bytes) / 1e9, "GB", "gigabyte")
            : bytes >= 1_000_000 ? (Double(bytes) / 1e6, "MB", "megabyte")
            : (max(1, (Double(bytes) / 1e3).rounded()), "KB", "kilobyte")
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        let rounded = (value * 10).rounded() / 10
        let n = f.string(from: NSNumber(value: rounded)) ?? String(rounded)
        if !spoken { return "\(n) \(short)" }
        return "\(n) \(long)" + (rounded == 1 ? "" : "s")
    }

    /// The same GitHub repository: owner/repo in any case.
    static func sameSource(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    /// A folder name a copy can have (never a download in progress, never a path).
    static func isCopyName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name != ".."
    }

    // MARK: - Sidecars

    static func read(_ dir: URL) -> DictionaryCopyInfo? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(infoFile)),
              let info = try? JSONDecoder().decode(DictionaryCopyInfo.self, from: d),
              DictionarySource.parse(info.source) != nil else { return nil }
        return info
    }

    static func write(_ info: DictionaryCopyInfo, to dir: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(info).write(to: dir.appendingPathComponent(infoFile), options: .atomic)
    }

    /// The sidecar a copy just downloaded gets.
    static func info(for snap: DictionarySnapshot, counts: [String: [Int]], layout: Int, now: Date = Date()) -> DictionaryCopyInfo {
        DictionaryCopyInfo(source: snap.source.id, tag: snap.version, published: snap.published, installed: now,
                           layout: layout, counts: counts)
    }

    // MARK: - What is on disk

    /// Total size of a folder's files.
    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    /// Every copy under `base` (empty when it cannot be read), by folder name.
    static func scan(_ base: URL) -> [DictionaryCopy] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.sorted().compactMap { n in
            guard isCopyName(n) else { return nil }
            let dir = base.appendingPathComponent(n, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return DictionaryCopy(folder: n, info: read(dir), bytes: size(of: dir))
        }
    }

    /// The folder in force: the settings' folder, when the source it was installed from IS the chosen one and it holds
    /// at least one of `files` (PronunciationDictionary.installedFolder, which both processes use).
    static func folderInForce(base: URL, folder: String?, installedSource: String, chosen: String?, files: [String]) -> URL? {
        guard let name = folder, !name.isEmpty, let chosen, installedSource == chosen else { return nil }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        guard files.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
        else { return nil }
        return dir
    }

    /// The copy kept for a source: the one the settings point at when it is that source's, else the newest.
    static func keptCopy(of source: String, in copies: [DictionaryCopy], active: String?) -> DictionaryCopy? {
        let mine = copies.filter { c in c.info.map { sameSource($0.source, source) } ?? false }
        if let a = active, let c = mine.first(where: { $0.folder == a }) { return c }
        return mine.max { ($0.info!.installed, $0.folder) < ($1.info!.installed, $1.folder) }
    }

    /// Older copies of a source than the one kept: removed by cleanUp.
    static func superseded(_ copies: [DictionaryCopy], active: String?) -> [String] {
        copies.compactMap { c in
            guard let info = c.info else { return nil }
            return keptCopy(of: info.source, in: copies, active: active)?.folder == c.folder ? nil : c.folder
        }
    }

    /// "Downloaded dictionaries": every kept copy but the one in use, and every unknown folder; by name, unknown last.
    static func listed(_ copies: [DictionaryCopy], inUse: String?, active: String?,
                       locale: Locale = .current) -> [DownloadedDictionary] {
        copies.filter { c in
            guard c.folder != inUse else { return false }
            guard let info = c.info else { return true }
            return keptCopy(of: info.source, in: copies, active: active)?.folder == c.folder
        }
        .map { DownloadedDictionary($0, locale: locale) }
        .sorted { a, b in
            if a.isKnown != b.isKnown { return a.isKnown }
            let o = a.name.localizedCaseInsensitiveCompare(b.name)
            return o == .orderedSame ? a.id < b.id : o == .orderedAscending
        }
    }

    // MARK: - Changing what is in force

    /// A copy from before sidecars: the folder the settings point at gets one from the settings (its source is the
    /// recorded one, which for an install from before sources is eigencrow's). Also repairs an unreadable sidecar of
    /// that folder. Returns whether it wrote one.
    @discardableResult
    static func migrate(base: URL, state: DictionaryActiveState, now: Date = Date()) -> Bool {
        guard let name = state.dictionaryFolder, isCopyName(name) else { return false }
        let fm = FileManager.default
        let dir = base.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, read(dir) == nil else { return false }
        let created = (try? fm.attributesOfItem(atPath: dir.path)[.creationDate] as? Date) ?? now
        let info = DictionaryCopyInfo(source: state.installedDictionarySource, tag: state.dictionaryTag,
                                      published: state.dictionaryPublished, installed: created,
                                      layout: state.dictionaryLayout, counts: state.communityCounts)
        return (try? write(info, to: dir)) != nil
    }

    /// Points the settings at a copy, as the chosen source `source` (its exact spelling, which the extension compares).
    /// The folder is written first: in between, the extension sees a folder whose source is not the chosen one and
    /// uses no community set, never the wrong one.
    static func activate(_ c: DictionaryCopy, as source: String, state: DictionaryActiveState) {
        guard let info = c.info else { return }
        state.dictionaryFolder = c.folder
        state.installedDictionarySource = source
        state.dictionaryTag = info.tag
        state.dictionaryPublished = info.published
        state.dictionaryLayout = info.layout
        state.communityCounts = info.counts
    }

    /// When nothing is in force for the chosen source but a copy of it is on disk: makes that copy active. Returns
    /// whether it did.
    @discardableResult
    static func activateKeptCopy(chosen: String?, base: URL, state: DictionaryActiveState, files: [String]) -> Bool {
        guard let chosen,
              folderInForce(base: base, folder: state.dictionaryFolder, installedSource: state.installedDictionarySource,
                            chosen: chosen, files: files) == nil,
              let c = keptCopy(of: chosen, in: scan(base), active: state.dictionaryFolder),
              files.contains(where: { FileManager.default.fileExists(atPath: base.appendingPathComponent(c.folder)
                                                                       .appendingPathComponent($0).path) })
        else { return false }
        activate(c, as: chosen, state: state)
        return true
    }

    /// The Remove button. Never the copy in use; a copy the settings still point at (a switch whose download has not
    /// finished) is let go of first.
    static func remove(_ folder: String, base: URL, state: DictionaryActiveState, inUse: String?) throws {
        guard isCopyName(folder) else { throw DictionaryCopyError.notACopy }
        guard folder != inUse else { throw DictionaryCopyError.inUse }
        if state.dictionaryFolder == folder {
            state.dictionaryFolder = nil
            state.dictionaryTag = nil
            state.dictionaryPublished = nil
            state.communityCounts = [:]
        }
        try FileManager.default.removeItem(at: base.appendingPathComponent(folder, isDirectory: true))
    }

    /// At launch and on return to the app, not while a download runs: the sidecar of a copy from before, then a crashed
    /// download's leftovers and every superseded copy go. Unknown folders stay (the user removes them).
    static func cleanUp(base: URL, state: DictionaryActiveState, downloading: Bool) {
        guard !downloading else { return }
        migrate(base: base, state: state)
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where n.hasPrefix(incomingPrefix) {
            try? fm.removeItem(at: base.appendingPathComponent(n, isDirectory: true))
        }
        for f in superseded(scan(base), active: state.dictionaryFolder) where f != state.dictionaryFolder {
            try? fm.removeItem(at: base.appendingPathComponent(f, isDirectory: true))
        }
    }
}
