//
//  AppGroup.swift
//  The app group the app and its speech extension share: the settings in its defaults, the community dictionary
//  and the user's own entries in its container. Every use goes through `AppGroup.id`, resolved once per process,
//  so the app and the extension always agree. Ported from Sapple (Shared/SingingMode.swift, `groupID`).
//
//  A copy installed directly (Xcode, the notarized Mac zip, a developer-signed IPA) has the group its entitlements
//  name: group.com.quinton.eloquencevoices on iPhone and iPad, ZGJQ5DZFK2.com.quinton.eloquencevoices on the Mac
//  (a Mac group must start with the team ID: then a Developer ID app needs no provisioning profile for it).
//  ClassicVoices measured on the phone that the extension can READ the group but not write to it - reading is all
//  the extension needs.
//
//  A copy re-signed by someone else is granted a DIFFERENT group, one their own team owns. AltStore and SideStore
//  append the installing account's team ID (group.com.quinton.eloquencevoices.<TEAM ID>) and write the new
//  identifiers into the Info.plist of the app and of each extension under ALTAppGroups (AltStore's
//  FetchProvisioningProfilesOperation and ResignAppOperation; frameworks are not touched). Other re-signers
//  (Sideloadly, Signulous, ...) and anyone building their own IPA under another team write no such list: the only
//  record of the group the copy was given is the provisioning profile embedded in each signed bundle
//  (embedded.mobileprovision, a CMS-signed property list whose Entitlements name the application groups). With the
//  group hard-coded, such a copy cannot open the container (the community dictionary download says "storage
//  unavailable"), and UserDefaults(suiteName:) quietly gives each process a private file of its own, so the
//  settings never reach the voices ("Settings can't be shared with the voices.").
//
//  So the group is, in this order:
//   1. ALTAppGroups, from this process's own bundle (the app's, or the extension's) or the bundle this code is
//      compiled into: the entry that starts with our group, else the list's first entry (as 0.1.1).
//   2. iPhone and iPad only: the application groups of the embedded provisioning profiles. The app and the
//      extension each read the SAME files - the app's profile and every extension's in its PlugIns folder, found
//      from either process - and keep the groups ALL of them grant (each process can be granted only what its own
//      profile lists, and a group is shared only if both have it). Those are ordered the same way in both
//      processes: our group itself, then names that start with it, then the rest, alphabetically within each.
//      The first whose container opens wins; if none opens, the first. If a profile cannot be read, the others
//      still decide; if the profiles share no group, this process's own profile's groups are used.
//   3. Our own group, exactly what every build before 0.1.1 used.
//  The Mac does not look at profiles: a Developer ID copy has none, and its group is the default as before.
//  Pure Foundation, no bridge, so `make appgroup-test` compiles this file as the targets do.
//

import Foundation

enum AppGroup {
    /// The group as the entitlements files name it: iPhone and iPad (App.entitlements, Ext.entitlements) and Mac
    /// (App-macOS.entitlements, Ext-macOS.entitlements).
    static let iOSDefault = "group.com.quinton.eloquencevoices"
    static let macDefault = "ZGJQ5DZFK2.com.quinton.eloquencevoices"
#if os(macOS)
    static let defaultID = macDefault
#else
    static let defaultID = iOSDefault
#endif

    /// The Info.plist key AltStore and SideStore list a re-signed copy's groups under.
    static let infoKey = "ALTAppGroups"
    /// The provisioning profile inside a signed iPhone bundle, and the entitlement naming its groups.
    static let profileName = "embedded.mobileprovision"
    static let groupsEntitlement = "com.apple.security.application-groups"

