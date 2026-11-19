//
//  Platform.swift
//  The few things the iOS and macOS apps do differently, in one place (`#if os(...)`, as Sapple does it).
//  Everything else is the same SwiftUI on both.
//

import SwiftUI
import AVFoundation

enum Playback {
    /// iOS: the playback audio session (ducks other audio) before the app plays a preview.
    /// macOS has no audio session; AVAudioPlayer plays as it is.
    static func activate() throws {
#if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
#endif
    }
}

extension View {
    /// Fields for words and phonetic codes: no automatic capital (iOS only; macOS has no such setting).
    @ViewBuilder func noAutocapitalization() -> some View {
#if os(iOS)
        self.textInputAutocapitalization(.never)
#else
        self
#endif
    }

    /// A sheet's title inline with its buttons (iOS only; a Mac sheet has no navigation bar).
    @ViewBuilder func inlineNavigationTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    /// A Mac window or sheet has no natural size; give the form room. Nothing on iOS.
    @ViewBuilder func macFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
#if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
#else
        self
#endif
    }
}
