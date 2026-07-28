import XCTest
@testable import EQForMac

final class AudioRingBufferTests: XCTestCase {
    func testReadWriteMaintainsSampleOrder() {
        let ringBuffer = AudioRingBuffer(capacityFrames: 8, channels: 2)

        write([0, 1, 2, 3, 4, 5], to: ringBuffer)

        let result = read(count: 6, from: ringBuffer)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.samples, [0, 1, 2, 3, 4, 5])
    }

    func testWrapAroundAfterPartialRead() {
        let ringBuffer = AudioRingBuffer(capacityFrames: 4, channels: 1)

        write([1, 2, 3], to: ringBuffer)
        XCTAssertEqual(read(count: 2, from: ringBuffer).samples, [1, 2])

        write([4, 5, 6], to: ringBuffer)
        let wrapped = read(count: 8, from: ringBuffer)

        XCTAssertEqual(wrapped.count, 4)
        XCTAssertEqual(wrapped.samples, [3, 4, 5, 6])
    }

    func testReadReturnsOnlyAvailableSamples() {
        let ringBuffer = AudioRingBuffer(capacityFrames: 4, channels: 1)

        XCTAssertEqual(read(count: 4, from: ringBuffer).count, 0)
        write([9, 10], to: ringBuffer)

        let partial = read(count: 4, from: ringBuffer)
        XCTAssertEqual(partial.count, 2)
        XCTAssertEqual(partial.samples, [9, 10])
        XCTAssertEqual(read(count: 1, from: ringBuffer).count, 0)
    }

    func testOverrunAcceptsCapacityAndDropsNewestSamples() {
        let ringBuffer = AudioRingBuffer(capacityFrames: 4, channels: 1)

        let accepted = writeAndReport([1, 2, 3, 4, 5, 6], to: ringBuffer)

        XCTAssertEqual(accepted, 4)
        XCTAssertEqual(writeAndReport([7], to: ringBuffer), 0)
        XCTAssertEqual(read(count: 8, from: ringBuffer).samples, [1, 2, 3, 4])
    }

    func testReadLatestDiscardsStaleSamples() {
        let ringBuffer = AudioRingBuffer(capacityFrames: 8, channels: 1)
        write([1, 2, 3, 4, 5, 6, 7, 8], to: ringBuffer)
        var destination = Array(repeating: Float.nan, count: 3)

        let samplesRead = destination.withUnsafeMutableBufferPointer { pointer in
            ringBuffer.readLatest(pointer.baseAddress!, count: pointer.count)
        }

        XCTAssertEqual(samplesRead, 3)
        XCTAssertEqual(destination, [6, 7, 8])
        XCTAssertEqual(read(count: 1, from: ringBuffer).count, 0)
    }

    func testPlaybackOverrunTrimsBacklogOnNextRead() {
        let ringBuffer = AudioRingBuffer(
            capacityFrames: 4,
            channels: 1,
            overrunBehavior: .discardStaleOnRead
        )

        XCTAssertEqual(writeAndReport([1, 2, 3, 4, 5, 6], to: ringBuffer), 4)
        XCTAssertEqual(read(count: 2, from: ringBuffer).samples, [3, 4])

        write([7, 8], to: ringBuffer)
        XCTAssertEqual(read(count: 2, from: ringBuffer).samples, [7, 8])
    }

    private func write(_ samples: [Float], to ringBuffer: AudioRingBuffer) {
        _ = writeAndReport(samples, to: ringBuffer)
    }

    private func writeAndReport(
        _ samples: [Float],
        to ringBuffer: AudioRingBuffer
    ) -> Int {
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return ringBuffer.write(baseAddress, count: pointer.count)
        }
    }

    private func read(
        count: Int,
        from ringBuffer: AudioRingBuffer
    ) -> (count: Int, samples: [Float]) {
        var destination = Array(repeating: Float.nan, count: count)
        let samplesRead = destination.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return ringBuffer.read(baseAddress, count: pointer.count)
        }
        return (samplesRead, Array(destination.prefix(samplesRead)))
    }
}
