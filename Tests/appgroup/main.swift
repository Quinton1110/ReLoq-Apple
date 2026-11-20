// Mac test of the app group resolver (Shared/AppGroup.swift, the same file the iOS and Mac targets compile):
// a copy with no ALTAppGroups list (installed directly) keeps the group its entitlements name, exactly as every
// build before 0.1.1; a copy AltStore or SideStore re-signed uses the group they list, from the app's or the
// extension's own Info.plist, and the app and the extension agree; a copy re-signed by anyone else (Sideloadly,
// Signulous, a self-built IPA under another team) uses the group its embedded provisioning profiles grant, and the
// app and the extension agree on it too. `make appgroup-test` (part of `make test`).
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
        // --ios: as an iPhone process resolves it (profiles read; no container check, this is not that process)
        let profiles = ios ? AppGroup.profileGroups(around: b.bundleURL) : .none
        let g = AppGroup.resolve(bundles: [b], profiles: profiles, defaultID: ios ? AppGroup.iOSDefault : AppGroup.macDefault)
        print("\(path): ALTAppGroups=\(list.map { "\($0)" } ?? "none") profile=\(profiles.own.map { "\($0)" } ?? "none")"
              + " allProfiles=\(profiles.all) -> \(g)")
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

// MARK: - The rule, given what the provisioning profiles grant

let side = ios + ".XYZ9876543"         // a team-suffixed group, as Sideloadly-style re-signers make it
let own = "group.org.example.reloq"    // someone building their own IPA under their own team and group
func P(own o: [String]?, _ all: [[String]]) -> AppGroup.ProfileGroups { AppGroup.ProfileGroups(own: o, all: all) }
check(AppGroup.resolve(lists: [nil, nil], profiles: P(own: [side], [[side], [side]]), defaultID: ios) == side,
      "no ALTAppGroups, profiles grant a team-suffixed group: that group, not the default")
check(AppGroup.resolve(lists: [nil], profiles: P(own: [own], [[own], [own]]), defaultID: ios) == own,
      "a self-built copy's own group name: that group")
check(AppGroup.resolve(lists: [[alt]], profiles: P(own: [side], [[side]]), defaultID: ios) == alt,
      "ALTAppGroups still comes first, whatever the profile says")
check(AppGroup.resolve(lists: [nil], profiles: P(own: [ios], [[ios], [ios]]), defaultID: ios) == ios,
      "a direct install's profile names our group: our group, as before")
check(AppGroup.resolve(lists: [nil], profiles: P(own: [own, ios, side], [[own, ios, side]]), defaultID: ios) == ios
      && AppGroup.resolve(lists: [nil], profiles: P(own: [own, side], [[own, side]]), defaultID: ios) == side,
      "several groups: ours, then one starting with ours, then the rest")
check(AppGroup.resolve(lists: [nil], profiles: P(own: ["group.b", "group.a"], [["group.b", "group.a"]]), defaultID: ios) == "group.a",
      "several unrelated groups: the first alphabetically, in either order")
check(AppGroup.profileCandidates(P(own: [own, side], [[own, side], [side]])) == [side]
      && AppGroup.profileCandidates(P(own: [side], [[own, side], [side]])) == [side],
      "the app's profile grants more than the extension's: both processes keep only the group both have")
check(AppGroup.resolve(lists: [nil], profiles: P(own: [side], [[own], [side]]), defaultID: ios) == side,
      "profiles that share no group: this process's own profile's group")
check(AppGroup.resolve(lists: [nil], profiles: P(own: [own, side], [[own, side]]), opens: { $0 == own }, defaultID: ios) == own,
      "the first candidate whose container opens wins")
check(AppGroup.resolve(lists: [nil], profiles: P(own: [own, side], [[own, side]]), opens: { _ in false }, defaultID: ios) == side,
      "no container opens: still the first candidate (the same answer in both processes)")
check(AppGroup.resolve(lists: [nil], profiles: P(own: ["*", ""], [["*", ""]]), defaultID: ios) == ios,
      "wildcards and empty names are not groups: the default")
check(AppGroup.resolve(lists: [nil, nil], profiles: .none, defaultID: ios) == ios
      && AppGroup.resolve(lists: [nil, nil], profiles: P(own: nil, []), defaultID: mac) == mac,
      "no profile: the default (iPhone and Mac)")

// MARK: - Reading a provisioning profile

