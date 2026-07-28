import AVFAudio
import Darwin
import Foundation

/// Small, allocation-free stereo stage used by the source-node render block.
///
/// Control values are packed into one atomic word so the main actor can update
/// them without taking a lock on the audio thread. DSP state is owned entirely
/// by the render thread after initialization.
final class StereoProcessor: @unchecked Sendable {
    struct Settings: Sendable {
        var crossfeedIntensity: Float
        var stereoWidth: Float
        var balance: Float
        var monoEnabled: Bool
        var bypassed: Bool

        static let neutral = Settings(
            crossfeedIntensity: 0,
            stereoWidth: 1,
            balance: 0,
            monoEnabled: false,
            bypassed: false
        )
    }

    private static let valueBits: UInt64 = 20
    private static let valueMask: UInt64 = (1 << valueBits) - 1
    private static let monoBit: UInt64 = 1 << 60
    private static let bypassBit: UInt64 = 1 << 61

    private var packedSettings: Int64
    private var packedFadeCommand: Int64 = 0
    private var nextFadeGeneration: UInt32 = 0

    private let crossfeedFilterCoefficient: Float
    private var leftFilterState: Float = 0
    private var rightFilterState: Float = 0
    private var leftDelay: [Float]
    private var rightDelay: [Float]
    private var delayWriteIndex = 0
    private var wasBypassed = false
    private var controlsWereNeutral = true

    private var lastFadeGeneration: UInt32 = 0
    private var currentGain: Float
    private var targetGain: Float
    private var gainStep: Float = 0
    private var remainingRampFrames = 0

    init(sampleRate: Double, initialGain: Float = 0) {
        packedSettings = Int64(bitPattern: Self.pack(.neutral))
        currentGain = max(0, min(1, initialGain))
        targetGain = currentGain

        let crossfeedCutoff: Double = 700
        crossfeedFilterCoefficient = Float(
            1 - exp(-2 * Double.pi * crossfeedCutoff / sampleRate)
        )
        // A short interaural delay plus a low-pass avoids simply collapsing
        // the signal toward mono.
        let delayFrames = max(1, Int(sampleRate * 0.000_25))
        leftDelay = Array(repeating: 0, count: delayFrames + 1)
        rightDelay = Array(repeating: 0, count: delayFrames + 1)
    }

    func update(settings: Settings) {
        atomicStore(Self.pack(settings), in: &packedSettings)
    }

    /// Schedules a render-thread ramp without touching render-owned state.
    func scheduleGainRamp(to target: Float, durationFrames: Int) {
        nextFadeGeneration &+= 1
        let targetBits = UInt64(
            max(0, min(65_535, Int((max(0, min(1, target)) * 65_535).rounded())))
        )
        let durationBits = UInt64(max(1, min(65_535, durationFrames)))
        let command =
            (UInt64(nextFadeGeneration) << 32)
            | (durationBits << 16)
            | targetBits
        atomicStore(command, in: &packedFadeCommand)
    }

    /// Applies crossfeed/width/balance/mono plus restart gain smoothing.
    /// The buffers are AVAudioEngine's non-interleaved Float32 output buffers.
    @inline(__always)
    func process(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        guard frameCount > 0, !bufferList.isEmpty else { return }

        consumeFadeCommandIfNeeded()
        let settings = Self.unpack(
            UInt64(bitPattern: OSAtomicAdd64Barrier(0, &packedSettings))
        )

        let left = bufferList[0].mData?.assumingMemoryBound(to: Float.self)
        let right = bufferList.count > 1
            ? bufferList[1].mData?.assumingMemoryBound(to: Float.self)
            : nil

        if settings.bypassed {
            wasBypassed = true
            applyGainOnly(
                bufferList,
                frameCount: frameCount,
                left: left,
                right: right
            )
            return
        }

        if wasBypassed {
            resetCrossfeedState()
            wasBypassed = false
        }

        let controlsAreNeutral =
            settings.crossfeedIntensity < 0.000_01
            && abs(settings.stereoWidth - 1) < 0.000_01
            && abs(settings.balance) < 0.000_01
            && !settings.monoEnabled
        if controlsAreNeutral {
            if !controlsWereNeutral {
                resetCrossfeedState()
                controlsWereNeutral = true
            }
            applyGainOnly(
                bufferList,
                frameCount: frameCount,
                left: left,
                right: right
            )
            return
        }
        controlsWereNeutral = false

        guard let left, let right else {
            applyGainOnly(
                bufferList,
                frameCount: frameCount,
                left: left,
                right: right
            )
            return
        }

        let crossfeedMix = settings.crossfeedIntensity * 0.22
        let dryScale = 1 / (1 + crossfeedMix)
        let width = settings.monoEnabled ? Float(0) : settings.stereoWidth
        let leftBalanceGain = settings.balance > 0 ? 1 - settings.balance : 1
        let rightBalanceGain = settings.balance < 0 ? 1 + settings.balance : 1

        for frame in 0..<frameCount {
            let dryLeft = left[frame]
            let dryRight = right[frame]

            leftFilterState +=
                crossfeedFilterCoefficient * (dryLeft - leftFilterState)
            rightFilterState +=
                crossfeedFilterCoefficient * (dryRight - rightFilterState)

            leftDelay[delayWriteIndex] = leftFilterState
            rightDelay[delayWriteIndex] = rightFilterState
            let delayReadIndex = (delayWriteIndex + 1) % leftDelay.count
            let delayedLeft = leftDelay[delayReadIndex]
            let delayedRight = rightDelay[delayReadIndex]
            delayWriteIndex = delayReadIndex

            let crossfedLeft =
                (dryLeft + delayedRight * crossfeedMix) * dryScale
            let crossfedRight =
                (dryRight + delayedLeft * crossfeedMix) * dryScale
            let mid = (crossfedLeft + crossfedRight) * 0.5
            let side = (crossfedLeft - crossfedRight) * 0.5 * width
            let gain = nextGain()

            left[frame] = (mid + side) * leftBalanceGain * gain
            right[frame] = (mid - side) * rightBalanceGain * gain

            if bufferList.count > 2, gain != 1 {
                for channel in 2..<bufferList.count {
                    guard let channelData = bufferList[channel]
                        .mData?
                        .assumingMemoryBound(to: Float.self)
                    else {
                        continue
                    }
                    channelData[frame] *= gain
                }
            }
        }
    }

