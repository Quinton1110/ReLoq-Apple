//
//  SpeechRate.swift
//  One speed scale for VoiceOver and the in-app preview - the shape ClassicVoices settled on.
//
//  Both VoiceOver and the app speak in terms of a slider fraction 0...1 (VoiceOver's Speaking Rate,
//  the app's Slow...Fast slider). 0.5 is the voice's natural speed. The fraction is turned into a
//  SPEED FACTOR relative to natural speed on a log scale: the lower half slows to 1/3 x, the upper
//  half speeds up to about 7.2 x (3^(r/10) for r in -10...18, the scale the SAPI 5 voices used and
//  the author's ClassicVoices uses). The bridge then puts that factor onto the engine's own
//  speed control (words per minute with eciRealWorldUnits on, see ev_bridge.c) - nothing is ever
//  time-stretched. Where the real engine stops getting faster, effectiveSpeed (EloquenceEngine) caps
//  the factor so the pauses between segments keep pace with the speech.
//
//  ⚠️ The exact relation between this factor and how fast Eloquence actually talks is a GUESS until
//     the real engine is in: tune EV_SPEED_* in ev_bridge.c, not this file.
//

import Foundation

enum SpeechRate {
    static let slowestStep = -10.0
    static let fastestStep = 18.0

    /// Slider fraction (0...1) -> log-scale step (-10...18), 0.5 -> 0.
    static func step(fromFraction f: Double) -> Double {
        let x = min(1.0, max(0.0, f))
        if x <= 0.5 { return slowestStep * (1.0 - x / 0.5) }
        return fastestStep * ((x - 0.5) / 0.5)
    }

    /// Speed relative to natural (1.0 = the voice's own speed).
    static func speedFactor(step r: Double) -> Double { pow(3.0, r / 10.0) }

    static func speedFactor(fromFraction f: Double) -> Double { speedFactor(step: step(fromFraction: f)) }

    /// VoiceOver's non-linear slider -> SSML prosody curve, inverted (learned on NeuralVoice, carried
    /// through ClassicVoices): slider 0...50% is sent as 0...100%, slider 50...100% as 100...400%.
    static func fraction(fromVOProsodyPercent p: Double) -> Double {
        let f: Double
        if p <= 100.0 { f = (p / 100.0) * 0.5 }
        else { f = 0.5 + ((p - 100.0) / 300.0) * 0.5 }
        return min(1.0, max(0.0, f))
    }

    /// Spoken description, e.g. "normal speed", "1.5 times normal".
    static func describe(fraction f: Double) -> String {
        let factor = speedFactor(fromFraction: f)
        if abs(factor - 1.0) < 0.03 { return "normal speed" }
        return String(format: "%.1f times normal", factor)
    }
}
