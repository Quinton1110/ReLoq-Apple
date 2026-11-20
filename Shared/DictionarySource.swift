//
//  DictionarySource.swift
//  Where the community pronunciation dictionary comes from: one GitHub repository at a time, chosen under
//  "Dictionary source" - IBMTTSDictionaries by eigencrow (CC0, the default and the most used),
//  AltIBMTTSDictionaries by Mohamed00, or a repository the user links to. The user's own entries sit on top
//  of whichever is in force, as always.
//
//  - A source's latest RELEASE is used: its tag (api.github.com .../releases/latest), and the .dic files of
//    the repository at that tag (.../git/trees/<tag>?recursive=1), each downloaded from raw.githubusercontent.com
//    at that tag. Both offered sources publish a zip of exactly those files as the release asset; reading the
//    files at the tag needs no unzipping (iOS has no zip API). A repository with NO release falls back to its
//    default branch's latest commit, so a plain repository of .dic files works too.
//  - Files are found wherever they sit, in any case: "<3-letter language prefix><main|root|abbr>.dic"
//    (ENUmain.dic, enuroot.dic, DEUabbr.dic ...). One folder per language is used, so a set is never mixed from
//    two folders: the folder holding the most of that language's three kinds, then the shallowest, then the
//    first by name. (AltIBMTTSDictionaries keeps its general set at the top and an IBMTTS 6.7-specific copy in
//    "IBMTTS 6.7/": the general set is the one used.) A kind a source does not publish is simply absent (the
//    alternative set has no abbreviations file).
//  - Installed under the names the rest of the app has always used (ENUmain.dic, ENURoot.dic, ENUabbr.dic, ...),
//    so a set installed before sources existed keeps working with no new download.
//
//  Pure Foundation (no bridge, no app group): `make userdict-test` compiles it, and `make dict-live-test` downloads
//  both offered sources through these same functions. AltIBMTTSDictionaries carries no licence: it is never
//  bundled, only downloaded from GitHub on the user's device when the user picks it.
//

import Foundation

/// A GitHub repository holding .dic files.
struct DictionarySource: Equatable, Hashable, Sendable {
    let owner: String
    let repo: String

    /// "owner/repo", as stored.
    var id: String { "\(owner)/\(repo)" }
    var webURL: URL { URL(string: "https://github.com/\(owner)/\(repo)")! }

    static let eigencrow = DictionarySource(owner: "eigencrow", repo: "IBMTTSDictionaries")
    static let alternative = DictionarySource(owner: "Mohamed00", repo: "AltIBMTTSDictionaries")

    /// A repository from what the user typed or pasted: https://github.com/owner/repo (http, www, a trailing
    /// .git, slash or path such as /tree/master/x or /releases all allowed), github.com/owner/repo,
    /// git@github.com:owner/repo.git, or plain owner/repo. nil for anything else, including other hosts.
    static func parse(_ text: String) -> DictionarySource? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        let lower = s.lowercased()
        if lower.hasPrefix("git@github.com:") {
            s = String(s.dropFirst("git@github.com:".count))
        } else {
            for scheme in ["https://", "http://"] where lower.hasPrefix(scheme) {
                s = String(s.dropFirst(scheme.count))
                break
            }
            if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
            if s.lowercased().hasPrefix("github.com/") {
                s = String(s.dropFirst("github.com/".count))
            } else if let first = s.split(separator: "/").first, first.contains(".") || first.contains(":") {
                return nil     // another host, or another scheme
            }
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        let ownerOK = !owner.isEmpty && owner.count <= 39
            && owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let repoOK = !repo.isEmpty && repo.count <= 100 && repo != "." && repo != ".."
            && repo.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        guard ownerOK, repoOK else { return nil }
        return DictionarySource(owner: owner, repo: repo)
    }
}