    private func applyGainOnly(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        left: UnsafeMutablePointer<Float>?,
        right: UnsafeMutablePointer<Float>?
    ) {
        for frame in 0..<frameCount {
            let gain = nextGain()
            guard gain != 1 else { continue }

            if let left {
                left[frame] *= gain
            }
            if let right {
                right[frame] *= gain
            }
            if bufferList.count > 2 {
                for channel in 2..<bufferList.count {
                    guard let channelData = bufferList[channel]
                        .mData?
                        .assumingMemoryBound(to: Float.self)
                    else {
                        continue
                    }
                    channelData[frame] *= gain
                }
            }
        }
    }

    @inline(__always)
    private func nextGain() -> Float {
        guard remainingRampFrames > 0 else { return currentGain }
        currentGain += gainStep
        remainingRampFrames -= 1
        if remainingRampFrames == 0 {
            currentGain = targetGain
        }
        return currentGain
    }

    private func consumeFadeCommandIfNeeded() {
        let command = UInt64(
            bitPattern: OSAtomicAdd64Barrier(0, &packedFadeCommand)
        )
        let generation = UInt32(truncatingIfNeeded: command >> 32)
        guard generation != lastFadeGeneration else { return }
        lastFadeGeneration = generation

        let duration = max(1, Int((command >> 16) & 0xFFFF))
        let targetBits = command & 0xFFFF
        targetGain = Float(targetBits) / 65_535
        remainingRampFrames = duration
        gainStep = (targetGain - currentGain) / Float(duration)
    }

    private func resetCrossfeedState() {
        leftFilterState = 0
        rightFilterState = 0
        delayWriteIndex = 0
        leftDelay.withUnsafeMutableBufferPointer { delay in
            guard let baseAddress = delay.baseAddress else { return }
            memset(
                baseAddress,
                0,
                delay.count * MemoryLayout<Float>.stride
            )
        }
        rightDelay.withUnsafeMutableBufferPointer { delay in
            guard let baseAddress = delay.baseAddress else { return }
            memset(
                baseAddress,
                0,
                delay.count * MemoryLayout<Float>.stride
            )
        }
    }

    private static func pack(_ settings: Settings) -> UInt64 {
        let crossfeed = quantize(settings.crossfeedIntensity, lower: 0, upper: 1)
        let width = quantize(settings.stereoWidth, lower: 0, upper: 2)
        let balance = quantize(settings.balance, lower: -1, upper: 1)
        var result =
            crossfeed
            | (width << valueBits)
            | (balance << (valueBits * 2))
        if settings.monoEnabled {
            result |= monoBit
        }
        if settings.bypassed {
            result |= bypassBit
        }
        return result
    }

    private static func unpack(_ packed: UInt64) -> Settings {
        let crossfeedBits = packed & valueMask
        let widthBits = (packed >> valueBits) & valueMask
        let balanceBits = (packed >> (valueBits * 2)) & valueMask
        return Settings(
            crossfeedIntensity: dequantize(
                crossfeedBits,
                lower: 0,
                upper: 1
            ),
            stereoWidth: dequantize(widthBits, lower: 0, upper: 2),
            balance: dequantize(balanceBits, lower: -1, upper: 1),
            monoEnabled: packed & monoBit != 0,
            bypassed: packed & bypassBit != 0
        )
    }

    private static func quantize(
        _ value: Float,
        lower: Float,
        upper: Float
    ) -> UInt64 {
        let normalized = (max(lower, min(upper, value)) - lower)
            / (upper - lower)
        return UInt64((normalized * Float(valueMask)).rounded())
    }

    private static func dequantize(
        _ value: UInt64,
        lower: Float,
        upper: Float
    ) -> Float {
        lower + (Float(value) / Float(valueMask)) * (upper - lower)
    }

    private func atomicStore(
        _ newValue: UInt64,
        in storage: inout Int64
    ) {
        let desired = Int64(bitPattern: newValue)
        while true {
            let current = OSAtomicAdd64Barrier(0, &storage)
            if OSAtomicCompareAndSwap64Barrier(current, desired, &storage) {
                return
            }
        }
    }
}
