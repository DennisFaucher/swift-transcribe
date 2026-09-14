import CoreAudio

struct InputDevice: Sendable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let channels: Int
    let sampleRate: Double
}

struct OutputDevice: Sendable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let channels: Int
    let sampleRate: Double
}

enum CoreAudioDevices {
    /// All devices exposing at least one input channel, using the macOS 15+
    /// Swift-native Core Audio object API (AudioHardwareSystem).
    static func listInputs() throws -> [InputDevice] {
        var result: [InputDevice] = []
        for device in try AudioHardwareSystem.shared.devices {
            guard let bufs = try? device.inputStreamConfiguration else { continue }
            let channels = bufs.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            guard let name = try? device.name,
                  let uid = try? device.uid,
                  let rate = try? device.nominalSampleRate else { continue }
            result.append(InputDevice(id: device.id, name: name, uid: uid, channels: channels, sampleRate: rate))
        }
        return result
    }

    /// First input device whose name contains `substring`, case-insensitive.
    static func findInput(nameContains substring: String) throws -> InputDevice? {
        try listInputs().first { $0.name.localizedCaseInsensitiveContains(substring) }
    }

    /// All devices exposing at least one output channel.
    static func listOutputs() throws -> [OutputDevice] {
        var result: [OutputDevice] = []
        for device in try AudioHardwareSystem.shared.devices {
            guard let bufs = try? device.outputStreamConfiguration else { continue }
            let channels = bufs.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            guard let name = try? device.name,
                  let uid = try? device.uid,
                  let rate = try? device.nominalSampleRate else { continue }
            result.append(OutputDevice(id: device.id, name: name, uid: uid, channels: channels, sampleRate: rate))
        }
        return result
    }

    /// First output device whose name contains `substring`, case-insensitive.
    static func findOutput(nameContains substring: String) throws -> OutputDevice? {
        try listOutputs().first { $0.name.localizedCaseInsensitiveContains(substring) }
    }
}
