import Accelerate
import AVFoundation
import CoreAudio

enum CaptureError: Error, CustomStringConvertible {
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)
    case noFormat

    var description: String {
        switch self {
        case .ioProcCreationFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
        case .startFailed(let s): return "AudioDeviceStart failed (\(s))"
        case .noFormat: return "could not determine input stream format"
        }
    }
}

/// Captures Float32 audio from a Core Audio device (a real input device, or a
/// tap-backed aggregate device from SystemAudioTap) via a real-time IOProc,
/// downmixes to mono, converts to 16 kHz, and hands off fixed-size buffers.
///
/// The IOProc block itself only downmixes and dispatches - the heavier
/// AVAudioConverter work happens on a background queue, off the real-time
/// audio thread. (A fully rigorous implementation would push into a
/// preallocated lock-free ring buffer instead of dispatching a heap-allocated
/// array; this is a deliberate simplification for a personal tool.)
final class CoreAudioCapture {
    let deviceID: AudioDeviceID
    let label: String

    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Config.sampleRate, channels: 1, interleaved: false
    )!
    private let processingQueue: DispatchQueue
    private let onSamples: @Sendable ([Float]) -> Void

    init(deviceID: AudioDeviceID, label: String, onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.deviceID = deviceID
        self.label = label
        self.onSamples = onSamples
        self.processingQueue = DispatchQueue(label: "capture.\(label)", qos: .userInitiated)
    }

    func start() throws {
        let rate = (try? AudioHardwareDevice(id: deviceID).nominalSampleRate) ?? Config.sampleRate
        guard let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        ) else {
            throw CaptureError.noFormat
        }
        inputFormat = inFmt
        let conv = AVAudioConverter(from: inFmt, to: outputFormat)
        conv?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter = conv

        var newProcID: AudioDeviceIOProcID?
        let queue = processingQueue
        let sink = onSamples
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, nil) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let mono = Self.downmix(inputData)
            guard !mono.isEmpty else { return }
            queue.async { self.convertAndEmit(mono, sink: sink) }
        }
        guard status == noErr, let pid = newProcID else {
            throw CaptureError.ioProcCreationFailed(status)
        }
        procID = pid

        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else {
            throw CaptureError.startFailed(startStatus)
        }
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
    }

    /// Real-time thread: downmix an AudioBufferList (interleaved or
    /// non-interleaved) to mono Float32. No locks; the one allocation here
    /// (the returned array) is the deliberate simplification noted above.
    private static func downmix(_ inputData: UnsafePointer<AudioBufferList>) -> [Float] {
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = bufs.first, let raw = first.mData else { return [] }
        let channels = Int(first.mNumberChannels)
        guard channels > 0 else { return [] }

        if bufs.count > 1 {
            // Non-interleaved: one buffer per channel.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return [] }
            var mono = [Float](repeating: 0, count: frames)
            for buf in bufs {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                vDSP_vadd(mono, 1, p, 1, &mono, 1, vDSP_Length(frames))
            }
            var n = Float(bufs.count)
            vDSP_vsdiv(mono, 1, &n, &mono, 1, vDSP_Length(frames))
            return mono
        } else if channels == 1 {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return [] }
            let p = raw.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: p, count: frames))
        } else {
            // Interleaved multi-channel.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard frames > 0 else { return [] }
            var mono = [Float](repeating: 0, count: frames)
            let p = raw.assumingMemoryBound(to: Float.self)
            let stride = vDSP_Stride(channels)
            for ch in 0..<channels {
                vDSP_vadd(mono, 1, p.advanced(by: ch), stride, &mono, 1, vDSP_Length(frames))
            }
            var n = Float(channels)
            vDSP_vsdiv(mono, 1, &n, &mono, 1, vDSP_Length(frames))
            return mono
        }
    }

    /// Off the real-time thread: resample to 16 kHz and hand to the sink.
    private func convertAndEmit(_ mono: [Float], sink: @Sendable ([Float]) -> Void) {
        guard let inputFormat, let converter else { return }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        guard let dst = inBuffer.floatChannelData?[0] else { return }
        mono.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: mono.count)
        }

        let ratio = Config.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(mono.count) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        guard conversionError == nil else { return }

        guard let channelData = outBuffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
        guard !samples.isEmpty else { return }
        sink(samples)
    }
}
