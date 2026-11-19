//
//  UserDictionary.swift
//  The user's OWN pronunciation entries: words they add, and their edits of community entries (an edit
//  is stored as their own entry with the same key - the downloaded files are never modified). Three
//  files in the community files' own format (Windows-1252, one "key TAB replacement" per line), in a
//  folder of their own, <group>/Library/UserDictionary/, which the community download, "Update now" and
//  the clean-up of old releases (App/DictionaryUpdater.swift, which works only under
//  Library/Dictionaries) never touch.
//
//  They are ALWAYS in force when there are any, whether or not "Use community dictionary" is on - they
//  are the user's own list - and they win over the community files (ev_bridge.h "THE USER'S OWN
//  ENTRIES" says how the engine is handed them).
//
//  Case follows the engine, so duplicate detection does too: whole words and abbreviations match
//  exactly ("US" and "us" are two entries), word roots in any capitalisation.
//
//  This file has no app-group or bridge dependency so the Mac test (`make userdict-test`) compiles it
//  as it is; the app-group location is in PronunciationDictionary.swift.
//

import Foundation

/// Which of the engine's three volumes an entry belongs to.
enum DictionaryKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case word, root, abbreviation

    var id: String { rawValue }

    /// The user's file for this kind.
    var userFile: String {
        switch self {
        case .word: return "user-main.dic"
        case .root: return "user-root.dic"
        case .abbreviation: return "user-abbr.dic"
        }
    }

    /// The community file for this kind (US English's names; PronunciationDictionary).
    var communityFile: String { communityFile(prefix: "ENU") }

    /// The community file for this kind in a language's set: "DEU" -> "DEUmain.dic" ...
    func communityFile(prefix: String) -> String {
        switch self {
        case .word: return prefix + "main.dic"
        case .root: return prefix + "Root.dic"
        case .abbreviation: return prefix + "abbr.dic"
        }
    }

    /// As VoiceOver reads it in a row and in the picker.
    var title: String {
        switch self {
        case .word: return "Whole word"
        case .root: return "Word root"
        case .abbreviation: return "Abbreviation"
        }
    }

    var explanation: String {
        switch self {
        case .word: return "Matches the word as written, any capitalisation unless you add that spelling too."
        case .root: return "Matches the word and its endings, any capitalisation. One word or phonemes."
        case .abbreviation: return "Matches exactly, capitals included."
        }
    }

    /// Whether the engine matches this kind's keys exactly (true) or in any capitalisation (false).
    var caseSensitive: Bool { self != .root }

    /// The form two keys are compared in, as the engine compares them.
    func matchKey(_ word: String) -> String {
        caseSensitive ? word : word.lowercased()
    }
}

struct DictionaryEntry: Identifiable, Hashable, Sendable {
    var kind: DictionaryKind
    var word: String
    var replacement: String

    /// Unique within one list (user or community): the kind and the key as the engine matches it.
    var id: String { kind.rawValue + "\u{1F}" + kind.matchKey(word) }
    var matchKey: String { kind.matchKey(word) }
}

// MARK: - Where the files live, under the app-group container

enum DictionaryLocations {
    /// The community releases: <container>/Library/Dictionaries/<release folder>/. The updater downloads
    /// into here and removes every folder here but the one in use.
    static func community(in container: URL) -> URL {
        container.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Dictionaries", isDirectory: true)
    }

    /// The user's own entries: <container>/Library/UserDictionary/ - a sibling of the community folder,
    /// never inside it, so nothing the updater does can reach it.
    static func user(in container: URL) -> URL {
        container.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("UserDictionary", isDirectory: true)
    }

    /// One language's: US English where it always was, every other language in a sibling folder of its
    /// own ("UserDictionary-dede") - never inside the community folder, never inside another language's.
    static func user(in container: URL, language code: String) -> URL {
        if code == "enus" { return user(in: container) }
        return container.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("UserDictionary-" + code, isDirectory: true)
    }
}

// MARK: - Parsing and writing the files

