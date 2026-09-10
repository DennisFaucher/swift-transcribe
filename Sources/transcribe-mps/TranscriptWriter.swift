import Foundation

struct SourceStats {
    var recordedSeconds: Double = 0
    var chunksEmitted: Int = 0
}

/// Owns the transcript file and console output. File output is always plain
/// text; console output gets ANSI dim/bold styling when stdout is a tty.
/// Mirrors the Python tool's line format: `[HH:MM:SS] [<source>] <text>`.
actor TranscriptWriter {
    private let fileHandle: FileHandle
    private let path: URL
    private let sessionStart: Date
    private var lineCount = 0
    private var stats: [String: SourceStats] = [:]
    private let isTTY = isatty(FileHandle.standardOutput.fileDescriptor) != 0

    init(path: URL, sources: [String]) throws {
        FileManager.default.createFile(atPath: path.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: path)
        self.path = path
        self.sessionStart = Date()
        let header = "# Meeting transcript - \(Self.sessionStamp(sessionStart))\nSources: \(sources.joined(separator: ", "))\n\n"
        fileHandle.write(Data(header.utf8))
        for s in sources { stats[s] = SourceStats() }
    }

    func recordSamples(source: String, seconds: Double) {
        stats[source, default: SourceStats()].recordedSeconds += seconds
    }

    func recordChunk(source: String) {
        stats[source, default: SourceStats()].chunksEmitted += 1
    }

    func emit(source: String, wallClockOffset: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = Self.clockStamp(Date(timeIntervalSince1970: max(wallClockOffset, 0)))
        let plain = "[\(ts)] [\(source)] \(trimmed)"
        writeLine(plain)
        if isTTY {
            print("\u{1B}[2m[\(ts)]\u{1B}[0m \u{1B}[1m[\(source)]\u{1B}[0m \(trimmed)")
        } else {
            print(plain)
        }
        lineCount += 1
    }

    func status(_ message: String) {
        if isTTY {
            print("\u{1B}[2m\(message)\u{1B}[0m")
        } else {
            print(message)
        }
    }

    func close(droppedChunks: Int, transcriberError: String?) {
        let elapsed = Date().timeIntervalSince(sessionStart)
        var summary = "\n" + String(repeating: "=", count: 60) + "\n"
        summary += "Session length : \(Self.formatDuration(elapsed))\n"
        summary += "Sources:\n"
        for (name, s) in stats.sorted(by: { $0.key < $1.key }) {
            summary += "  - \(name): \(Int(s.recordedSeconds))s recorded, \(s.chunksEmitted) chunks\n"
        }
        summary += "Transcript lines: \(lineCount)\n"
        if droppedChunks > 0 {
            summary += "Dropped chunks  : \(droppedChunks) (transcriber fell behind)\n"
        }
        if let transcriberError {
            summary += "Transcriber error: \(transcriberError)\n"
        }
        summary += "Transcript saved to: \(path.path)\n"
        summary += String(repeating: "=", count: 60) + "\n"
        print(summary)
        writeLine("\n---\n" + summary)
        try? fileHandle.close()
    }

    private func writeLine(_ line: String) {
        fileHandle.write(Data((line + "\n").utf8))
    }

    static func sessionStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    private static func clockStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}