/// The "Dictionary source" picker, most used first.
enum DictionarySourceChoice: String, CaseIterable, Identifiable, Sendable {
    case eigencrow, alternative, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .eigencrow: return "IBMTTSDictionaries by eigencrow"
        case .alternative: return "AltIBMTTSDictionaries by Mohamed00"
        case .custom: return "Custom"
        }
    }

    /// The repository; for Custom, the one the user linked to (nil until a valid link is given).
    func source(custom: String?) -> DictionarySource? {
        switch self {
        case .eigencrow: return .eigencrow
        case .alternative: return .alternative
        case .custom: return custom.flatMap(DictionarySource.parse)
        }
    }

    /// The choice from its stored value; unset or unknown = the default.
    init(stored: String?) { self = stored.flatMap(DictionarySourceChoice.init(rawValue:)) ?? .eigencrow }
}

// MARK: - Finding the files

enum DictionaryLayout {
    /// A file name's language prefix (upper case) and kind, or nil when it is not a dictionary file.
    static func classify(_ fileName: String) -> (prefix: String, kind: DictionaryKind)? {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".dic") else { return nil }
        let stem = lower.dropLast(4)
        guard stem.count == 7 else { return nil }
        let prefix = String(stem.prefix(3)), rest = String(stem.dropFirst(3))
        guard prefix.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let kind: DictionaryKind
        switch rest {
        case "main": kind = .word
        case "root": kind = .root
        case "abbr": kind = .abbreviation
        default: return nil
        }
        return (prefix.uppercased(), kind)
    }

    /// For every language prefix found (upper case: "ENU", "DEU", "ESP" ...), the path of each kind it has, all
    /// from ONE folder: the folder with the most of its kinds, then the shallowest, then the first by name.
    /// Paths are as the repository lists them ("IBMTTS 6.7/enumain.dic"); anything under a folder starting with
    /// "." is ignored.
    static func find(paths: [String]) -> [String: [DictionaryKind: String]] {
        // prefix -> folder -> kind -> path
        var byPrefix: [String: [String: [DictionaryKind: String]]] = [:]
        for path in paths.sorted() {
            let comps = path.split(separator: "/").map(String.init)
            guard let name = comps.last, !comps.dropLast().contains(where: { $0.hasPrefix(".") }),
                  let (prefix, kind) = classify(name) else { continue }
            let folder = comps.dropLast().joined(separator: "/")
            if byPrefix[prefix, default: [:]][folder, default: [:]][kind] == nil {   // first by name wins
                byPrefix[prefix, default: [:]][folder, default: [:]][kind] = path
            }
        }
        var out: [String: [DictionaryKind: String]] = [:]
        for (prefix, folders) in byPrefix {
            let best = folders.keys.sorted { a, b in
                let ka = folders[a]!.count, kb = folders[b]!.count
                if ka != kb { return ka > kb }
                let da = a.isEmpty ? 0 : a.split(separator: "/").count, db = b.isEmpty ? 0 : b.split(separator: "/").count
                if da != db { return da < db }
                return a < b
            }.first!
            out[prefix] = folders[best]!
        }
        return out
    }
}

// MARK: - GitHub

/// What a source offers now: the ref the files are read at (a release tag, or a commit for a repository with no
/// release), how the app names that version, when it was published, and the repository's file paths at it.
struct DictionarySnapshot: Sendable {
    let source: DictionarySource
    let ref: String
    let version: String
    let published: Date?
    let paths: [String]
}

enum DictionarySourceError: Error, Equatable {
    case badResponse(Int)
    case noRepository
    case noFiles
    case emptyFile(String)
    case doesNotParse(String)
    case noContainer
    case notALink
}

struct DictionaryFetcher {
    let session: URLSession
    var userAgent = "ReLoq-Apple"

