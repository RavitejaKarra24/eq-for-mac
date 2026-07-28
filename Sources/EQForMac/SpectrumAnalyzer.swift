import Accelerate
import Foundation

/// Off-render-thread spectrum analysis fed by a real-time-safe SPSC copy.
///
/// The Core Audio callback only calls `submitInterleaved`; windowing, FFT,
/// log-frequency aggregation, normalization, and smoothing all run on the
/// analyzer queue at the display refresh rate.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let binCount = 64
    static let minimumFrequency: Float = 20
    static let maximumFrequency: Float = 20_000

    private let channelCount: Int
    private let fftSize: Int
    private let log2FFTSize: vDSP_Length
    private let inputRing: AudioRingBuffer
    private let analysisQueue = DispatchQueue(
        label: "com.eqformac.spectrum",
        qos: .userInteractive
    )
    private let fftSetup: FFTSetup
    private let binRanges: [Range<Int>]
    private let powerScale: Float
    private let onMagnitudes: @Sendable ([Float]) -> Void

    private var timer: DispatchSourceTimer?
    private var monitoringEnabled = true
    private var validRollingFrames = 0

    // All buffers below are created before analysis starts and are touched only
    // by `analysisQueue`.
    private var interleavedScratch: [Float]
    private var rollingSamples: [Float]
    private var window: [Float]
    private var windowedSamples: [Float]
    private var splitReal: [Float]
    private var splitImaginary: [Float]
    private var channelPowerSpectrum: [Float]
    private var powerSpectrum: [Float]
    private var decibelSpectrum: [Float]
    private var smoothedMagnitudes: [Float]

    init?(
        sampleRate: Double,
        channelCount: Int,
        fftSize: Int = 4_096,
        onMagnitudes: @escaping @Sendable ([Float]) -> Void
    ) {
        guard sampleRate > Double(Self.minimumFrequency * 2),
              channelCount > 0,
              fftSize >= 256,
              fftSize.nonzeroBitCount == 1
        else {
            return nil
        }

        let log2Size = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            return nil
        }

        self.channelCount = channelCount
        self.fftSize = fftSize
        log2FFTSize = log2Size
        fftSetup = setup
        self.onMagnitudes = onMagnitudes

        // A few FFT windows absorb scheduling jitter without making the
        // visualization lag far behind real audio.
        let scratchFrameCount = fftSize * 4
        inputRing = AudioRingBuffer(
            capacityFrames: max(scratchFrameCount, Int(sampleRate / 4)),
            channels: channelCount
        )
        interleavedScratch = Array(
            repeating: 0,
            count: scratchFrameCount * channelCount
        )
        rollingSamples = Array(
            repeating: 0,
            count: fftSize * channelCount
        )
        window = Array(repeating: 0, count: fftSize)
        windowedSamples = Array(repeating: 0, count: fftSize)
        splitReal = Array(repeating: 0, count: fftSize / 2)
        splitImaginary = Array(repeating: 0, count: fftSize / 2)
        channelPowerSpectrum = Array(repeating: 0, count: fftSize / 2)
        powerSpectrum = Array(repeating: 0, count: fftSize / 2)
        decibelSpectrum = Array(repeating: -90, count: fftSize / 2)
        smoothedMagnitudes = Array(repeating: 0, count: Self.binCount)

        vDSP_hann_window(
            &window,
            vDSP_Length(fftSize),
            Int32(vDSP_HANN_NORM)
        )
        var windowSum: Float = 0
        vDSP_sve(window, 1, &windowSum, vDSP_Length(fftSize))
        let coherentGain = max(0.000_001, windowSum / Float(fftSize))
        let amplitudeScale = 2 / (Float(fftSize) * coherentGain)
        powerScale = amplitudeScale * amplitudeScale

        let nyquist = Float(sampleRate / 2)
        let upperFrequency = min(Self.maximumFrequency, nyquist)
        let frequencyRatio = upperFrequency / Self.minimumFrequency
        let hzPerFFTBin = Float(sampleRate) / Float(fftSize)
        binRanges = (0..<Self.binCount).map { index in
            let lowerFraction = Float(index) / Float(Self.binCount)
            let upperFraction = Float(index + 1) / Float(Self.binCount)
            let lowerFrequency =
                Self.minimumFrequency * pow(frequencyRatio, lowerFraction)
            let upperFrequency =
                Self.minimumFrequency * pow(frequencyRatio, upperFraction)

            let lowerIndex = max(1, Int(floor(lowerFrequency / hzPerFFTBin)))
            let upperIndex = min(
                fftSize / 2 - 1,
                max(lowerIndex, Int(ceil(upperFrequency / hzPerFFTBin)))
            )
            return lowerIndex..<(upperIndex + 1)
        }
    }

    deinit {
        // `stop` clears the timer's retaining event handler. AudioEngine calls
        // it before releasing its analyzer.
        vDSP_destroy_fftsetup(fftSetup)
    }

    func start() {
        analysisQueue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: analysisQueue)
            source.schedule(
                deadline: .now(),
                repeating: .milliseconds(33),
                leeway: .milliseconds(4)
            )
            source.setEventHandler { [weak self] in
                self?.analyzeNewestSamples()
            }
            timer = source
            source.resume()
        }
    }

    func stop() {
        analysisQueue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.monitoringEnabled = enabled
            if enabled {
                // Drop samples accumulated while hidden so the first rendered
                // frame reflects current audio rather than stale history.
                self.interleavedScratch.withUnsafeMutableBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    _ = self.inputRing.readLatest(baseAddress, count: buffer.count)
                }
                self.validRollingFrames = 0
                self.rollingSamples.withUnsafeMutableBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    memset(
                        baseAddress,
                        0,
                        buffer.count * MemoryLayout<Float>.stride
                    )
                }
            }
        }
    }

    /// Called from the Core Audio IOProc. This method deliberately performs
    /// only bounded ring-buffer copies and never allocates or dispatches.
    @inline(__always)
    func submitInterleaved(_ samples: UnsafePointer<Float>, count: Int) {
        inputRing.write(samples, count: count)
    }

    private func analyzeNewestSamples() {
        guard monitoringEnabled else { return }

        let receivedSampleCount = interleavedScratch.withUnsafeMutableBufferPointer {
            guard let destination = $0.baseAddress else { return 0 }
            return inputRing.readLatest(destination, count: $0.count)
        }
        let alignedSampleCount =
            receivedSampleCount - (receivedSampleCount % channelCount)
        let receivedFrameCount = alignedSampleCount / channelCount
        guard receivedFrameCount > 0 else { return }

        appendToRollingWindow(frameCount: receivedFrameCount)
        guard validRollingFrames == fftSize else { return }

        calculatePowerSpectrum()
        publishLogBins()
    }

    private func appendToRollingWindow(frameCount: Int) {
        interleavedScratch.withUnsafeBufferPointer { incoming in
            rollingSamples.withUnsafeMutableBufferPointer { rolling in
                guard let incomingBase = incoming.baseAddress,
                      let rollingBase = rolling.baseAddress
                else {
                    return
                }

                if frameCount >= fftSize {
                    memcpy(
                        rollingBase,
                        incomingBase.advanced(
                            by: (frameCount - fftSize) * channelCount
                        ),
                        fftSize * channelCount * MemoryLayout<Float>.stride
                    )
                    validRollingFrames = fftSize
                    return
                }

                let retainedFrames = fftSize - frameCount
                memmove(
                    rollingBase,
                    rollingBase.advanced(by: frameCount * channelCount),
                    retainedFrames * channelCount * MemoryLayout<Float>.stride
                )
                memcpy(
                    rollingBase.advanced(by: retainedFrames * channelCount),
                    incomingBase,
                    frameCount * channelCount * MemoryLayout<Float>.stride
                )
                validRollingFrames = min(
                    fftSize,
                    validRollingFrames + frameCount
                )
            }
        }
    }

    private func calculatePowerSpectrum() {
        vDSP_vclr(
            &powerSpectrum,
            1,
            vDSP_Length(powerSpectrum.count)
        )

        rollingSamples.withUnsafeBufferPointer { rolling in
            guard let rollingBase = rolling.baseAddress else { return }
            for channel in 0..<channelCount {
                vDSP_vmul(
                    rollingBase.advanced(by: channel),
                    vDSP_Stride(channelCount),
                    window,
                    1,
                    &windowedSamples,
                    1,
                    vDSP_Length(fftSize)
                )

                windowedSamples.withUnsafeBufferPointer { input in
                    splitReal.withUnsafeMutableBufferPointer { real in
                        splitImaginary.withUnsafeMutableBufferPointer { imaginary in
                            guard let inputBase = input.baseAddress,
                                  let realBase = real.baseAddress,
                                  let imaginaryBase = imaginary.baseAddress
                            else {
                                return
                            }

                            var splitComplex = DSPSplitComplex(
                                realp: realBase,
                                imagp: imaginaryBase
                            )
                            inputBase.withMemoryRebound(
                                to: DSPComplex.self,
                                capacity: fftSize / 2
                            ) { complexInput in
                                vDSP_ctoz(
                                    complexInput,
                                    2,
                                    &splitComplex,
                                    1,
                                    vDSP_Length(fftSize / 2)
                                )
                            }
                            vDSP_fft_zrip(
                                fftSetup,
                                &splitComplex,
                                1,
                                log2FFTSize,
                                FFTDirection(kFFTDirection_Forward)
                            )
                            vDSP_zvmags(
                                &splitComplex,
                                1,
                                &channelPowerSpectrum,
                                1,
                                vDSP_Length(fftSize / 2)
                            )
                        }
                    }
                }
                vDSP_vadd(
                    powerSpectrum,
                    1,
                    channelPowerSpectrum,
                    1,
                    &powerSpectrum,
                    1,
                    vDSP_Length(powerSpectrum.count)
                )
            }
        }

        var scale = powerScale / Float(channelCount)
        vDSP_vsmul(
            powerSpectrum,
            1,
            &scale,
            &powerSpectrum,
            1,
            vDSP_Length(powerSpectrum.count)
        )
        var floorPower: Float = 0.000_000_001
        vDSP_vthr(
            powerSpectrum,
            1,
            &floorPower,
            &powerSpectrum,
            1,
            vDSP_Length(powerSpectrum.count)
        )
        var referencePower: Float = 1
        vDSP_vdbcon(
            powerSpectrum,
            1,
            &referencePower,
            &decibelSpectrum,
            1,
            vDSP_Length(decibelSpectrum.count),
            0
        )
    }

    private func publishLogBins() {
        let noiseFloor: Float = -90
        let displayRange = -noiseFloor

        decibelSpectrum.withUnsafeBufferPointer { decibels in
            guard let baseAddress = decibels.baseAddress else { return }
            for (index, range) in binRanges.enumerated() {
                var peak = noiseFloor
                vDSP_maxv(
                    baseAddress.advanced(by: range.lowerBound),
                    1,
                    &peak,
                    vDSP_Length(range.count)
                )
                let target = max(0, min(1, (peak - noiseFloor) / displayRange))
                let smoothing: Float =
                    target > smoothedMagnitudes[index] ? 0.45 : 0.12
                smoothedMagnitudes[index] +=
                    (target - smoothedMagnitudes[index]) * smoothing
            }
        }

        onMagnitudes(Array(smoothedMagnitudes))
    }
}
