import AVFAudio
import Foundation
import XCTest
@testable import EQForMac

final class StereoProcessorTests: XCTestCase {
    func testNeutralControlsLeaveSamplesUnchanged() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 1)

        let result = process(
            left: [1, -0.5],
            right: [-1, 0.25],
            with: processor
        )

        XCTAssertEqual(result.left, [1, -0.5])
        XCTAssertEqual(result.right, [-1, 0.25])
    }

    func testMonoFoldsBothChannelsToTheirAverage() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 1)
        processor.update(
            settings: StereoProcessor.Settings(
                crossfeedIntensity: 0,
                stereoWidth: 0,
                balance: 0,
                monoEnabled: true,
                bypassed: false
            )
        )

        let result = process(
            left: [1, 0],
            right: [0, 1],
            with: processor
        )

        assertEqual(result.left, [0.5, 0.5])
        assertEqual(result.right, [0.5, 0.5])
    }

    func testBypassIsDryEvenWithExtremeControls() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 1)
        processor.update(
            settings: StereoProcessor.Settings(
                crossfeedIntensity: 1,
                stereoWidth: 0,
                balance: 1,
                monoEnabled: true,
                bypassed: true
            )
        )

        let result = process(
            left: [0.75, -0.25],
            right: [-0.5, 0.5],
            with: processor
        )

        XCTAssertEqual(result.left, [0.75, -0.25])
        XCTAssertEqual(result.right, [-0.5, 0.5])
    }

    func testGainRampReachesTargetAcrossRequestedFrames() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 0)
        processor.scheduleGainRamp(to: 1, durationFrames: 4)

        let result = process(
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1],
            with: processor
        )

        assertEqual(result.left, [0.25, 0.5, 0.75, 1])
        assertEqual(result.right, [0.25, 0.5, 0.75, 1])
    }

    func testDisablingCrossfeedClearsDelayHistory() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 1)
        let crossfeed = StereoProcessor.Settings(
            crossfeedIntensity: 1,
            stereoWidth: 1,
            balance: 0,
            monoEnabled: false,
            bypassed: false
        )
        processor.update(settings: crossfeed)
        _ = process(
            left: [1, 0],
            right: [0, 0],
            with: processor
        )

        processor.update(settings: .neutral)
        _ = process(
            left: Array(repeating: 0, count: 32),
            right: Array(repeating: 0, count: 32),
            with: processor
        )

        processor.update(settings: crossfeed)
        let resumed = process(
            left: Array(repeating: 0, count: 32),
            right: Array(repeating: 0, count: 32),
            with: processor
        )
        assertEqual(resumed.left, Array(repeating: 0, count: 32))
        assertEqual(resumed.right, Array(repeating: 0, count: 32))
    }

    private func process(
        left: [Float],
        right: [Float],
        with processor: StereoProcessor
    ) -> (left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        var left = left
        var right = right
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                let bufferList = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(bufferList.unsafeMutablePointer) }
                bufferList.count = 2
                bufferList[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(
                        leftBuffer.count * MemoryLayout<Float>.stride
                    ),
                    mData: leftBuffer.baseAddress
                )
                bufferList[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(
                        rightBuffer.count * MemoryLayout<Float>.stride
                    ),
                    mData: rightBuffer.baseAddress
                )
                processor.process(bufferList, frameCount: leftBuffer.count)
            }
        }
        return (left, right)
    }

    private func assertEqual(
        _ actual: [Float],
        _ expected: [Float],
        accuracy: Float = 0.000_01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(
                actual,
                expected,
                accuracy: accuracy,
                file: file,
                line: line
            )
        }
    }
}
