//
//  ListenMarker.swift
//  The dictionary editor's Listen through VoiceOver: the app wants VoiceOver - that is, this app's
//  extension, when an Eloquence voice is VoiceOver's voice - to say a word once WITHOUT one dictionary
//  entry ("the original"), then "now pronounced", then the word with it. It leaves this marker in the app
//  group (PronunciationDictionary.swift posts and reads it); the extension applies it to the first
//  request, within its lifetime, whose whole text is the word, and never again for the same id. The app
//  sends the "with" word with a full stop after it, so that one never matches even if the extension was
//  restarted in between. Pure logic here, so `make userdict-test` compiles it as it is.
//

import Foundation

struct ListenMarker: Codable, Equatable {
    var id: String
    var language: String          // EloquenceLanguage.code
    var word: String
    var communityOff: Bool        // a community entry: "without" = no community dictionary for the utterance
    var expires: Date

    static let key = "listen.marker"
    private static var used = Set<String>()
    private static let lock = NSLock()

    /// The decision alone: same language, not expired, not used, and the request's whole text is the
    /// word (any case). Marks the marker used when it answers it.
    static func take(_ m: ListenMarker, language: String, requestText: String, now: Date) -> ListenMarker? {
        guard m.language == language, now < m.expires,
              requestText.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(m.word) == .orderedSame
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        if used.contains(m.id) { return nil }
        used.insert(m.id)
        return m
    }
}
