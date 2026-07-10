import Foundation

/// Lock-free single-producer single-consumer ring buffer for bridging
/// Core Audio IOProc (producer) to AVAudioEngine (consumer).
final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private var writeHead: UInt64 = 0
    private var readHead: UInt64 = 0

    init(capacityFrames: Int, channels: Int) {
        let samples = capacityFrames * channels
        var power = 1
        while power < samples { power *= 2 }
        capacity = power
        mask = power - 1
        buffer = .allocate(capacity: power)
        buffer.initialize(repeating: 0, count: power)
    }

    deinit {
        buffer.deallocate()
    }

    private var availableToRead: Int {
        Int(writeHead &- readHead)
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            buffer[Int(writeHead) & mask] = data[i]
            writeHead &+= 1
        }
    }

    func read(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let toRead = min(count, availableToRead)
        for i in 0..<toRead {
            dest[i] = buffer[Int(readHead) & mask]
            readHead &+= 1
        }
        return toRead
    }
}
