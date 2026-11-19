// Mac test of the user's own pronunciation entries (Shared/UserDictionary.swift, the same file the iOS
// targets compile): parsing as the bridge parses, the store's files, duplicate detection by the engine's
// case rules, edits of community entries kept as the user's own, revert, validation, and that the user's
// files sit where the community updater never reaches. `make userdict-test` (part of `make test`).
// Everything is written to a temporary folder and removed; nothing here ships an entry.

import Foundation

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if ok { passes += 1 } else { failures += 1 }
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("ev-userdict-test-\(getpid())", isDirectory: true)
try? fm.removeItem(at: tmp)
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)

func e(_ k: DictionaryKind, _ w: String, _ r: String) -> DictionaryEntry { DictionaryEntry(kind: k, word: w, replacement: r) }

// MARK: - Parsing, as ev_dict_split does

let raw = Data("ios\tigh oe ess\r\nIOS\tigh oe ess\r\nno tab here\r\n\r\n tabindex \t Tab Index \r\nempty\t \r\n\tno key\r\ncaf\u{e9}\tka fay\r\nios\tlater wins\r\n".utf8)
    .replacingCP1252()
let parsed = DictionaryFile.parse(raw, kind: .word)
check(parsed.count == 5, "parse: 5 entries from 9 lines (no tab, blank, empty halves skipped): \(parsed.count)")
check(parsed.contains(e(.word, "tabindex", "Tab Index")), "parse: key and value trimmed of spaces and tabs")
check(parsed.contains(e(.word, "caf\u{e9}", "ka fay")), "parse: Windows-1252 byte 0xE9 read as \u{e9}")
let dedupWord = DictionaryFile.deduplicated(parsed)
check(dedupWord.count == 4 && dedupWord.first { $0.word == "ios" }?.replacement == "later wins"
      && dedupWord.contains { $0.word == "IOS" },
      "whole words: one per EXACT key, the later line wins; ios and IOS stay two")
let roots = DictionaryFile.deduplicated(DictionaryFile.parse(Data("iphone\tA\nIPhone\tB\n".utf8), kind: .root))
check(roots.count == 1 && roots[0].replacement == "B", "word roots: one per key in ANY case, the later line wins")

// MARK: - The store

let container = tmp.appendingPathComponent("group", isDirectory: true)
let userDir = DictionaryLocations.user(in: container)
let store = UserDictionaryStore(directory: userDir)
check(store.load().isEmpty && store.bridgePaths == ["", "", ""], "a new store is empty and hands the bridge no files")
try! store.save([e(.word, "unread", "un red"), e(.root, "gloop", "`[.1wEl.0kxm]"), e(.abbreviation, "QZX", "quiz ex"),
                 e(.word, "caf\u{e9}", "ka fay")])
let back = store.load()
check(back.count == 4 && Set(back) == Set([e(.word, "unread", "un red"), e(.root, "gloop", "`[.1wEl.0kxm]"),
                                            e(.abbreviation, "QZX", "quiz ex"), e(.word, "caf\u{e9}", "ka fay")]),
      "save then load gives the same entries back")
let mainBytes = try! Data(contentsOf: store.url(for: .word))
check(mainBytes == Data("unread\tun red\ncaf\u{e9}\tka fay\n".utf8).replacingCP1252(),
      "the whole-word file is Windows-1252 'key TAB replacement' lines, as the bridge reads them")
check(store.bridgePaths.allSatisfy { !$0.isEmpty }, "all three files handed to the bridge")
try! store.save([e(.word, "unread", "un red")])
check(!fm.fileExists(atPath: store.url(for: .root).path) && store.bridgePaths[1] == "" && store.load().count == 1,
      "a kind left with no entries has its file removed")

// MARK: - The updater never reaches the user's files

let communityDir = DictionaryLocations.community(in: container)
check(!userDir.standardizedFileURL.path.hasPrefix(communityDir.standardizedFileURL.path + "/"),
      "the user folder (\(userDir.lastPathComponent)) is not inside the community folder (\(communityDir.lastPathComponent))")
