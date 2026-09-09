import Foundation

/// Bounded FIFO shared across all capture sources, feeding one transcription
/// consumer. On overflow the OLDEST chunk is dropped (matches the Python
/// tool's backpressure policy) so the newest audio is always kept.
actor ChunkQueue {
    private var buffer: [SpeechChunk] = []
    private var waiter: CheckedContinuation<SpeechChunk?, Never>?
    private var closed = false
    private(set) var droppedCount = 0
    private let capacity: Int

    init(capacity: Int = Config.queueMaxChunks) {
        self.capacity = capacity
    }

    func push(_ chunk: SpeechChunk) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
            return
        }
        if buffer.count >= capacity {
            buffer.removeFirst()
            droppedCount += 1
        }
        buffer.append(chunk)
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    /// Single consumer only - do not call concurrently from multiple tasks.
    func next() async -> SpeechChunk? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            self.waiter = continuation
        }
    }
}
