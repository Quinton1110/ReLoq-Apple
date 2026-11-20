// LIVE check of the dictionary sources (network; NOT part of `make test`): `make dict-live-test`.
// For each offered source, through the same functions the app uses (Shared/DictionarySource.swift): its latest
// release from GitHub, the files found in it, downloaded and installed under the app's names, counted by the
// bridge's own parser - then handed to the bridge (ev_dict_configure_lang, ReLoq C linked in) and a sentence of
// words from each file spoken with and without them: the dictionary must change the speech, and the handle's
// report must show the main file loaded and root entries handed over.
// Extra arguments are GitHub links to check the same way (a Custom source).

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

final class PCM { var samples: [Int16] = [] }
let collect: ev_pcm_fn = { pcm, n, user in
    let b = Unmanaged<PCM>.fromOpaque(user!).takeUnretainedValue()
    b.samples.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(n)))
    return 0
}

func speak(_ text: String) -> [Int16] {
    guard let v = ev_voice_open(1) else { return [] }
    defer { ev_voice_close(v) }
    var r = ev_request()
    ev_voice_preset_params(v, &r.voice)
    r.voice.speed = 50
    r.prosody.speed = 1; r.prosody.range = 1; r.prosody.volume = 1
    r.sample_rate = 11025
    let b = PCM()
    _ = ev_voice_speak(v, text, &r, collect, Unmanaged.passUnretained(b).toOpaque())
    return b.samples
}

func report(_ text: String) -> ev_dict_report {
    var rep = ev_dict_report()
    guard let v = ev_voice_open(1) else { return rep }
    defer { ev_voice_close(v) }
    var r = ev_request()
    ev_voice_preset_params(v, &r.voice)
    r.prosody.speed = 1; r.prosody.range = 1; r.prosody.volume = 1
    r.sample_rate = 11025
    let b = PCM()
    _ = ev_voice_speak(v, text, &r, collect, Unmanaged.passUnretained(b).toOpaque())
    ev_voice_dict_report(v, &rep)
    return rep
}

let US: Int32 = 0x10000
let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("ev-dictsource-live-\(getpid())", isDirectory: true)
try? fm.removeItem(at: tmp)
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
let fetcher = DictionaryFetcher(session: URLSession(configuration: .ephemeral), userAgent: "ReLoq-Apple-test")

var sources = [DictionarySource.eigencrow, DictionarySource.alternative]
for a in CommandLine.arguments.dropFirst() {
    if let s = DictionarySource.parse(a) { sources.append(s) } else { check(false, "not a GitHub link: \(a)") }
}

for source in sources {
    let dir = tmp.appendingPathComponent(source.repo, isDirectory: true)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        let snap = try await fetcher.latest(source)
        let found = DictionaryLayout.find(paths: snap.paths)
        print("\(source.id): version \(snap.version), published \(snap.published.map { "\($0)" } ?? "?"), "
              + "found " + found.keys.sorted().map { p in "\(p)=" + DictionaryKind.allCases.map { found[p]![$0] ?? "-" }.joined(separator: ",") }
                .joined(separator: " "))
        let got = try await fetcher.download(snap, prefixes: ["ENU", "DEU"], into: dir,
                                             count: { Int(ev_dict_count_entries($0.path)) })
        for (p, c) in got.sorted(by: { $0.key < $1.key }) { print("  \(p) entries main/root/abbr: \(c)") }
        let enu = got["ENU"] ?? []
        check(enu.count == 3 && (enu[0] > 0 || enu[1] > 0), "\(source.id): US English installed, entries \(enu)")
        let paths = DictionaryKind.allCases.map { k -> String? in
            let u = dir.appendingPathComponent(k.communityFile(prefix: "ENU"))
            return fm.fileExists(atPath: u.path) ? u.path : nil
        }
        // a sentence of keys from the main and root files (the first ten plain-word entries of each)
        var words: [String] = []
        for (k, p) in zip(DictionaryKind.allCases, paths) where k != .abbreviation {
            guard let p else { continue }
            words += DictionaryFile.load(URL(fileURLWithPath: p), kind: k).map(\.word)
                .filter { $0.allSatisfy { $0.isLetter } && $0.count > 2 }.prefix(10)
        }
        let text = words.joined(separator: ", ") + "."
        ev_dict_configure_lang(US, nil, nil, nil)
        let plain = speak(text)
        ev_dict_configure_lang(US, paths[0], paths[1], paths[2])
        let with = speak(text)
        let rep = report(text)
        print("  bridge: root table \(ev_dict_root_entries()) entries; report in_force=\(rep.in_force) main_rc=\(rep.main_rc) "
              + "abbr_rc=\(rep.abbr_rc) root_added=\(rep.root_added); \(words.count) words, \(plain.count) -> \(with.count) samples")
        check(!plain.isEmpty && !with.isEmpty && plain != with,
              "\(source.id): loaded through the bridge, and its entries change the speech (\(plain.count) -> \(with.count) samples)")
        // eciLoadDict answers 0 (DictNoError) for a loaded file, -1 here = not loaded; the root table holds one entry
        // per key, so a file's repeated keys count once
        let rootN = Int(ev_dict_root_entries())
        check(rep.in_force != 0 && (paths[0] == nil ? rep.main_rc == -1 : rep.main_rc == 0)
              && (paths[2] == nil ? rep.abbr_rc == -1 : rep.abbr_rc == 0)
              && (paths[1] == nil || (rootN > 0 && rootN <= enu[1] && rep.root_added > 0)),
              "\(source.id): the bridge's report agrees (main rc \(rep.main_rc), abbr rc \(rep.abbr_rc), root table \(rootN) of \(enu[1]) lines, \(rep.root_added) handed over)")
        ev_dict_configure_lang(US, nil, nil, nil)
    } catch {
        check(false, "\(source.id): \(error)")
    }
}

try? fm.removeItem(at: tmp)
print(failures == 0 ? "PASSED" : "FAILED: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
