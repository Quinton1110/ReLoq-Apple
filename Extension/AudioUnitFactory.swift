//
//  AudioUnitFactory.swift
//  Principal class of the speech-provider extension.
//
//  The @objc name is bare (not module-prefixed) and matches NSExtensionPrincipalClass in
//  Extension/Info.plist - the pattern that works for NeuralVoice and ClassicVoices.
//

import CoreAudioKit

@objc(EloquenceVoicesProviderFactory)
public class EloquenceVoicesProviderFactory: NSObject, AUAudioUnitFactory {
    public func beginRequest(with context: NSExtensionContext) {}

    @objc public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        return try EloquenceVoicesProvider(componentDescription: componentDescription, options: [])
    }
}