// What DictionaryUpdater does: install a release folder, point at it, then remove every other entry of the
// community folder. The user's files must come through unchanged.
try! fm.createDirectory(at: communityDir.appendingPathComponent("v26.08-1"), withIntermediateDirectories: true)
try! fm.createDirectory(at: communityDir.appendingPathComponent("v26.09-2"), withIntermediateDirectories: true)
let before = try! Data(contentsOf: store.url(for: .word))
for name in try! fm.contentsOfDirectory(atPath: communityDir.path) where name != "v26.09-2" {
    try! fm.removeItem(at: communityDir.appendingPathComponent(name))
}
check((try? Data(contentsOf: store.url(for: .word))) == before && store.load() == [e(.word, "unread", "un red")],
      "an update and the clean-up of old releases leave the user's entries as they were")

// MARK: - Duplicate detection, edits, revert

let community = [e(.word, "ios", "igh oe ess"), e(.word, "IOS", "igh oe ess"), e(.word, "US", "you ess"),
                 e(.root, "iphone", "`[.1Y.2fon]"), e(.abbreviation, "WWII", "world war two"),
                 e(.word, "tabindex", "Tab Index")]
var cat = DictionaryCatalog(community: community, user: [e(.word, "unread", "un red")])
check(cat.duplicate(kind: .word, word: "unread") == .user(e(.word, "unread", "un red")),
      "adding a word the user already has: reported as the user's entry")
check(cat.duplicate(kind: .word, word: "Unread") == .none,
      "whole words match exactly, as the engine does: Unread is not a duplicate of unread")
check(cat.duplicate(kind: .root, word: "IPHONE") == .community(e(.root, "iphone", "`[.1Y.2fon]")),
      "word roots match in any case: IPHONE is the community root iphone")
check(cat.duplicate(kind: .word, word: "us") == .none && cat.duplicate(kind: .word, word: "US") == .community(e(.word, "US", "you ess")),
      "US and us are different whole words")
check(cat.duplicate(kind: .abbreviation, word: "tabindex") == .none,
      "a different kind is not a duplicate (tabindex is a whole word, not an abbreviation)")
check(cat.duplicate(kind: .word, word: " unread ") != .none, "surrounding spaces do not hide a duplicate")
check(cat.duplicate(kind: .word, word: "unread", excluding: e(.word, "unread", "un red")) == .none,
      "an entry being edited is not a duplicate of itself")

// edit a community entry -> the user's own entry with the same key; the community list is unchanged
var list = cat.settingUserEntry(e(.word, "tabindex", "tab dex"))
cat = DictionaryCatalog(community: community, user: list)
check(cat.isOverride(e(.word, "tabindex", "tab dex")) && cat.effective(kind: .word, word: "tabindex")?.replacement == "tab dex"
      && cat.communityEntry(kind: .word, word: "tabindex")?.replacement == "Tab Index",
      "editing a community entry keeps it as the user's own; the community one is untouched")
var rows = cat.rows(query: "tab", kind: nil)
check(rows.mine.map(\.word) == ["tabindex"] && rows.community.isEmpty,
      "the listing shows the user's version and hides the community one it replaces")
check(cat.duplicate(kind: .word, word: "tabindex") == .user(e(.word, "tabindex", "tab dex")),
      "after an edit, adding the word again points at the user's version")
list = cat.removingUserEntry(e(.word, "tabindex", "tab dex"))
cat = DictionaryCatalog(community: community, user: list)
rows = cat.rows(query: "tab", kind: nil)
check(cat.userEntry(kind: .word, word: "tabindex") == nil, "revert removes the user's entry")
check(rows.mine.isEmpty && rows.community.map(\.replacement) == ["Tab Index"], "after revert the community entry is listed again")

// rename one of the user's entries onto another key
list = cat.settingUserEntry(e(.word, "unreads", "un reds"), replacing: e(.word, "unread", "un red"))
check(list == [e(.word, "unreads", "un reds")], "renaming replaces the old entry rather than adding a second")

// listing: filters, order, kinds
cat = DictionaryCatalog(community: community, user: [e(.word, "zebra", "zee bra"), e(.word, "Apple", "ap pull")])
rows = cat.rows(query: "", kind: nil)
check(rows.mine.map(\.word) == ["Apple", "zebra"] && rows.community.count == 6, "everything listed, alphabetically in any case")
rows = cat.rows(query: "IOS", kind: .word)
check(rows.community.map(\.word) == ["IOS", "ios"] && rows.mine.isEmpty, "search in any case, one kind: IOS, ios")
rows = cat.rows(query: "world", kind: nil)
check(rows.community.map(\.word) == ["WWII"], "search also finds the pronunciation")

