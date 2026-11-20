// Mac test of the app group resolver (Shared/AppGroup.swift, the same file the iOS and Mac targets compile):
// a copy with no ALTAppGroups list (installed directly) keeps the group its entitlements name, exactly as every
// build before 0.1.1; a copy AltStore or SideStore re-signed uses the group they list, from the app's or the
// extension's own Info.plist, and the app and the extension agree. `make appgroup-test` (part of `make test`).
// The bundles are written to a temporary folder, from the project's own Info.plists, and removed.
//
// Given bundle paths as arguments, it also prints the group each one resolves to (add --ios for an iPhone build):
//   build/mac/appgroup_test "/Applications/ReLoq Apple.app" "/Applications/ReLoq Apple.app/Contents/PlugIns/X.appex"

import Foundation

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if ok { passes += 1 } else { failures += 1 }
}

let args = Array(CommandLine.arguments.dropFirst())
if !args.isEmpty {
    let ios = args.contains("--ios")
    for path in args where path != "--ios" {
        guard let b = Bundle(path: path) else { print("not a bundle: \(path)"); failures += 1; continue }
        let list = b.object(forInfoDictionaryKey: AppGroup.infoKey) as? [String]
        let g = AppGroup.resolve(bundles: [b], defaultID: ios ? AppGroup.iOSDefault : AppGroup.macDefault)
        print("\(path): ALTAppGroups=\(list.map { "\($0)" } ?? "none") -> \(g)")
    }
    exit(failures == 0 ? 0 : 1)
}

let ios = AppGroup.iOSDefault, mac = AppGroup.macDefault
let alt = ios + ".ABCDE12345"          // what AltStore makes of it: <group>.<the installing account's team ID>

// MARK: - The rule, given the lists

check(ios == "group.com.quinton.eloquencevoices" && mac == "ZGJQ5DZFK2.com.quinton.eloquencevoices",
      "the defaults are the groups the entitlements files name")
check(AppGroup.defaultID == mac, "this Mac build's default is the team-prefixed Mac group")
check(AppGroup.resolve(lists: [], defaultID: ios) == ios, "no bundles: the default (iPhone)")
check(AppGroup.resolve(lists: [nil, nil], defaultID: ios) == ios, "no ALTAppGroups anywhere: the default (iPhone)")
check(AppGroup.resolve(lists: [nil, nil], defaultID: mac) == mac, "no ALTAppGroups anywhere: the default (Mac)")
check(AppGroup.resolve(lists: [[alt], nil], defaultID: ios) == alt, "AltStore's list: its group")
check(AppGroup.resolve(lists: [["group.someone.else", alt]], defaultID: ios) == alt,
      "several groups: the one that starts with ours, wherever it is in the list")
check(AppGroup.resolve(lists: [["group.someone.else"]], defaultID: ios) == "group.someone.else",
      "none starts with ours: the list's first entry")
check(AppGroup.resolve(lists: [nil, [alt]], defaultID: ios) == alt, "no list in the main bundle: the code's bundle's")
check(AppGroup.resolve(lists: [[], [alt]], defaultID: ios) == alt, "an empty list counts as none")
check(AppGroup.resolve(lists: [[""], nil], defaultID: ios) == ios, "a list of one empty name counts as none")
check(AppGroup.resolve(lists: [[ios + ".AAAAAAAAAA"], [ios + ".BBBBBBBBBB"]], defaultID: ios) == ios + ".AAAAAAAAAA",
      "the process's own bundle comes first")
check(AppGroup.resolve(lists: [[mac + ".X"]], defaultID: mac) == mac + ".X", "a list on a Mac build is honoured too")

// MARK: - This process: a command-line tool, no Info.plist, so no list

check(AppGroup.id == mac, "AppGroup.id in a bundle with no ALTAppGroups is the default: \(AppGroup.id)")

// MARK: - Real Info.plists: the project's own, as installed directly and as AltStore rewrites them

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)   // make runs it from the project
guard fm.fileExists(atPath: root.appendingPathComponent("App/Info.plist").path) else {
    print("FAIL run from the project folder (make appgroup-test)"); exit(1)
}
let tmp = fm.temporaryDirectory.appendingPathComponent("ev-appgroup-test-\(getpid())", isDirectory: true)
try? fm.removeItem(at: tmp)
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)

/// A bundle folder holding a copy of `plist` (iPhone layout: Info.plist at the top; Mac: in Contents/), with
/// `groups` added under ALTAppGroups the way AltStore writes them (ResignAppOperation: the whole Info dictionary
/// written back as a property list), or untouched when nil.
func makeBundle(_ name: String, from plist: String, mac: Bool, groups: [String]?) -> Bundle {
    let dir = tmp.appendingPathComponent(name, isDirectory: true)
    let infoDir = mac ? dir.appendingPathComponent("Contents", isDirectory: true) : dir
    try! fm.createDirectory(at: infoDir, withIntermediateDirectories: true)
    let dst = infoDir.appendingPathComponent("Info.plist")
    var info = NSDictionary(contentsOf: root.appendingPathComponent(plist)) as! [String: Any]
    if let groups { info[AppGroup.infoKey] = groups }
    try! (info as NSDictionary).write(to: dst)
    return Bundle(url: dir)!
}

for (label, appPlist, extPlist, mac, def) in [("iPhone", "App/Info.plist", "Extension/Info.plist", false, ios),
                                              ("Mac", "App/Info-macOS.plist", "Extension/Info-macOS.plist", true, mac)] {
    let app = makeBundle("\(label)-direct.app", from: appPlist, mac: mac, groups: nil)
    let ext = makeBundle("\(label)-direct.appex", from: extPlist, mac: mac, groups: nil)
    check(app.object(forInfoDictionaryKey: "CFBundleDisplayName") != nil
          && app.object(forInfoDictionaryKey: AppGroup.infoKey) == nil,
          "\(label): the project's Info.plists read back, with no ALTAppGroups")
    check(AppGroup.resolve(bundles: [app], defaultID: def) == def
          && AppGroup.resolve(bundles: [ext], defaultID: def) == def,
          "\(label), installed directly: the app and the extension both use \(def), as before")

    let rApp = makeBundle("\(label)-altstore.app", from: appPlist, mac: mac, groups: [alt])
    let rExt = makeBundle("\(label)-altstore.appex", from: extPlist, mac: mac, groups: [alt])
    let gApp = AppGroup.resolve(bundles: [rApp], defaultID: def), gExt = AppGroup.resolve(bundles: [rExt], defaultID: def)
    check(gApp == alt && gExt == alt, "\(label), re-signed by AltStore: the app and the extension both use \(alt)")
    // the extension process: Bundle.main is the extension; the code's own bundle is the extension too
    check(AppGroup.resolve(bundles: [rExt, rExt], defaultID: def) == gApp,
          "\(label), re-signed: the extension's process agrees with the app's")
    // the engine framework is not prepared by AltStore (no list of its own): it must not change the answer
    let fw = makeBundle("\(label)-EloquenceEngine.framework", from: extPlist, mac: mac, groups: nil)
    check(AppGroup.resolve(bundles: [rApp, fw], defaultID: def) == alt && AppGroup.resolve(bundles: [fw], defaultID: def) == def,
          "\(label): a bundle with no list (the engine framework) neither overrides nor invents a group")
}

try? fm.removeItem(at: tmp)
print("\(passes) ok, \(failures) failed")
exit(failures == 0 ? 0 : 1)
