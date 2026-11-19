//
//  DictionaryEditorView.swift
//  "Dictionary entries": every entry of the downloaded community dictionary (whole words, word roots,
//  abbreviations - about 70,000), searchable, and the user's own entries. Any community entry can be
//  edited (kept as the user's own entry with the same word; the downloaded files are never changed) and
//  reverted; new words can be added and the user's own deleted. The user's entries live in their own
//  files (Shared/UserDictionary.swift), which updates never touch, and they win over the community ones.
//
//  VoiceOver: plain List rows, one element each, read as "word, X" (the pronunciation) with the kind
//  (+ "edited" for a changed community entry) as the value; delete / revert are also rotor actions. The
//  editor is a Form. Status changes (saved, deleted, a problem) are announced.
//

import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

@MainActor
final class DictionaryEditorModel: ObservableObject {
    @Published private(set) var catalog = DictionaryCatalog(community: [], user: [])
    @Published private(set) var isLoading = true
    @Published private(set) var mine: [DictionaryEntry] = []
    @Published private(set) var community: [DictionaryEntry] = []
    @Published var query = "" { didSet { scheduleFilter() } }
    @Published var kindFilter: DictionaryKind? = nil { didSet { scheduleFilter() } }
    @Published private(set) var communityInstalled = false
    /// The language whose dictionaries are listed: each has its own community files (if the project has
    /// any) and the user's own entries in a folder of its own.
    @Published private(set) var language: EloquenceLanguage = ELOQUENCE_US_ENGLISH

    private var store: UserDictionaryStore? { PronunciationDictionary.userStore(for: language) }
    private var filterTask: Task<Void, Never>?

    func setLanguage(_ lang: EloquenceLanguage) {
        guard lang != language || isLoading else { return }
        language = lang
        catalog = DictionaryCatalog(community: [], user: [])
        mine = []; community = []
        load()
    }

    /// A replacement as the list shows it: US English phoneme codes as a readable respelling; another
    /// language's codes (its own phoneme set, not converted) as "phonetic entry"; words as they are.
    func shown(_ r: String) -> String {
        language == ELOQUENCE_US_ENGLISH ? PhoneticRespelling.display(r)
            : (PhoneticRespelling.isPhonetic(r) ? "phonetic entry" : r)
    }

    func spoken(_ r: String) -> String {
        language == ELOQUENCE_US_ENGLISH ? PhoneticRespelling.spoken(r)
            : (PhoneticRespelling.isPhonetic(r) ? "phonetic entry" : r)
    }

    /// The voice of this language with the same preset as the one selected on the main screen.
    func voice(like v: EloquenceVoiceDef) -> EloquenceVoiceDef {
        VoiceCatalog.voices(for: language).first { $0.preset == v.preset } ?? v
    }

    func load() {
        isLoading = true
        let userStore = store
        let lang = language
        Task.detached(priority: .userInitiated) {
            let theirs = PronunciationDictionary.communityEntries(for: lang)
            let user = userStore?.load() ?? []
            let catalog = DictionaryCatalog(community: theirs, user: user)
            await MainActor.run {
                guard self.language == lang else { return }
                self.catalog = catalog
                self.communityInstalled = !theirs.isEmpty
                self.isLoading = false
                self.scheduleFilter(immediately: true)
            }
        }
    }

    private func scheduleFilter(immediately: Bool = false) {
        filterTask?.cancel()
        let catalog = self.catalog, q = query, k = kindFilter
        filterTask = Task.detached(priority: .userInitiated) {
            if !immediately { try? await Task.sleep(nanoseconds: 250_000_000) }
            if Task.isCancelled { return }
            let rows = catalog.rows(query: q, kind: k)
            if Task.isCancelled { return }
            await MainActor.run {
                self.mine = rows.mine
                self.community = rows.community
            }
        }
    }

    /// Saves the user's list; nil when it worked, otherwise a sentence for the user.
    private func save(_ list: [DictionaryEntry]) -> String? {
        guard let store else { return "Couldn't save: storage unavailable." }
        do {
            try store.save(list)
        } catch {
            return "Could not save: \(error.localizedDescription)"
        }
        catalog = DictionaryCatalog(community: catalog.community, user: store.load())
        scheduleFilter(immediately: true)
        return nil
    }

    func set(_ entry: DictionaryEntry, replacing old: DictionaryEntry?) -> String? {
        save(catalog.settingUserEntry(entry, replacing: old))
    }

