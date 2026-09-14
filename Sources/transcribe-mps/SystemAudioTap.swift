import CoreAudio
import Foundation

enum SystemAudioTapError: Error, CustomStringConvertible {
    case tapCreationFailed
    case aggregateCreationFailed
    case noOutputDevice

    var description: String {
        switch self {
        case .tapCreationFailed: return "failed to create system-audio process tap"
        case .aggregateCreationFailed: return "failed to create aggregate device for system-audio tap"
        case .noOutputDevice: return "no default output device found to anchor the tap aggregate"
        }
    }
}

/// Captures system audio (everything playing on this Mac) via a macOS 14.2+
/// Core Audio process tap, instead of a virtual loopback driver like BlackHole.
/// Builds a private, auto-starting aggregate device whose sole purpose is to
/// expose the tap as a regular input AudioObjectID that CoreAudioCapture can
/// attach an IOProc to.
final class SystemAudioTap {
    private let system = AudioHardwareSystem.shared
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?

    /// - Parameter speakersSubstring: if given, tap the output device whose
    ///   name contains this substring (case-insensitive) instead of the
    ///   system default output device.
    /// - Returns: the aggregate device's ID, and the display name of the
    ///   output device actually tapped.
    func start(speakersSubstring: String? = nil) throws -> (deviceID: AudioObjectID, name: String) {
        let outputUID: String
        let outputName: String
        if let speakersSubstring {
            guard let outputDevice = try CoreAudioDevices.findOutput(nameContains: speakersSubstring) else {
                throw SystemAudioTapError.noOutputDevice
            }
            outputUID = outputDevice.uid
            outputName = outputDevice.name
        } else {
            guard let outputDevice = try system.defaultOutputDevice else {
                throw SystemAudioTapError.noOutputDevice
            }
            outputUID = try outputDevice.uid
            outputName = (try? outputDevice.name) ?? "System Audio"
        }

        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        guard let tap = try system.makeProcessTap(description: tapDescription) else {
            throw SystemAudioTapError.tapCreationFailed
        }
        self.tap = tap
        let tapUID = try tap.uid

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "transcribe-mps-system-audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ],
        ]

        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw SystemAudioTapError.aggregateCreationFailed
        }
        self.aggregate = aggregate
        return (aggregate.id, outputName)
    }

    func stop() {
        if let aggregate {
            try? system.destroyAggregateDevice(aggregate)
        }
        if let tap {
            try? system.destroyProcessTap(tap)
        }
        aggregate = nil
        tap = nil
    }
}