/// An embedded.mobileprovision as a re-signer writes it: the property list inside a CMS (DER) envelope. The bytes
/// around it stand in for the envelope; the resolver only looks between `<?xml` and `</plist>`.
func profileData(groups: [String]?, team: String = "XYZ9876543") -> Data {
    var ents: [String: Any] = ["application-identifier": "\(team).com.quinton.eloquencevoices",
                               "com.apple.developer.team-identifier": team, "get-task-allow": true]
    if let groups { ents[AppGroup.groupsEntitlement] = groups }
    let plist: [String: Any] = ["Name": "fixture", "TeamIdentifier": [team], "Entitlements": ents,
                                "ExpirationDate": Date(timeIntervalSince1970: 2_000_000_000)]
    let xml = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return Data([0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02, 0xa0, 0x80, 0x30, 0x80])
        + xml + Data([0x00, 0x00, 0xa0, 0x82, 0x0a, 0x3c, 0x30, 0x82, 0x06, 0x00, 0x3c, 0x3f, 0x78, 0x00])
}
check(AppGroup.groups(inProfile: profileData(groups: [side])) == [side], "a profile's application groups are read from inside its envelope")
check(AppGroup.groups(inProfile: profileData(groups: nil)) == nil, "a profile with no application-groups entitlement: none")
check(AppGroup.groups(inProfile: Data("not a profile".utf8)) == nil && AppGroup.groups(inProfile: Data()) == nil,
      "something that is not a profile: none")

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

// MARK: - iPhone bundles laid out as installed: App.app/embedded.mobileprovision and
// App.app/PlugIns/EloquenceVoicesExtension.appex/embedded.mobileprovision, resolved as each process does it
// (Bundle.main = the app, or the extension; the profiles found from there).

/// An iPhone app with its extension inside, each with an optional ALTAppGroups list and an optional profile
/// granting `appProfile` / `extProfile` (nil = no profile file). Returns (app, extension).
func makeIPhoneInstall(_ name: String, alt altGroups: [String]?, appProfile: [String]?, extProfile: [String]?) -> (Bundle, Bundle) {
    let app = makeBundle("\(name)/ReLoq.app", from: "App/Info.plist", mac: false, groups: altGroups)
    let ext = makeBundle("\(name)/ReLoq.app/PlugIns/EloquenceVoicesExtension.appex", from: "Extension/Info.plist", mac: false,
                         groups: altGroups)
    if let appProfile { try! profileData(groups: appProfile).write(to: app.bundleURL.appendingPathComponent(AppGroup.profileName)) }
    if let extProfile { try! profileData(groups: extProfile).write(to: ext.bundleURL.appendingPathComponent(AppGroup.profileName)) }
    return (Bundle(url: app.bundleURL)!, Bundle(url: ext.bundleURL)!)
}
func asProcess(_ b: Bundle, opens: ((String) -> Bool)? = nil) -> String {
    AppGroup.resolve(bundles: [b, b], profiles: AppGroup.profileGroups(around: b.bundleURL), opens: opens, defaultID: ios)
}

for (label, altGroups, appProfile, extProfile, want) in [
    ("AltStore-style (ALTAppGroups + a team-suffixed profile)", [alt] as [String]?, [alt] as [String]?, [alt] as [String]?, alt),
    ("Sideloadly-style (team-suffixed group in the profiles, no ALTAppGroups)", nil, [side], [side], side),
    ("self-built IPA (its own group name, no ALTAppGroups)", nil, [own], [own], own),
    ("no profile, no ALTAppGroups", nil, nil, nil, ios),
    ("a direct install (our own group in the profiles)", nil, [ios], [ios], ios),
    ("the app granted one group more than the extension", nil, [own, side], [side], side),
] {
    let tag = label.prefix(while: { $0 != " " })
    let (app, ext) = makeIPhoneInstall("iphone-\(tag)-\(passes)", alt: altGroups, appProfile: appProfile, extProfile: extProfile)
    let gApp = asProcess(app), gExt = asProcess(ext)
    check(gApp == want && gExt == want, "iPhone, \(label): the app (\(gApp)) and the extension (\(gExt)) both use \(want)")
}
do {   // as the real process does it: only the granted group's container opens
    let (app, ext) = makeIPhoneInstall("iphone-opens", alt: nil, appProfile: [own, side], extProfile: [own, side])
    let gApp = asProcess(app, opens: { $0 == own }), gExt = asProcess(ext, opens: { $0 == own })
    check(gApp == own && gExt == own, "iPhone, two granted groups, only one container opens: both use it (\(gApp), \(gExt))")
}
do {   // the extension cannot read the app's profile (removed): the extension's own still decides, the same way
    let (app, ext) = makeIPhoneInstall("iphone-unreadable", alt: nil, appProfile: nil, extProfile: [side])
    check(asProcess(ext) == side && asProcess(app) == side,
          "iPhone, only the extension's profile readable: both processes still use \(side)")
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