// MARK: - Validation

check(DictionaryValidation.problem(word: "unread", replacement: "un red", kind: .word) == nil, "a whole word may be respelled as several words")
check(DictionaryValidation.problem(word: "unread", replacement: "un red", kind: .root) != nil,
      "a word root may NOT (the engine ignores a root replacement with a space - measured)")
check(DictionaryValidation.problem(word: "unread", replacement: "`[.2Hn.1rEd]", kind: .root) == nil, "a root may be phonemes")
check(DictionaryValidation.problem(word: "two words", replacement: "x", kind: .word) != nil, "the word must be one word")
check(DictionaryValidation.problem(word: "", replacement: "x", kind: .word) != nil
      && DictionaryValidation.problem(word: "x", replacement: " ", kind: .word) != nil, "neither half may be empty")
check(DictionaryValidation.problem(word: "caf\u{e9}", replacement: "ka fay", kind: .word) == nil, "Western European letters are fine")
check(DictionaryValidation.problem(word: "\u{732b}", replacement: "neko", kind: .word) != nil, "a character with no Windows-1252 byte is refused")
check(DictionaryValidation.problem(word: "a", replacement: "x\ty", kind: .word) != nil, "no tabs in the pronunciation")

// MARK: - The update schedule (Shared/DictionarySchedule.swift)

let t0 = Date(timeIntervalSince1970: 1_790_000_000)
let hour: TimeInterval = 3600, day = 24 * hour
func due(_ f: DictionaryUpdateFrequency, _ ago: TimeInterval?, enabled: Bool = true, auto: Bool = true) -> Bool {
    DictionarySchedule.isDue(enabled: enabled, autoUpdate: auto, frequency: f,
                             lastCheck: ago.map { t0.addingTimeInterval(-$0) }, now: t0)
}
check(DictionaryUpdateFrequency.default == .monthly && DictionaryUpdateFrequency(stored: nil) == .monthly
      && DictionaryUpdateFrequency(stored: "hourly") == .monthly && DictionaryUpdateFrequency(stored: "weekly") == .weekly,
      "default Monthly; nothing or nonsense stored reads as Monthly")
check(!due(.daily, nil, auto: false) && !due(.daily, 400 * day, enabled: false), "never due with Update automatically or the dictionary off")
check(due(.monthly, nil) && due(.weekly, nil) && due(.daily, nil), "due when there has never been a check")
check(!due(.daily, 12 * hour) && due(.daily, 21 * hour) && due(.daily, 2 * day), "daily: not after 12 h, due after 21 h")
check(!due(.weekly, 2 * day) && !due(.weekly, 6 * day) && due(.weekly, 7 * day - 3 * hour) && due(.weekly, 8 * day),
      "weekly: not after 2 or 6 days, due from about 7")
check(!due(.monthly, 8 * day) && !due(.monthly, 29 * day) && due(.monthly, 30 * day - 3 * hour) && due(.monthly, 45 * day),
      "monthly: not after 8 or 29 days, due from about 30")
check(due(.monthly, -5 * day), "a last check in the future (clock moved back) does not block checks")
check(DictionaryUpdateFrequency.allCases.map(\.title) == ["Daily", "Weekly", "Monthly"], "the picker's three choices, in order")

// MARK: - Phoneme codes as a readable respelling (Shared/PhoneticRespelling.swift)

