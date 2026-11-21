// Mac test of the downloaded dictionaries, one copy per source (Shared/DictionaryCopies.swift, the same file the app
// and the extension compile): the sidecar a copy from before gets from the settings, a switch back to a source
// downloaded before (its copy in force again, its version, date and counts restored, nothing fetched), an update that
// replaces only that source's older copy, the "Downloaded dictionaries" list and its wording, Remove, unknown folders,
// a download in progress, Custom links by owner/repo, and no container. `make dictcopies-test` (part of `make test`).
// Everything is written to a temporary folder and removed; the settings are a plain object, not the app group.

import Foundation

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if ok { passes += 1 } else { failures += 1 }
}

/// The settings, as VoiceSettingsStore keeps them (an unset installed source is eigencrow's, as there).
final class Settings: DictionaryActiveState {
    var dictionaryFolder: String?
    var installedDictionarySource = DictionarySource.eigencrow.id
    var dictionaryTag: String?
    var dictionaryPublished: Date?
    var dictionaryLayout = 0
    var communityCounts: [String: [Int]] = [:]
    /// "Dictionary source": the repository chosen ("owner/repo"; nil = Custom without a link).
    var chosen: String? = DictionarySource.eigencrow.id
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("ev-dictcopies-test-\(getpid())", isDirectory: true)
try? fm.removeItem(at: tmp)
let base = tmp.appendingPathComponent("group/Library/Dictionaries", isDirectory: true)
try! fm.createDirectory(at: base, withIntermediateDirectories: true)
let files = ["ENUmain.dic", "ENURoot.dic", "ENUabbr.dic"]
let en = Locale(identifier: "en_US")
let alt = DictionarySource.alternative.id, eig = DictionarySource.eigencrow.id

/// A folder of .dic files of these sizes (bytes), as a download leaves it.
func makeFolder(_ name: String, _ sizes: [String: Int]) {
    let dir = base.appendingPathComponent(name, isDirectory: true)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (f, n) in sizes { try! Data(repeating: 0x61, count: n).write(to: dir.appendingPathComponent(f)) }
}
func exists(_ name: String) -> Bool { fm.fileExists(atPath: base.appendingPathComponent(name).path) }
/// What DictionaryUpdater.install does once a download is complete: the sidecar, then (when its source is the chosen
/// one) the settings point at it.
func install(_ name: String, source: String, tag: String, counts: [String: [Int]], at: Date, sizes: [String: Int],
             _ s: Settings) {
    makeFolder(name, sizes)
    let snap = DictionarySnapshot(source: DictionarySource.parse(source)!, ref: tag, version: tag,
                                  published: at.addingTimeInterval(-86400), paths: [])
    let info = DictionaryCopies.info(for: snap, counts: counts, layout: 2, now: at)
    try! DictionaryCopies.write(info, to: base.appendingPathComponent(name))
    if let c = s.chosen, DictionaryCopies.sameSource(c, source) {
        DictionaryCopies.activate(DictionaryCopy(folder: name, info: info, bytes: 0), as: c, state: s)
    }
}
func inUse(_ s: Settings) -> String? {
    DictionaryCopies.folderInForce(base: base, folder: s.dictionaryFolder, installedSource: s.installedDictionarySource,
                                   chosen: s.chosen, files: files)?.lastPathComponent
}
/// The picker: what DictionaryUpdater.setSource -> refreshInstalled does. Returns whether a download would follow
/// (nothing in force for the chosen source afterwards).
func choose(_ source: String?, _ s: Settings) -> Bool {
    s.chosen = source
    DictionaryCopies.activateKeptCopy(chosen: source, base: base, state: s, files: files)
    return source != nil && inUse(s) == nil
}
func list(_ s: Settings) -> [DownloadedDictionary] {
    DictionaryCopies.listed(DictionaryCopies.scan(base), inUse: inUse(s), active: s.dictionaryFolder, locale: en)
}

// MARK: - Migration: the one folder an install from before sources left, with only the settings to describe it

let t0 = Date(timeIntervalSince1970: 1_763_000_000)
let s = Settings()
makeFolder("v26.11-100", ["ENUmain.dic": 30_000, "ENURoot.dic": 1_500_000, "ENUabbr.dic": 2_000, "DEUmain.dic": 1_000])
s.dictionaryFolder = "v26.11-100"
s.dictionaryTag = "v26.11"
s.dictionaryPublished = t0
s.dictionaryLayout = 2
s.communityCounts = ["enus": [1242, 69757, 84], "dede": [43, 157, 14]]
check(DictionaryCopies.scan(base).first?.info == nil, "before migration the folder has no sidecar")
check(DictionaryCopies.migrate(base: base, state: s), "migration writes the sidecar of the folder in use")
let migrated = DictionaryCopies.read(base.appendingPathComponent("v26.11-100"))
check(migrated?.source == eig && migrated?.tag == "v26.11" && migrated?.published == t0 && migrated?.layout == 2
      && migrated?.counts == ["enus": [1242, 69757, 84], "dede": [43, 157, 14]],
      "the sidecar says eigencrow (no source recorded = eigencrow's), with the settings' version, date, counts, layout")
check(!DictionaryCopies.migrate(base: base, state: s), "a second migration writes nothing")
check(inUse(s) == "v26.11-100" && list(s).isEmpty, "in use, so not listed: nothing under Downloaded dictionaries")
try! Data("{not json".utf8).write(to: base.appendingPathComponent("v26.11-100/\(DictionaryCopies.infoFile)"))
check(DictionaryCopies.migrate(base: base, state: s)
      && DictionaryCopies.read(base.appendingPathComponent("v26.11-100"))?.source == eig,
      "an unreadable sidecar of the folder in use is written again from the settings")

// MARK: - Switching to a source not downloaded, then back

let t1 = t0.addingTimeInterval(3600)
check(choose(alt, s), "AltIBMTTSDictionaries chosen, no copy of it: a download follows")
check(inUse(s) == nil && s.dictionaryFolder == "v26.11-100", "until it is in, no community set is in force; the settings still name eigencrow's folder")
check(list(s).map(\.id) == ["v26.11-100"], "meanwhile eigencrow's copy is listed (removable)")
install("2026-11-200", source: alt, tag: "2026-11", counts: ["enus": [81, 3272, 0]], at: t1,
        sizes: ["ENUmain.dic": 3_000, "ENURoot.dic": 117_000], s)
check(inUse(s) == "2026-11-200" && s.dictionaryTag == "2026-11" && s.communityCounts == ["enus": [81, 3272, 0]]
      && s.installedDictionarySource == alt, "the download in force, its version and counts in the settings")
check(exists("v26.11-100"), "eigencrow's copy is kept")
let rows = list(s)
check(rows.count == 1 && rows[0].id == "v26.11-100" && rows[0].name == "IBMTTSDictionaries by eigencrow",
      "Downloaded dictionaries: eigencrow's copy only (Alt is in use)")
check(rows.first?.spokenLabel == "IBMTTSDictionaries by eigencrow, version 26.11, 1.5 megabytes",
      "VoiceOver hears one label for the row: \(rows.first?.spokenLabel ?? "-")")
check(rows.first?.detail == "Version 26.11, 1.5 MB" && rows.first?.removeLabel == "Remove IBMTTSDictionaries by eigencrow",
      "shown: \(rows.first?.detail ?? "-"); the button: \(rows.first?.removeLabel ?? "-")")

check(!choose(eig, s), "back to eigencrow: its copy is used, no download")
check(inUse(s) == "v26.11-100" && s.dictionaryTag == "v26.11" && s.dictionaryPublished == t0 && s.dictionaryLayout == 2
      && s.communityCounts == ["enus": [1242, 69757, 84], "dede": [43, 157, 14]] && s.installedDictionarySource == eig,
      "its version, date, layout and every language's counts restored")
check(list(s).map(\.name) == ["AltIBMTTSDictionaries by Mohamed00"]
      && list(s).first?.spokenLabel == "AltIBMTTSDictionaries by Mohamed00, version 2026-11, 120 kilobytes",
      "now Alt is listed: \(list(s).first?.spokenLabel ?? "-")")
check(!choose(alt, s) && inUse(s) == "2026-11-200" && s.dictionaryTag == "2026-11", "and to Alt again: its copy, no download")
_ = choose(eig, s)

// MARK: - An update replaces only that source's older copy

let t2 = t1.addingTimeInterval(3600)
install("v26.12-300", source: eig, tag: "v26.12", counts: ["enus": [1300, 70000, 90], "dede": [44, 160, 14]], at: t2,
        sizes: ["ENUmain.dic": 31_000, "ENURoot.dic": 1_510_000, "ENUabbr.dic": 2_100], s)
check(inUse(s) == "v26.12-300" && s.dictionaryTag == "v26.12", "eigencrow updated: the new copy in force")
check(DictionaryCopies.superseded(DictionaryCopies.scan(base), active: s.dictionaryFolder) == ["v26.11-100"],
      "the older eigencrow copy is superseded; Alt's is not")
check(list(s).map(\.id) == ["2026-11-200"], "the superseded copy is not listed, Alt's is")
check(exists("v26.11-100"), "the older copy stays until the clean-up (the extension may still read it)")
try! fm.createDirectory(at: base.appendingPathComponent(".incoming-v26.13-400"), withIntermediateDirectories: true)
DictionaryCopies.cleanUp(base: base, state: s, downloading: true)
check(exists("v26.11-100") && exists(".incoming-v26.13-400"), "no clean-up while a download runs")
check(!list(s).contains { $0.id.hasPrefix(".") }, "a download in progress is never listed")
DictionaryCopies.cleanUp(base: base, state: s, downloading: false)
check(!exists("v26.11-100") && !exists(".incoming-v26.13-400") && exists("v26.12-300") && exists("2026-11-200"),
      "the clean-up: the older eigencrow copy and a dead download gone; the new one and Alt's kept")
check(!choose(eig, s) && inUse(s) == "v26.12-300", "still in force after the clean-up")
_ = choose(alt, s)
check(inUse(s) == "2026-11-200" && list(s).map(\.id) == ["v26.12-300"], "and switching away keeps one eigencrow copy, the new one")
_ = choose(eig, s)

// MARK: - Unknown folders

makeFolder("v26.10-50", ["ENUmain.dic": 12_000])
makeFolder("odd-60", ["ENUmain.dic": 999])
try! Data("[]".utf8).write(to: base.appendingPathComponent("odd-60/\(DictionaryCopies.infoFile)"))
let unknown = list(s).filter { !$0.isKnown }
check(unknown.map(\.id) == ["odd-60", "v26.10-50"] && list(s).last?.isKnown == false,
      "folders with no or a corrupt sidecar: listed as unknown, after the known ones")
check(unknown.first { $0.id == "v26.10-50" }?.spokenLabel == "Unknown dictionary, 12 kilobytes"
      && unknown.first { $0.id == "v26.10-50" }?.removeLabel == "Remove unknown dictionary"
      && unknown.first { $0.id == "odd-60" }?.spokenLabel == "Unknown dictionary, 1 kilobyte",
      "an unknown row: its size only")
DictionaryCopies.cleanUp(base: base, state: s, downloading: false)
check(exists("v26.10-50") && exists("odd-60"), "the clean-up never removes an unknown folder")

// MARK: - Remove

check((try? DictionaryCopies.remove("v26.12-300", base: base, state: s, inUse: inUse(s))) == nil && exists("v26.12-300"),
      "the copy in use cannot be removed")
var err: DictionaryCopyError?
do { try DictionaryCopies.remove("v26.12-300", base: base, state: s, inUse: inUse(s)) } catch { err = error as? DictionaryCopyError }
check(err == .inUse, "refused as in use")
for bad in ["", "..", "../x", ".incoming-v26.13-400", "a/b"] {
    err = nil
    do { try DictionaryCopies.remove(bad, base: base, state: s, inUse: inUse(s)) } catch { err = error as? DictionaryCopyError }
    check(err == .notACopy, "not a copy, refused: \"\(bad)\"")
}
try! DictionaryCopies.remove("2026-11-200", base: base, state: s, inUse: inUse(s))
check(!exists("2026-11-200") && inUse(s) == "v26.12-300" && !list(s).contains { $0.id == "2026-11-200" },
      "Alt's copy removed (folder and sidecar); eigencrow still in force")
check(choose(alt, s), "choosing Alt again downloads it")
_ = choose(eig, s)
try! DictionaryCopies.remove("v26.10-50", base: base, state: s, inUse: inUse(s))
try! DictionaryCopies.remove("odd-60", base: base, state: s, inUse: inUse(s))
check(!exists("v26.10-50") && !exists("odd-60") && list(s).isEmpty, "unknown folders removed")

// A switch whose download has not finished: the settings still name the old source's folder, which is not in force.
check(!choose(nil, s) && inUse(s) == nil, "Custom without a link: nothing in force, nothing to download")
check(list(s).map(\.id) == ["v26.12-300"], "eigencrow's copy is then listed")
try! DictionaryCopies.remove("v26.12-300", base: base, state: s, inUse: inUse(s))
check(s.dictionaryFolder == nil && s.dictionaryTag == nil && s.communityCounts.isEmpty && !exists("v26.12-300"),
      "removing the folder the settings name lets go of it in the settings too")
check(choose(eig, s), "and eigencrow is downloaded again when chosen")

// MARK: - Custom links: a copy per owner/repo, any case

install("v1-500", source: "Someone/Dicts", tag: "v1", counts: ["enus": [5, 6, 0]], at: t2, sizes: ["ENUmain.dic": 500], s)
_ = choose("someone/dicts", s)
check(inUse(s) == "v1-500" && s.installedDictionarySource == "someone/dicts",
      "a Custom link in another case finds the same repository's copy (and the settings take the chosen spelling)")
s.chosen = "other/dicts"
install("main-600", source: "other/dicts", tag: "main abc1234", counts: ["enus": [7, 0, 0]], at: t2,
        sizes: ["ENUmain.dic": 2_500_000], s)
check(inUse(s) == "main-600" && list(s).map(\.name) == ["Dicts by Someone"],
      "another Custom repository: its own copy; the first listed as \"repo by owner\"")
_ = choose("someone/dicts", s)
check(list(s).first?.spokenLabel == "dicts by other, version main abc1234, 2.5 megabytes",
      "a repository with no release: its branch and commit as the version: \(list(s).first?.spokenLabel ?? "-")")
check(DictionarySource.displayName("mohamed00/altibmttsdictionaries") == "AltIBMTTSDictionaries by Mohamed00"
      && DictionarySource.displayName("EIGENCROW/IBMTTSDictionaries") == "IBMTTSDictionaries by eigencrow",
      "the offered sources keep the picker's names in any case")
install("v2-700", source: "Someone/Dicts", tag: "v2", counts: ["enus": [6, 6, 0]], at: t2.addingTimeInterval(60),
        sizes: ["ENUmain.dic": 600], s)
check(inUse(s) == "v2-700" && DictionaryCopies.superseded(DictionaryCopies.scan(base), active: s.dictionaryFolder) == ["v1-500"],
      "a Custom repository's update supersedes only its own older copy")

// A download that finishes after the user chose another source: kept, not put in force.
s.chosen = alt
_ = choose(eig, s)       // nothing of eigencrow's any more: nothing in force
install("2026-12-800", source: alt, tag: "2026-12", counts: ["enus": [90, 3300, 0]], at: t2, sizes: ["ENUmain.dic": 3_000], s)
check(inUse(s) == nil && s.dictionaryFolder != "2026-12-800" && list(s).contains { $0.id == "2026-12-800" },
      "a download of a source no longer chosen is kept as a copy, not used")

// MARK: - Sizes, and no container

check(DictionaryCopies.sizeText(1_234_567, spoken: false, locale: en) == "1.2 MB"
      && DictionaryCopies.sizeText(1_000_000, spoken: true, locale: en) == "1 megabyte"
      && DictionaryCopies.sizeText(820_400, spoken: true, locale: en) == "820 kilobytes"
      && DictionaryCopies.sizeText(10, spoken: false, locale: en) == "1 KB"
      && DictionaryCopies.sizeText(2_500_000_000, spoken: true, locale: en) == "2.5 gigabytes"
      && DictionaryCopies.sizeText(1_234_567, spoken: false, locale: Locale(identifier: "de_DE")) == "1,2 MB",
      "sizes in decimal units, the number in the user's locale")
let missing = tmp.appendingPathComponent("no-container/Library/Dictionaries")
let s2 = Settings()
s2.dictionaryFolder = "v26.11-100"
check(DictionaryCopies.scan(missing).isEmpty && !DictionaryCopies.migrate(base: missing, state: s2)
      && !DictionaryCopies.activateKeptCopy(chosen: eig, base: missing, state: s2, files: files)
      && DictionaryCopies.listed([], inUse: nil, active: nil).isEmpty, "no container: nothing listed, nothing written")
DictionaryCopies.cleanUp(base: missing, state: s2, downloading: false)
check(!fm.fileExists(atPath: missing.path), "and the clean-up creates nothing")

try? fm.removeItem(at: tmp)
print("\(passes) ok, \(failures) failed")
exit(failures == 0 ? 0 : 1)