    private func get(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func api(_ s: DictionarySource, _ tail: String) -> URL {
        URL(string: "https://api.github.com/repos/\(s.owner)/\(s.repo)" + (tail.isEmpty ? "" : "/" + tail))!
    }

    private static func pathEscaped(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// The latest release, or with none the default branch's latest commit; and the paths at it.
    func latest(_ s: DictionarySource) async throws -> DictionarySnapshot {
        let (data, code) = try await get(Self.api(s, "releases/latest"))
        var ref: String, version: String, published: Date?
        let iso = ISO8601DateFormatter()
        if code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = obj["tag_name"] as? String, !tag.isEmpty {
            ref = tag; version = tag
            published = (obj["published_at"] as? String).flatMap { iso.date(from: $0) }
        } else if code == 404 {
            // No release (or no repository): the default branch.
            let (rd, rc) = try await get(Self.api(s, ""))
            guard rc == 200, let repo = try JSONSerialization.jsonObject(with: rd) as? [String: Any],
                  let branch = repo["default_branch"] as? String else {
                throw rc == 404 ? DictionarySourceError.noRepository : DictionarySourceError.badResponse(rc)
            }
            let (cd, cc) = try await get(Self.api(s, "commits/" + Self.pathEscaped(branch)))
            guard cc == 200, let commit = try JSONSerialization.jsonObject(with: cd) as? [String: Any],
                  let sha = commit["sha"] as? String else { throw DictionarySourceError.badResponse(cc) }
            ref = sha
            version = "\(branch) \(sha.prefix(7))"
            let c = commit["commit"] as? [String: Any]
            published = ((c?["committer"] as? [String: Any])?["date"] as? String).flatMap { iso.date(from: $0) }
        } else {
            throw DictionarySourceError.badResponse(code)
        }
        let (td, tc) = try await get(Self.api(s, "git/trees/\(Self.pathEscaped(ref))?recursive=1"))
        guard tc == 200, let tree = try JSONSerialization.jsonObject(with: td) as? [String: Any],
              let items = tree["tree"] as? [[String: Any]] else { throw DictionarySourceError.badResponse(tc) }
        let paths = items.compactMap { $0["type"] as? String == "blob" ? $0["path"] as? String : nil }
        return DictionarySnapshot(source: s, ref: ref, version: version, published: published, paths: paths)
    }

    /// The raw file at the snapshot's ref.
    func rawURL(_ snap: DictionarySnapshot, path: String) -> URL {
        let p = path.split(separator: "/").map { Self.pathEscaped(String($0)) }.joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(snap.source.owner)/\(snap.source.repo)/\(Self.pathEscaped(snap.ref))/\(p)")!
    }

    /// Downloads the found files of these languages (prefixes, US English first) into `dir`, under the app's
    /// names (DictionaryKind.communityFile), and counts each with `count` (the bridge's parser in the app).
    /// Returns, per prefix that has any, [main, root, abbr] entry counts with 0 for a kind it does not have.
    /// The FIRST prefix is required (no file of it = noFiles; a file that does not parse = doesNotParse); the
    /// others are optional and left out whole when any of their files fails.
    func download(_ snap: DictionarySnapshot, prefixes: [String], into dir: URL,
                  count: (URL) -> Int) async throws -> [String: [Int]] {
        let fm = FileManager.default
        let found = DictionaryLayout.find(paths: snap.paths)
        guard let first = prefixes.first, let required = found[first], !required.isEmpty else {
            throw DictionarySourceError.noFiles
        }
        var out: [String: [Int]] = [:]
        for prefix in prefixes {
            guard let kinds = found[prefix], !kinds.isEmpty else { continue }
            let isRequired = prefix == first
            var counts: [Int] = []
            var written: [URL] = []
            do {
                for kind in DictionaryKind.allCases {
                    guard let path = kinds[kind] else { counts.append(0); continue }
                    var req = URLRequest(url: rawURL(snap, path: path))
                    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    let (tmp, resp) = try await session.download(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw DictionarySourceError.badResponse(code) }
                    let dest = dir.appendingPathComponent(kind.communityFile(prefix: prefix))
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: tmp, to: dest)
                    written.append(dest)
                    let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
                    let name = (path as NSString).lastPathComponent
                    guard size > 0 else { throw DictionarySourceError.emptyFile(name) }
                    let n = count(dest)
                    guard n >= 1 else { throw DictionarySourceError.doesNotParse(name) }
                    counts.append(n)
                }
                out[prefix] = counts
            } catch {
                for u in written { try? fm.removeItem(at: u) }
                if isRequired { throw error }
            }
        }
        return out
    }
}