    func remove(_ entry: DictionaryEntry) -> String? {
        save(catalog.removingUserEntry(entry))
    }

    /// Speaks `word` with the user's entries as they would be with `draft` saved (and the community
    /// dictionary as its switch says), in this app process only: the draft goes into a temporary copy of
    /// the user's files, and the real ones are put back in force afterwards. Nothing is saved.
    func listen(word: String, draft: DictionaryEntry?, replacing old: DictionaryEntry?,
                voice: EloquenceVoiceDef, settings: VoiceSettings, completion: @escaping ([Int16]?) -> Void) {
        var list = catalog.user
        if let draft { list = catalog.settingUserEntry(draft, replacing: old) }
        let voice = self.voice(like: voice)
        let settings = VoiceSettingsStore.shared.settings(for: voice)
        let lang = language
        let request = EloquenceEngine.request(settings: settings, speedFactor: 1.0, sampleRate: OutputSampleRate.native)
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-preview-\(UUID().uuidString)", isDirectory: true)
            let temp = UserDictionaryStore(directory: tmp)
            PronunciationDictionary.configureEngine(language: lang)    // the community files as the switch says
            if (try? temp.save(list)) != nil {
                let p = temp.bridgePaths
                ev_dict_configure_user_lang(lang.eci, p[0], p[1], p[2])
            }
            let samples = EloquenceEngine.shared.synthesize(text: word, voice: voice, request: request)
            PronunciationDictionary.configureEngine()                  // the real user files again
            try? FileManager.default.removeItem(at: tmp)
            DispatchQueue.main.async { completion(samples) }
        }
    }

    private var rowPlayer: AVAudioPlayer?

    /// The row's "Listen": the word as it is said WITHOUT this entry, then "now pronounced", then the word
    /// WITH it - in the app's own Eloquence, with the voice and settings selected on the main screen.
    /// "Without": for the user's own entry (added, or a change to a community one) the user's list less
    /// this entry, with the community dictionary - so a change is heard against the community version,
    /// or the plain engine where there is none; for a community entry, the plain engine (no community
    /// dictionary, the user's own entries still in force). "With": the community dictionary and the
    /// user's whole list - whatever the switch says, so the entry is heard even while it is off.
    ///
    /// With VoiceOver running (it should be what says the Listen action) the
    /// three are VoiceOver announcements instead, queued one after another, so the user's own VoiceOver voice,
    /// rate and settings say them. When that voice is one of these voices it applies the user's
    /// dictionary to everything, so the app first leaves a ListenMarker in the app group: the extension
    /// says the first announcement - exactly the word - WITHOUT the entry, once; the last is the word
    /// with a full stop, which never matches, so it is said with the entry. If the VoiceOver voice is not
    /// an Eloquence voice of this language, all three are said by that voice and the marker does nothing.
    func listenComparison(_ e: DictionaryEntry, mine: Bool, voice: EloquenceVoiceDef, settings: VoiceSettings,
                          done: @escaping (String?) -> Void) {
#if os(iOS)
        // macOS: always the in-app comparison below.
        if UIAccessibility.isVoiceOverRunning {
            ListenMarker.post(ListenMarker(id: UUID().uuidString, language: language.code, word: e.word,
                                           communityOff: !mine, expires: Date().addingTimeInterval(20)))
            let tag = language.bcp47
            func say(_ text: String, inLanguage: Bool) {
                var attrs: [NSAttributedString.Key: Any] = [.accessibilitySpeechQueueAnnouncement: true]
                if inLanguage { attrs[.accessibilitySpeechLanguage] = tag }
                UIAccessibility.post(notification: .announcement, argument: NSAttributedString(string: text, attributes: attrs))
            }
            say(e.word, inLanguage: true)
            say("now pronounced", inLanguage: false)
            say(e.word + ".", inLanguage: true)
            done(nil)
            return
        }
#endif
        let voice = self.voice(like: voice)
        let settings = VoiceSettingsStore.shared.settings(for: voice)
        let lang = language
        let without = catalog.removingUserEntry(e)
        let with = catalog.user
        let request = EloquenceEngine.request(settings: settings, speedFactor: 1.0, sampleRate: OutputSampleRate.native)
        let word = e.word
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent("dictionary-listen-\(UUID().uuidString)", isDirectory: true)
            let a = UserDictionaryStore(directory: base.appendingPathComponent("without"))
            let b = UserDictionaryStore(directory: base.appendingPathComponent("with"))
            try? a.save(without)
            try? b.save(with)
            let engine = EloquenceEngine.shared
            PronunciationDictionary.configureEngineForPreview(language: lang, community: mine, userPaths: a.bridgePaths)
            let before = engine.synthesize(text: word, voice: voice, request: request)
            // "now pronounced" in English, whatever the entry's language: it is the app's own phrase
            let english = VoiceCatalog.voices(for: ELOQUENCE_US_ENGLISH).first { $0.preset == voice.preset } ?? voice
            let link = engine.synthesize(text: "now pronounced", voice: english,
                                         request: EloquenceEngine.request(settings: VoiceSettingsStore.shared.settings(for: english),
                                                                          speedFactor: 1.0, sampleRate: OutputSampleRate.native))
            PronunciationDictionary.configureEngineForPreview(language: lang, community: true, userPaths: b.bridgePaths)
            let after = engine.synthesize(text: word, voice: voice, request: request)
            PronunciationDictionary.configureEngine()                  // the real configuration again
            try? fm.removeItem(at: base)
            DispatchQueue.main.async {
                guard let before, let link, let after, !before.isEmpty, !after.isEmpty else {
                    done("Could not speak \(word).")
                    return
                }
                let gap = [Int16](repeating: 0, count: Int(0.25 * Double(OutputSampleRate.native)))
                let all = before + gap + link + gap + after
                do {
                    try Playback.activate()
                    self.rowPlayer?.stop()
                    let p = try AVAudioPlayer(data: WAVFile.data(all, sampleRate: OutputSampleRate.native))
                    p.prepareToPlay()
                    p.play()
                    self.rowPlayer = p
                    done(nil)
                } catch {
                    done("Playback error: \(error.localizedDescription)")
                }
            }
        }
    }
}

