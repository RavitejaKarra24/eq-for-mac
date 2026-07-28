import Darwin
import Foundation

/// Lock-free single-producer single-consumer ring buffer for bridging
/// Core Audio IOProc (producer) to AVAudioEngine (consumer).
///
/// Exactly one thread may call `write` and exactly one other thread may call
/// `read`/`readLatest`. The heads use OSAtomic barriers because the package
/// still deploys to macOS 14, where Swift's newer `Synchronization.Atomic`
/// cannot be assumed. Replace these compatibility atomics when the deployment
/// target moves to a runtime that includes the Synchronization framework.
final class AudioRingBuffer: @unchecked Sendable {
    enum OverrunBehavior {
        /// Preserve queued order and reject samples that do not fit.
        case dropNewest
        /// On the next read, trim the backlog to one requested block so a
        /// real-time stream does not remain permanently delayed.
        case discardStaleOnRead
    }

    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let overrunBehavior: OverrunBehavior
    private var writeHead: Int64 = 0
    private var readHead: Int64 = 0
    private var consumerResyncRequested: UInt32 = 0

    init(
        capacityFrames: Int,
        channels: Int,
        overrunBehavior: OverrunBehavior = .dropNewest
    ) {
        let samples = max(1, capacityFrames * channels)
        var power = 1
        while power < samples { power *= 2 }
        capacity = power
        mask = power - 1
        self.overrunBehavior = overrunBehavior
        buffer = .allocate(capacity: power)
        buffer.initialize(repeating: 0, count: power)
    }

    deinit {
        buffer.deallocate()
    }

    var capacitySamples: Int {
        capacity
    }

    var availableSamples: Int {
        availableToRead(write: loadWriteHead(), read: loadReadHead())
    }

    private func loadWriteHead() -> Int64 {
        OSAtomicAdd64Barrier(0, &writeHead)
    }

    private func loadReadHead() -> Int64 {
        OSAtomicAdd64Barrier(0, &readHead)
    }

    private func availableToRead(write: Int64, read: Int64) -> Int {
        min(capacity, max(0, Int(write - read)))
    }

    /// Copies as many samples as fit. Returning the number accepted lets
    /// callers account for drops without adding work to the audio callback.
    @discardableResult
    func write(_ data: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        let write = loadWriteHead()
        let read = loadReadHead()
        let occupied = availableToRead(write: write, read: read)
        let toWrite = min(count, capacity - occupied)
        guard toWrite > 0 else {
            requestConsumerResyncIfNeeded()
            return 0
        }

        let writeIndex = Int(UInt64(bitPattern: write) & UInt64(mask))
        let firstCount = min(toWrite, capacity - writeIndex)
        memcpy(
            buffer.advanced(by: writeIndex),
            data,
            firstCount * MemoryLayout<Float>.stride
        )

        let secondCount = toWrite - firstCount
        if secondCount > 0 {
            memcpy(
                buffer,
                data.advanced(by: firstCount),
                secondCount * MemoryLayout<Float>.stride
            )
        }

        // Publish only after both wrapped copy segments are complete.
        OSAtomicAdd64Barrier(Int64(toWrite), &writeHead)
        if toWrite < count {
            requestConsumerResyncIfNeeded()
        }
        return toWrite
    }

    func read(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        discardStaleSamplesIfRequested(keepingAtMost: count)
        let read = loadReadHead()
        let write = loadWriteHead()
        let toRead = min(count, availableToRead(write: write, read: read))
        guard toRead > 0 else { return 0 }

        let readIndex = Int(UInt64(bitPattern: read) & UInt64(mask))
        let firstCount = min(toRead, capacity - readIndex)
        memcpy(
            dest,
            buffer.advanced(by: readIndex),
            firstCount * MemoryLayout<Float>.stride
        )

        let secondCount = toRead - firstCount
        if secondCount > 0 {
            memcpy(
                dest.advanced(by: firstCount),
                buffer,
                secondCount * MemoryLayout<Float>.stride
            )
        }

        // Release the slots only after the destination copy is complete.
        OSAtomicAdd64Barrier(Int64(toRead), &readHead)
        return toRead
    }

    /// Reads up to `count` of the newest samples, discarding older queued data
    /// when the consumer has fallen behind. This is useful for visualization,
    /// where freshness matters more than preserving every sample.
    func readLatest(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        let currentReadHead = loadReadHead()
        let write = loadWriteHead()
        let available = availableToRead(write: write, read: currentReadHead)
        let skipped = max(0, available - count)
        if skipped > 0 {
            OSAtomicAdd64Barrier(Int64(skipped), &readHead)
        }
        return read(dest, count: min(count, available))
    }

    /// Drops queued history while retaining a caller-selected latency target.
    func trimBacklog(keepingAtMost count: Int) {
        let read = loadReadHead()
        let write = loadWriteHead()
        let available = availableToRead(write: write, read: read)
        let staleCount = max(0, available - max(0, count))
        if staleCount > 0 {
            OSAtomicAdd64Barrier(Int64(staleCount), &readHead)
        }
    }

    private func requestConsumerResyncIfNeeded() {
        guard overrunBehavior == .discardStaleOnRead else { return }
        OSAtomicOr32Barrier(1, &consumerResyncRequested)
    }

    private func discardStaleSamplesIfRequested(keepingAtMost count: Int) {
        guard overrunBehavior == .discardStaleOnRead,
              OSAtomicAnd32OrigBarrier(0, &consumerResyncRequested) != 0
        else {
            return
        }

        let read = loadReadHead()
        let write = loadWriteHead()
        let available = availableToRead(write: write, read: read)
        let staleCount = max(0, available - count)
        if staleCount > 0 {
            OSAtomicAdd64Barrier(Int64(staleCount), &readHead)
        }
    }
}