let respellCases: [(String, String)] = [
    ("`[.2e.1ra.0nXk]", "air-RAH-nihk"),               // aaronic, the one first heard as symbols
    ("`[.1Y.2fon]", "EYE-fohn"),                        // iphone
    ("`[.1Y.2mE.0sXJ]", "EYE-meh-sihj"),                // imessage
    ("`[.1zo.0X.2trop]", "ZOH-ih-trohp"),               // zoetrope
    ("`[.1fW.0stxs]", "FAU-stuhs"),                     // faustus: "fow" is read "foe"
    ("`[.1mId.2lYnz]", "MIHD-lighnz"),                  // midlines: "lynz" is read with a short i
    ("`[.2kyu.0ni.1A.0FXk]", "kew-nee-AT-tihk"),        // cuneatic: /ju/ after a consonant, open /ae/
    ("`[.1c.0Fi.0o.2bUks]", "AW-tee-oh-books"),         // audiobooks
    ("`[.0dw.1a.0mXS]", "DWAH-mihsh"),                   // a syllable with no vowel joins the next
    ("`[.2Ambli.1o.0pi.0x]", "amblee-OH-pee-uh"),       // two vowels in one syllable
    ("`[.1wEl.0kxm]", "WEHL-kuhm"),
]
for (code, want) in respellCases {
    let got = PhoneticRespelling.respell(code)
    check(got == want, "respell \(code) -> \(got ?? "nil") (want \(want))")
}
check(PhoneticRespelling.display("un red") == "un red", "a plain spelling is shown as it is")
check(PhoneticRespelling.display("sonic `[.0kx.1Cur]") == "sonic kuh-CHOOR", "words and a code together")
check(PhoneticRespelling.display("`[.1re.0ge] `1 `[.1Zcn]") == "RAY-gay ZHAWN", "other annotations (`1) are dropped")
check(PhoneticRespelling.display("`[.2du.1pH0Fx]") == "phonetic entry", "a malformed code falls back to \"phonetic entry\"")
check(PhoneticRespelling.display("`[.1q%]") == "phonetic entry" && PhoneticRespelling.display("`[.1ab") == "phonetic entry",
      "unknown symbols or an unclosed code fall back too")
check(PhoneticRespelling.spoken("`[.2e.1ra.0nXk]") == "air-rah-nihk, stress on rah",
      "for VoiceOver: all small (Eloquence spells short capitals) and the stress said: \(PhoneticRespelling.spoken("`[.2e.1ra.0nXk]"))")
check(!PhoneticRespelling.display("`[.1Y.2fon]").contains("`") && !PhoneticRespelling.display("`[.1Y.2fon]").contains("["),
      "no symbols ever shown")

// MARK: - Languages: each its own files and its own user folder

check(DictionaryKind.word.communityFile(prefix: "DEU") == "DEUmain.dic" && DictionaryKind.root.communityFile(prefix: "DEU") == "DEURoot.dic"
      && DictionaryKind.abbreviation.communityFile == "ENUabbr.dic", "community file names per language prefix")
let enusDir = DictionaryLocations.user(in: container, language: "enus")
let dedeDir = DictionaryLocations.user(in: container, language: "dede")
let engbDir = DictionaryLocations.user(in: container, language: "engb")
check(enusDir == DictionaryLocations.user(in: container), "US English keeps the folder its entries were always in")
check(Set([enusDir, dedeDir, engbDir].map(\.path)).count == 3
      && ![dedeDir, engbDir].contains { $0.path.hasPrefix(enusDir.path + "/") || $0.path.hasPrefix(communityDir.path + "/") },
      "every language's user folder is its own, inside neither another language's nor the community folder")
let de = UserDictionaryStore(directory: dedeDir)
try! de.save([e(.word, "Grüße", "Gruesse")])
check(UserDictionaryStore(directory: enusDir).load().allSatisfy { $0.word != "Grüße" } && de.load().count == 1,
      "a German entry stays German")

// MARK: - The Listen marker (the extension's side of Listen through VoiceOver)

let now = Date()
let mk = ListenMarker(id: "a1", language: "enus", word: "unread", communityOff: false, expires: now.addingTimeInterval(20))
check(ListenMarker.take(mk, language: "dede", requestText: "unread", now: now) == nil, "marker: another language's voice ignores it")
check(ListenMarker.take(mk, language: "enus", requestText: "unread.", now: now) == nil, "marker: the \"with\" word (full stop) does not match")
check(ListenMarker.take(mk, language: "enus", requestText: "now pronounced", now: now) == nil, "marker: other text does not match")
check(ListenMarker.take(mk, language: "enus", requestText: "unread", now: now.addingTimeInterval(21)) == nil, "marker: expired")
check(ListenMarker.take(mk, language: "enus", requestText: " Unread ", now: now) == mk, "marker: the word itself, any case, is said without the entry")
check(ListenMarker.take(mk, language: "enus", requestText: "unread", now: now) == nil, "marker: used once only")

try? fm.removeItem(at: tmp)
print("\(passes) ok, \(failures) failed")
exit(failures == 0 ? 0 : 1)

extension Data {
    /// The same text as Windows-1252 bytes (the tests write fixtures in UTF-8 source).
    func replacingCP1252() -> Data {
        String(decoding: self, as: UTF8.self).data(using: .windowsCP1252)!
    }
}
