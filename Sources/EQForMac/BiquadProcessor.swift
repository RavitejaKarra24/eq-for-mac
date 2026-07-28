import Accelerate
import AVFAudio
import Darwin
import Foundation

/// Allocation-free render-thread biquad cascade.
///
/// Control changes publish an immutable configuration through an atomic raw
/// pointer. Configurations stay retained until this processor is destroyed, so
/// the audio thread never performs ARC traffic or observes reclaimed memory.
final class BiquadProcessor: @unchecked Sendable {
    private final class Configuration {
        let setup: vDSP_biquad_Setup?
        let linearGain: Float
        let bypassed: Bool
        let channelCount: Int
        let delayCountPerChannel: Int
        let delayStates: UnsafeMutablePointer<Float>?

        init(
            coefficients: [BiquadCoefficients],
            linearGain: Float,
            bypassed: Bool,
            channelCount: Int
        ) {
            self.linearGain = linearGain
            self.bypassed = bypassed
            let resolvedChannelCount = max(1, channelCount)
            self.channelCount = resolvedChannelCount

            let flattened = coefficients.flatMap {
                [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2]
            }
            setup = flattened.withUnsafeBufferPointer {
                guard let baseAddress = $0.baseAddress, !coefficients.isEmpty
                else { return nil }
                return vDSP_biquad_CreateSetup(
                    baseAddress,
                    vDSP_Length(coefficients.count)
                )
            }
            if setup == nil {
                delayCountPerChannel = 0
                delayStates = nil
            } else {
                // vDSP_biquad requires two history samples for the input and
                // for every section in the cascade.
                delayCountPerChannel = 2 * coefficients.count + 2
                let states = UnsafeMutablePointer<Float>.allocate(
                    capacity: delayCountPerChannel * resolvedChannelCount
                )
                states.initialize(
                    repeating: 0,
                    count: delayCountPerChannel * resolvedChannelCount
                )
                delayStates = states
            }
        }

        deinit {
            if let setup {
                vDSP_biquad_DestroySetup(setup)
            }
            if let delayStates {
                delayStates.deinitialize(
                    count: delayCountPerChannel * channelCount
                )
                delayStates.deallocate()
            }
        }
    }

    private let sampleRate: Double
    private let channelCount: Int
    private var retainedConfigurations: [Configuration] = []
    private var activeConfigurationAddress: Int64 = 0
    private var activeRenderReaders: Int32 = 0

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        update(bands: [], preampDB: 0, bypassed: false)
    }

    func update(bands: [EQBand], preampDB: Float, bypassed: Bool) {
        let coefficients = bypassed
            ? []
            : bands.filter(\.changesFrequencyResponse).map {
                EQResponse.coefficients(for: $0, sampleRate: sampleRate)
            }
        let configuration = Configuration(
            coefficients: coefficients,
            linearGain: pow(10, preampDB / 20),
            bypassed: bypassed,
            channelCount: channelCount
        )
        retainedConfigurations.append(configuration)
        let address = Int64(Int(bitPattern: Unmanaged.passUnretained(configuration).toOpaque()))
        atomicStore(address, in: &activeConfigurationAddress)

        // Reclaim only on the control thread and only when no render callback
        // can still hold an unretained pointer to an older configuration.
        // Update count alone is not a valid lifetime fence.
        if retainedConfigurations.count > 256,
           OSAtomicAdd32Barrier(0, &activeRenderReaders) == 0 {
            retainedConfigurations.removeFirst(
                retainedConfigurations.count - 1
            )
        }
    }


    @inline(__always)
    func process(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        OSAtomicIncrement32Barrier(&activeRenderReaders)
        defer { OSAtomicDecrement32Barrier(&activeRenderReaders) }

        let address = OSAtomicAdd64Barrier(0, &activeConfigurationAddress)
        guard address != 0,
              let pointer = UnsafeRawPointer(bitPattern: Int(address))
        else { return }
        let configuration = Unmanaged<Configuration>.fromOpaque(pointer)
            .takeUnretainedValue()
        let needsGain = abs(configuration.linearGain - 1) > 0.000_001
        guard !configuration.bypassed,
              let setup = configuration.setup,
              let delayStates = configuration.delayStates
        else {
            guard needsGain else { return }
            applyGain(
                configuration.linearGain,
                to: bufferList,
                frameCount: frameCount
            )
            return
        }

        guard bufferList.count >= configuration.channelCount else { return }
        for channel in 0..<configuration.channelCount {
            guard let samples = bufferList[channel].mData?
                .assumingMemoryBound(to: Float.self)
            else { return }
            vDSP_biquad(
                setup,
                delayStates.advanced(
                    by: channel * configuration.delayCountPerChannel
                ),
                samples,
                1,
                samples,
                1,
                vDSP_Length(frameCount)
            )
        }
        if needsGain {
            applyGain(
                configuration.linearGain,
                to: bufferList,
                frameCount: frameCount
            )
        }
    }

    private func applyGain(
        _ gain: Float,
        to bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        for channel in 0..<bufferList.count {
            guard let samples = bufferList[channel].mData?
                .assumingMemoryBound(to: Float.self)
            else { continue }
            var scalar = gain
            vDSP_vsmul(
                samples,
                1,
                &scalar,
                samples,
                1,
                vDSP_Length(frameCount)
            )
        }
    }

    private func atomicStore(_ desired: Int64, in storage: inout Int64) {
        while true {
            let current = OSAtomicAdd64Barrier(0, &storage)
            if OSAtomicCompareAndSwap64Barrier(current, desired, &storage) {
                return
            }
        }
    }
}