    /// The group this process uses. Resolved once: a bundle's Info.plist and profile do not change while it runs.
    static let id: String = {
        let bundles = [Bundle.main, Bundle(for: Marker.self)]
#if os(macOS)
        return resolve(bundles: bundles)
#else
        return resolve(bundles: bundles, profiles: profileGroups(around: Bundle.main.bundleURL),
                       opens: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil })
#endif
    }()

    /// The group's container, nil when it cannot be opened.
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    /// The group's defaults (nil only for a name UserDefaults refuses).
    static func makeDefaults() -> UserDefaults? { UserDefaults(suiteName: id) }

    /// The group named by the first of these bundles that carries an ALTAppGroups list; else the profiles' choice
    /// (`profiles`: the groups of each profile found, the process's own first; `opens`: whether a group's container
    /// opens in this process); else `defaultID`.
    static func resolve(bundles: [Bundle], profiles: ProfileGroups = .none, opens: ((String) -> Bool)? = nil,
                        defaultID: String = defaultID) -> String {
        resolve(lists: bundles.map { $0.object(forInfoDictionaryKey: infoKey) as? [String] },
                profiles: profiles, opens: opens, defaultID: defaultID)
    }

    /// The same, given the ALTAppGroups lists themselves (nil = that bundle has none).
    static func resolve(lists: [[String]?], profiles: ProfileGroups = .none, opens: ((String) -> Bool)? = nil,
                        defaultID: String = defaultID) -> String {
        for list in lists {
            let groups = (list ?? []).filter { !$0.isEmpty }
            if let g = groups.first(where: { $0.hasPrefix(iOSDefault) || $0.hasPrefix(defaultID) }) ?? groups.first {
                return g
            }
        }
        let candidates = profileCandidates(profiles, defaultID: defaultID)
        if let opens, let g = candidates.first(where: opens) { return g }
        return candidates.first ?? defaultID
    }

    // MARK: - Provisioning profiles

    /// What the profiles say: `own` = this process's own bundle's profile (nil = none or unreadable); `all` = every
    /// profile found in the app (the app's and each extension's, the same set from either process; unreadable ones
    /// left out).
    struct ProfileGroups {
        var own: [String]?
        var all: [[String]]
        static let none = ProfileGroups(own: nil, all: [])
    }

    /// The groups to try, in the order both processes use: those every profile grants (else this process's own),
    /// our group first, then names starting with it, then the rest, alphabetically within each.
    static func profileCandidates(_ p: ProfileGroups, defaultID: String = defaultID) -> [String] {
        let clean: ([String]) -> Set<String> = { Set($0.filter { !$0.isEmpty && !$0.contains("*") }) }
        var shared: Set<String>? = nil
        for groups in p.all { shared = shared.map { $0.intersection(clean(groups)) } ?? clean(groups) }
        var pool = shared ?? []
        if pool.isEmpty, let own = p.own { pool = clean(own) }
        func rank(_ g: String) -> Int {
            if g == iOSDefault || g == defaultID { return 0 }
            if g.hasPrefix(iOSDefault) || g.hasPrefix(defaultID) { return 1 }
            return 2
        }
        return pool.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// The application groups a provisioning profile grants: the property list inside the CMS envelope (from
    /// `<?xml` to `</plist>`), Entitlements -> com.apple.security.application-groups. nil = not a profile, or no
    /// such entitlement.
    static func groups(inProfile data: Data) -> [String]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                      options: [], format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any] else { return nil }
        if let list = ents[groupsEntitlement] as? [String] { return list }
        if let one = ents[groupsEntitlement] as? String { return [one] }
        return nil
    }

    /// The profiles of the app that contains `bundleURL` (an .app, or an .appex inside one): the app's own
    /// embedded.mobileprovision and each PlugIns/*.appex's, so the app and its extension read the same files.
    static func profileGroups(around bundleURL: URL) -> ProfileGroups {
        let fm = FileManager.default
        let own = bundleURL.standardizedFileURL
        let isExt = own.pathExtension == "appex"
        let app = isExt && own.deletingLastPathComponent().lastPathComponent == "PlugIns"
            ? own.deletingLastPathComponent().deletingLastPathComponent() : own
        var bundles = [app]
        let plugIns = app.appendingPathComponent("PlugIns", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) {
            bundles += items.filter { $0.pathExtension == "appex" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        if !bundles.contains(where: { $0.standardizedFileURL.path == own.path }) { bundles.append(own) }
        func read(_ b: URL) -> [String]? {
            (try? Data(contentsOf: b.appendingPathComponent(profileName))).flatMap(groups(inProfile:))
        }
        return ProfileGroups(own: read(own), all: bundles.compactMap(read))
    }

    private final class Marker {}
}
