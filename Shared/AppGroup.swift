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
//  A copy re-signed by AltStore or SideStore is granted a DIFFERENT group: the installing account's team ID is
//  appended (group.com.quinton.eloquencevoices.<TEAM ID>), and the new identifiers are written into the Info.plist
//  of the app and of each extension under ALTAppGroups (AltStore's FetchProvisioningProfilesOperation and
//  ResignAppOperation; frameworks are not touched). With the group hard-coded, as in 0.1, such a copy could not
//  open the container (the community dictionary download said "storage unavailable"), and UserDefaults(suiteName:)
//  quietly gave each process a private file of its own, so the settings never reached the voices.
//
//  So the group is: from the ALTAppGroups list of this process's own bundle (the app's, or the extension's) or of
//  the bundle this code is compiled into, the entry that starts with our group, else the list's first entry; with
//  no list, our own group, exactly what every build before 0.1.1 used. Pure Foundation, no bridge, so
//  `make appgroup-test` compiles this file as the targets do.
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

    /// The group this process uses. Resolved once: a bundle's Info.plist does not change while it runs.
    static let id: String = resolve(bundles: [Bundle.main, Bundle(for: Marker.self)])

    /// The group's container, nil when it cannot be opened.
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    /// The group's defaults (nil only for a name UserDefaults refuses).
    static func makeDefaults() -> UserDefaults? { UserDefaults(suiteName: id) }

    /// The group named by the first of these bundles that carries an ALTAppGroups list, else `defaultID`.
    static func resolve(bundles: [Bundle], defaultID: String = defaultID) -> String {
        resolve(lists: bundles.map { $0.object(forInfoDictionaryKey: infoKey) as? [String] }, defaultID: defaultID)
    }

    /// The same, given the lists themselves (nil = that bundle has none).
    static func resolve(lists: [[String]?], defaultID: String = defaultID) -> String {
        for list in lists {
            let groups = (list ?? []).filter { !$0.isEmpty }
            if let g = groups.first(where: { $0.hasPrefix(iOSDefault) || $0.hasPrefix(defaultID) }) ?? groups.first {
                return g
            }
        }
        return defaultID
    }

    private final class Marker {}
}
