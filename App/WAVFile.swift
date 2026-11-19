import Foundation

enum WAVFile {
    /// Wrap raw Int16 mono PCM in a minimal WAV container (for AVAudioPlayer and the self-test).
    static func data(_ samples: [Int16], sampleRate: Int) -> Data {
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataLen = samples.count * 2
        var d = Data()
        d.append(Data("RIFF".utf8)); d.append(u32(UInt32(36 + dataLen))); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(u32(16)); d.append(u16(1)); d.append(u16(1))
        d.append(u32(UInt32(sampleRate))); d.append(u32(UInt32(sampleRate * 2)))
        d.append(u16(2)); d.append(u16(16))
        d.append(Data("data".utf8)); d.append(u32(UInt32(dataLen)))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