struct DictionaryEditorView: View {
    /// The voice and settings the app's screen has selected, for Listen.
    let voice: EloquenceVoiceDef
    let settings: VoiceSettings

    @StateObject private var model = DictionaryEditorModel()
    @State private var editing: EditorTarget?
    @State private var status = ""

    var body: some View {
        List {
            Section {
                Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(ELOQUENCE_LANGUAGES) { l in Text(l.name).tag(l) }
                }
                Picker("Show", selection: $model.kindFilter) {
                    Text("All kinds").tag(DictionaryKind?.none)
                    ForEach(DictionaryKind.allCases) { k in
                        Text(k.title + "s").tag(DictionaryKind?.some(k))
                    }
                }
                Button {
                    editing = .add(prefill: model.query.trimmingCharacters(in: .whitespaces))
                } label: {
                    Label("Add a word", systemImage: "plus.circle")
                }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(footerText)
            }

            if model.isLoading {
                Section { Text("Loading...") }
            } else {
                Section {
                    if model.mine.isEmpty {
                        Text(model.query.isEmpty ? "None yet." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.mine) { e in row(e, mine: true) }
                } header: {
                    Text("Your entries, \(model.mine.count)")
                }
                if model.communityInstalled {
                    Section {
                        if model.community.isEmpty {
                            Text("No matches.").foregroundStyle(.secondary)
                        }
                        ForEach(model.community) { e in row(e, mine: false) }
                    } header: {
                        Text("Community entries, \(model.community.count)")
                    }
                }
            }
        }
        .navigationTitle("Dictionary entries")
        .searchable(text: $model.query, prompt: "Search words")
        .autocorrectionDisabled(true)
        .noAutocapitalization()
        .onAppear { if model.isLoading { model.setLanguage(voice.language) } }
        .sheet(item: $editing) { target in
            EntryEditorView(target: target, model: model, voice: voice, settings: settings) { message in
                editing = nil
                announce(message)
            }
        }
    }

    private var footerText: String {
        var s = "Your entries always apply, and updates never change them."
        if !model.isLoading && !model.communityInstalled {
            s += model.language.communityPrefix == nil
                ? " No community dictionary for \(model.language.name)."
                : " Community dictionary not downloaded."
        } else if !VoiceSettingsStore.shared.dictionaryEnabled {
            s += " Community dictionary is off."
        }
        return s
    }

