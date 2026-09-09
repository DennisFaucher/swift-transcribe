import AVFoundation
import Foundation

enum AudioFileError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case cannotConvert(String)

    var description: String {
        switch self {
        case .cannotOpen(let p): return "cannot open audio file '\(p)'"
        case .cannotConvert(let p): return "cannot convert audio file '\(p)' to 16kHz mono"
        }
    }
}

enum AudioFile {
    /// Reads any AVFoundation-readable audio file and returns 16 kHz mono Float32 samples.
    static func loadMono16k(path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            throw AudioFileError.cannotOpen(path)
        }

        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Fast path: already the target format.
        if file.processingFormat.sampleRate == Config.sampleRate,
           file.processingFormat.channelCount == 1 {
            return try readAll(file: file, format: file.processingFormat)
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw AudioFileError.cannotConvert(path)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let inFrameCount = AVAudioFrameCount(file.length)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inFrameCount) else {
            throw AudioFileError.cannotOpen(path)
        }
        try file.read(into: inBuffer)

        let ratio = Config.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioFileError.cannotConvert(path)
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inBuffer
        }
        if let conversionError {
            throw AudioFileError.cannotConvert("\(path): \(conversionError)")
        }

        return floatSamples(from: outBuffer)
    }

    private static func readAll(file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioFileError.cannotOpen(file.url.path)
        }
        try file.read(into: buffer)
        return floatSamples(from: buffer)
    }

    private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