enum DictionaryFile {
    /// The entries of one file, in file order, exactly as the bridge splits them (ev_dict_split): lines end
    /// at \n or \r, the key is what comes before the first tab, trimmed of spaces and tabs, the
    /// replacement what comes after, trimmed; lines without a tab or with an empty half are skipped.
    static func parse(_ data: Data, kind: DictionaryKind) -> [DictionaryEntry] {
        guard let text = String(data: data, encoding: .windowsCP1252) else { return [] }
        var out: [DictionaryEntry] = []
        text.enumerateLines { line, _ in
            guard let tab = line.firstIndex(of: "\t") else { return }
            let key = line[..<tab].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let value = line[line.index(after: tab)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !key.isEmpty, !value.isEmpty else { return }
            out.append(DictionaryEntry(kind: kind, word: key, replacement: value))
        }
        return out
    }

    /// One entry per key, the LATER line winning (as the engine and the bridge do), in first-seen order.
    static func deduplicated(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var index: [String: Int] = [:]
        var out: [DictionaryEntry] = []
        for e in entries {
            if let i = index[e.id] { out[i] = e } else { index[e.id] = out.count; out.append(e) }
        }
        return out
    }

    static func load(_ url: URL, kind: DictionaryKind) -> [DictionaryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return deduplicated(parse(data, kind: kind))
    }

    /// The file's bytes: Windows-1252, "key TAB replacement" and a newline per entry.
    static func encode(_ entries: [DictionaryEntry]) -> Data? {
        var s = ""
        for e in entries { s += e.word + "\t" + e.replacement + "\n" }
        return s.data(using: .windowsCP1252)
    }
}

// MARK: - Validation

enum DictionaryValidation {
    /// Longest word the bridge will match (its word buffers are 128 bytes).
    static let maxWordBytes = 120
    static let maxReplacementBytes = 400

    /// nil when the entry can be saved, otherwise one plain sentence saying why not.
    static func problem(word: String, replacement: String, kind: DictionaryKind) -> String? {
        let w = word.trimmingCharacters(in: .whitespaces)
        let r = replacement.trimmingCharacters(in: .whitespaces)
        if w.isEmpty { return "Type the word." }
        if r.isEmpty { return "Type how it should be pronounced." }
        if w.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "The word must be a single word, with no spaces."
        }
        if w.contains("`") { return "The word cannot contain a backtick." }
        if r.rangeOfCharacter(from: CharacterSet(charactersIn: "\t\n\r")) != nil {
            return "The pronunciation cannot contain tabs or line breaks."
        }
        guard let wb = w.data(using: .windowsCP1252) else {
            return "Word: use only Western European letters."
        }
        guard let rb = r.data(using: .windowsCP1252) else {
            return "Pronunciation: use only Western European letters."
        }
        if wb.count > maxWordBytes { return "The word is too long." }
        if rb.count > maxReplacementBytes { return "The pronunciation is too long." }
        if kind == .root, !r.hasPrefix("`["), r.rangeOfCharacter(from: .whitespaces) != nil {
            // Measured on the Mac engine 2026-09-24: a root replacement with a space in it is ignored.
            return "A root's pronunciation must be one word or phonemes. Use a whole word entry for several words."
        }
        return nil
    }
}

// MARK: - The user's store

/// Reads and writes the user's three files in one folder. Not thread-safe; the app uses it from the main
/// actor. Writes are atomic (a new file renamed over the old), which is also what tells the bridge in
/// the extension that the file changed (its size, time or inode).
final class UserDictionaryStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func url(for kind: DictionaryKind) -> URL {
        directory.appendingPathComponent(kind.userFile)
    }

    /// Every user entry, all three kinds, one per key.
    func load() -> [DictionaryEntry] {
        DictionaryKind.allCases.flatMap { DictionaryFile.load(url(for: $0), kind: $0) }
    }

    /// Replaces the stored entries with these (one per key; a later one with the same key wins). A kind
    /// with no entries has its file removed.
    func save(_ entries: [DictionaryEntry]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let unique = DictionaryFile.deduplicated(entries)
        for kind in DictionaryKind.allCases {
            let mine = unique.filter { $0.kind == kind }
            let dest = url(for: kind)
            if mine.isEmpty {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                continue
            }
            guard let data = DictionaryFile.encode(mine) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            try data.write(to: dest, options: .atomic)
        }
    }

    /// The three paths for the bridge ("" for a kind with no file).
    var bridgePaths: [String] {
        DictionaryKind.allCases.map { kind in
            let u = url(for: kind)
            return FileManager.default.fileExists(atPath: u.path) ? u.path : ""
        }
    }
}

// MARK: - The two lists together: what the editor shows, and duplicate detection

struct DictionaryCatalog {
    /// The community files' entries (one per key), empty when nothing is downloaded.
    var community: [DictionaryEntry]
    /// The user's own.
    var user: [DictionaryEntry]