    private func row(_ e: DictionaryEntry, mine: Bool) -> some View {
        let edited = mine && model.catalog.isOverride(e)
        var value = e.kind.title
        if edited { value += ", edited" }
        return Button {
            editing = .edit(e, mine: mine)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.word).foregroundStyle(.primary)
                // phoneme codes as a readable respelling ("air-RAH-nihk"), never the symbols
                Text(model.shown(e.replacement)).font(.footnote).foregroundStyle(.secondary)
                Text(value).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(e.word), \(model.spoken(e.replacement))")
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
        .modifier(RowActions(entry: e, mine: mine, edited: edited, model: model, voice: voice, settings: settings,
                             announce: announce))
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        status = message
        AccessibilityNotification.Announcement(message).post()
    }
}

/// Listen (every row), and Delete (the user's own) or Revert (an edited community entry), as swipe
/// actions - which VoiceOver lists as the row's actions, once each.
private struct RowActions: ViewModifier {
    let entry: DictionaryEntry
    let mine: Bool
    let edited: Bool
    let model: DictionaryEditorModel
    let voice: EloquenceVoiceDef
    let settings: VoiceSettings
    let announce: (String) -> Void

    func body(content: Content) -> some View {
        let removeTitle = edited ? "Revert" : "Delete"
        return content
            .swipeActions(edge: .trailing) {
                if mine {
                    Button(removeTitle, role: edited ? nil : .destructive) { remove() }
                }
                Button("Listen") { listen() }.tint(.blue)
            }
            // No separate accessibilityAction: VoiceOver already offers every swipe action as an action
            // of the row, and a second one made VoiceOver say "Listen" twice (2026-09-24).
    }

    private func listen() {
        model.listenComparison(entry, mine: mine, voice: voice, settings: settings) { problem in
            if let problem { announce(problem) }
        }
    }

    private func remove() {
        if let problem = model.remove(entry) {
            announce(problem)
        } else {
            announce(edited ? "Reverted \(entry.word)." : "Deleted \(entry.word).")
        }
    }
}

enum EditorTarget: Identifiable {
    case add(prefill: String)
    case edit(DictionaryEntry, mine: Bool)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let e, let mine): return (mine ? "mine:" : "community:") + e.id
        }
    }
}

struct EntryEditorView: View {
    let target: EditorTarget
    @ObservedObject var model: DictionaryEditorModel
    let voice: EloquenceVoiceDef
    let settings: VoiceSettings
    let done: (String) -> Void

    /// The entry being edited, when it is not a new one: the user's own, or a community one.
    @State private var original: DictionaryEntry?
    @State private var originalIsMine = false
    @State private var word = ""
    @State private var replacement = ""
    @State private var kind: DictionaryKind = .word
    @State private var problem = ""
    @State private var duplicate: DictionaryCatalog.Duplicate = .none
    @State private var showDuplicate = false
    @State private var player: AVAudioPlayer?
    @State private var listening = false
    @State private var loaded = false
    @State private var editCode = false          // the raw phoneme code shown for editing

    private var isNew: Bool { original == nil }
    private var communityVersion: DictionaryEntry? {
        guard let o = original else { return nil }
        return model.catalog.communityEntry(kind: o.kind, word: o.word)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Word", text: $word)
                        .autocorrectionDisabled(true)
                        .noAutocapitalization()
                        .disabled(communityVersion != nil)
                        .accessibilityLabel("Word")
                    if PhoneticRespelling.isPhonetic(replacement) && !editCode {
                        // A phoneme code is shown as a readable respelling; the code itself is one tap away.
                        LabeledContent("Pronounced as", value: model.shown(replacement))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Pronounced as, \(model.spoken(replacement))")
                        Button("Edit phonetic code") { editCode = true }
                        Button("Type a spelling instead") { replacement = ""; editCode = false }
                    } else {
                        TextField(editCode ? "Phonetic code" : "Pronounced as", text: $replacement)
                            .autocorrectionDisabled(true)
                            .noAutocapitalization()
                            .accessibilityLabel(editCode ? "Phonetic code" : "Pronounced as")
                        if editCode && PhoneticRespelling.isPhonetic(replacement) {
                            Text("Reads as: \(model.shown(replacement))")
                                .font(.footnote)
                                .accessibilityLabel("Reads as \(model.spoken(replacement))")
                        }
                    }
                    if isNew {
                        Picker("Kind", selection: $kind) {
                            ForEach(DictionaryKind.allCases) { k in Text(k.title).tag(k) }
                        }
                    } else {
                        LabeledContent("Kind", value: kind.title)
                    }
                } footer: {
                    Text(kind.explanation)
                }

                if let c = communityVersion {
                    Section {
                        Text("Community version: \(model.shown(c.replacement))")
                            .font(.footnote)
                            .accessibilityLabel("Community version: \(model.spoken(c.replacement))")
                    }
                }

                if !problem.isEmpty {
                    Section {
                        Text(problem).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        listen()
                    } label: {
                        Label("Listen", systemImage: "play.circle")
                    }
                    .disabled(listening || word.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if originalIsMine, let o = original {
                    Section {
                        Button(role: communityVersion == nil ? .destructive : nil) {
                            if let p = model.remove(o) { show(p) } else {
                                done(communityVersion == nil ? "Deleted \(o.word)." : "Reverted \(o.word).")
                            }
                        } label: {
                            Text(communityVersion == nil ? "Delete entry" : "Revert to community version")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add a word" : "Edit \(original?.word ?? "")")
            .inlineNavigationTitle()
            .macFrame(minWidth: 440, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { done("") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert(duplicateTitle, isPresented: $showDuplicate) {
                Button("Edit existing") { switchToDuplicate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(duplicateMessage)
            }
            .onAppear { if !loaded { load(); loaded = true } }
        }
    }

    private func load() {
        switch target {
        case .add(let prefill):
            original = nil
            word = prefill
        case .edit(let e, let mine):
            original = e
            originalIsMine = mine
            word = e.word
            replacement = e.replacement
            kind = e.kind
        }
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(kind: kind, word: word.trimmingCharacters(in: .whitespaces),
                        replacement: replacement.trimmingCharacters(in: .whitespaces))
    }

    private func show(_ message: String) {
        problem = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func save() {
        if let p = DictionaryValidation.problem(word: word, replacement: replacement, kind: kind) {
            show(p)
            return
        }
        // Duplicate detection: a new word, or a renamed one of the user's, that the engine would read as
        // the same key as an existing entry of the same kind.
        let renamed = original.map { $0.matchKey != draft.matchKey } ?? true
        if renamed {
            let d = model.catalog.duplicate(kind: kind, word: draft.word, excluding: originalIsMine ? original : nil)
            if d != .none {
                duplicate = d
                showDuplicate = true
                return
            }
        }
        let old = originalIsMine ? original : nil
        if let p = model.set(draft, replacing: old) {
            show(p)
            return
        }
        done(isNew ? "Added \(draft.word)." : "Saved \(draft.word).")
    }

    private var duplicateTitle: String {
        switch duplicate {
        case .user(let e), .community(let e): return "Already an entry for \(e.word)"
        case .none: return ""
        }
    }

    private var duplicateMessage: String {
        switch duplicate {
        case .user(let e), .community(let e):
            return "Pronounced \(model.spoken(e.replacement)). Edit it instead?"
        case .none: return ""
        }
    }

    /// Opens the existing entry in this editor, keeping the pronunciation just typed so nothing is lost.
    private func switchToDuplicate() {
        let typed = replacement
        switch duplicate {
        case .user(let e):
            original = e
            originalIsMine = true
            word = e.word
            kind = e.kind
        case .community(let e):
            original = e
            originalIsMine = false
            word = e.word
            kind = e.kind
        case .none:
            return
        }
        replacement = typed
        problem = ""
        AccessibilityNotification.Announcement("Editing \(word).").post()
    }

    private func listen() {
        listening = true
        let hasDraft = DictionaryValidation.problem(word: word, replacement: replacement, kind: kind) == nil
        model.listen(word: word.trimmingCharacters(in: .whitespaces), draft: hasDraft ? draft : nil,
                     replacing: originalIsMine ? original : nil, voice: voice, settings: settings) { samples in
            listening = false
            guard let samples, !samples.isEmpty else {
                show("Could not speak that word.")
                return
            }
            do {
                try Playback.activate()
                player?.stop()
                let p = try AVAudioPlayer(data: WAVFile.data(samples, sampleRate: OutputSampleRate.native))
                p.prepareToPlay()
                p.play()
                player = p
            } catch {
                show("Playback error: \(error.localizedDescription)")
            }
        }
    }
}