    private var communityIndex: [String: Int]
    private var userIndex: [String: Int]

    /// `community` is sorted here (DictionaryCatalog.order) - 70,000 entries, so build this off the main
    /// thread; the user's list is sorted when listed.
    init(community: [DictionaryEntry], user: [DictionaryEntry]) {
        self.community = DictionaryFile.deduplicated(community).sorted(by: Self.order)
        self.user = DictionaryFile.deduplicated(user)
        communityIndex = Dictionary(self.community.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, b in b })
        userIndex = Dictionary(self.user.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    private static func id(_ kind: DictionaryKind, _ word: String) -> String {
        DictionaryEntry(kind: kind, word: word, replacement: "").id
    }

    func userEntry(kind: DictionaryKind, word: String) -> DictionaryEntry? {
        userIndex[Self.id(kind, word)].map { user[$0] }
    }

    func communityEntry(kind: DictionaryKind, word: String) -> DictionaryEntry? {
        communityIndex[Self.id(kind, word)].map { community[$0] }
    }

    /// Whether a user entry replaces a community one (an edit, which "Revert" undoes).
    func isOverride(_ e: DictionaryEntry) -> Bool {
        communityEntry(kind: e.kind, word: e.word) != nil
    }

    /// What is in force for a key: the user's entry if there is one, else the community one.
    func effective(kind: DictionaryKind, word: String) -> DictionaryEntry? {
        userEntry(kind: kind, word: word) ?? communityEntry(kind: kind, word: word)
    }

    enum Duplicate: Equatable {
        case none
        case user(DictionaryEntry)        // the user already has this word
        case community(DictionaryEntry)   // the community dictionary has it (and the user has not edited it)
    }

    /// Duplicate detection for ADDING a word (or renaming one): the same kind and the same key as the
    /// engine matches it. `excluding` is the entry being edited, which is not a duplicate of itself.
    func duplicate(kind: DictionaryKind, word: String, excluding: DictionaryEntry? = nil) -> Duplicate {
        let w = word.trimmingCharacters(in: .whitespaces)
        if let u = userEntry(kind: kind, word: w), u.id != excluding?.id { return .user(u) }
        if let c = communityEntry(kind: kind, word: w), c.id != excluding?.id,
           userEntry(kind: kind, word: w) == nil { return .community(c) }
        return .none
    }

    /// The rows the editor lists: every user entry, then every community entry the user has not replaced.
    /// `query` filters on the word (and the pronunciation), in any case; `kind` nil = all kinds.
    func rows(query: String, kind: DictionaryKind?) -> (mine: [DictionaryEntry], community: [DictionaryEntry]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        func keep(_ e: DictionaryEntry) -> Bool {
            if let k = kind, e.kind != k { return false }
            if q.isEmpty { return true }
            return e.word.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || e.replacement.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let mine = user.filter(keep).sorted(by: Self.order)
        let theirs = community.filter { userIndex[$0.id] == nil && keep($0) }   // already in order
        return (mine, theirs)
    }

    /// Alphabetical by word in any case, then by kind.
    static func order(_ a: DictionaryEntry, _ b: DictionaryEntry) -> Bool {
        let c = a.word.compare(b.word, options: [.caseInsensitive, .diacriticInsensitive])
        if c != .orderedSame { return c == .orderedAscending }
        if a.word != b.word { return a.word < b.word }
        return a.kind.rawValue < b.kind.rawValue
    }

    // MARK: Edits (return the new user list; the caller saves it)

    /// Adds or replaces the user's entry for this key.
    func settingUserEntry(_ e: DictionaryEntry, replacing old: DictionaryEntry? = nil) -> [DictionaryEntry] {
        var list = user
        if let old, let i = list.firstIndex(where: { $0.id == old.id }) { list.remove(at: i) }
        let clean = DictionaryEntry(kind: e.kind,
                                    word: e.word.trimmingCharacters(in: .whitespaces),
                                    replacement: e.replacement.trimmingCharacters(in: .whitespaces))
        if let i = list.firstIndex(where: { $0.id == clean.id }) { list[i] = clean } else { list.append(clean) }
        return list
    }

    /// Removes the user's entry (for an edit of a community entry, that is "revert").
    func removingUserEntry(_ e: DictionaryEntry) -> [DictionaryEntry] {
        user.filter { $0.id != e.id }
    }
}
