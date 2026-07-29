import Accelerate
import AVFAudio
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.eqformac.app", category: "audio")

/// Per-graph render state. Its strong capture by `AVAudioSourceNode` ties the
/// scratch storage and processors to the render block's lifetime.
final class AudioRenderContext: @unchecked Sendable {
    let ringBuffer: AudioRingBuffer
    let stereoProcessor: StereoProcessor
    let biquadProcessor: BiquadProcessor
    private let channelCount: Int
    private let targetFillSamples: Int
    private let scratchCapacity: Int
    private let scratch: UnsafeMutablePointer<Float>
    private var isPrimed = false

    init(
        ringBuffer: AudioRingBuffer,
        channelCount: Int,
        scratchFrameCapacity: Int,
        targetFillFrames: Int,
        stereoProcessor: StereoProcessor,
        biquadProcessor: BiquadProcessor
    ) {
        self.ringBuffer = ringBuffer
        self.channelCount = max(1, channelCount)
        targetFillSamples = max(0, targetFillFrames) * self.channelCount
        self.stereoProcessor = stereoProcessor
        self.biquadProcessor = biquadProcessor
        scratchCapacity = scratchFrameCapacity * self.channelCount
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        scratch.deallocate()
    }

    @inline(__always)
    func render(
        frameCount: UInt32,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = Int(frameCount)
        let interleavedCount = frames * channelCount
        let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard interleavedCount <= scratchCapacity else {
            zero(bufferList)
            return noErr
        }

        let available = ringBuffer.availableSamples
        if !isPrimed {
            guard available >= targetFillSamples + interleavedCount else {
                zero(bufferList)
                return noErr
            }
            isPrimed = true
        } else if available > targetFillSamples + interleavedCount * 4 {
            ringBuffer.trimBacklog(
                keepingAtMost: targetFillSamples + interleavedCount
            )
        }

        let read = ringBuffer.read(scratch, count: interleavedCount)
        if read < interleavedCount {
            memset(
                scratch.advanced(by: read),
                0,
                (interleavedCount - read) * MemoryLayout<Float>.stride
            )
        }

        var unity: Float = 1
        for channelIndex in 0..<bufferList.count {
            guard let output = bufferList[channelIndex].mData?
                .assumingMemoryBound(to: Float.self)
            else { continue }
            let sourceChannel = min(channelIndex, channelCount - 1)
            vDSP_vsmul(
                scratch.advanced(by: sourceChannel),
                vDSP_Stride(channelCount),
                &unity,
                output,
                1,
                vDSP_Length(frames)
            )
        }
        stereoProcessor.process(bufferList, frameCount: frames)
        biquadProcessor.process(bufferList, frameCount: frames)
        return noErr
    }

    private func zero(_ bufferList: UnsafeMutableAudioBufferListPointer) {
        for buffer in bufferList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}

/// Converts any tap buffer layout into the interleaved samples consumed by the
/// ring buffer. Core Audio may provide one interleaved buffer or multiple
/// non-interleaved buffers depending on the tapped device.
final class TapInputContext: @unchecked Sendable {
    private let ringBuffer: AudioRingBuffer
    private let spectrumAnalyzer: SpectrumAnalyzer?
    private let channelCount: Int
    private let scratchCapacity: Int
    private let scratch: UnsafeMutablePointer<Float>

    init(
        ringBuffer: AudioRingBuffer,
        spectrumAnalyzer: SpectrumAnalyzer?,
        channelCount: Int,
        scratchFrameCapacity: Int
    ) {
        self.ringBuffer = ringBuffer
        self.spectrumAnalyzer = spectrumAnalyzer
        self.channelCount = max(1, channelCount)
        scratchCapacity = max(1, scratchFrameCapacity) * self.channelCount
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        scratch.deallocate()
    }

    @inline(__always)
    func consume(_ audioBufferList: UnsafePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        guard !bufferList.isEmpty else { return }

        if bufferList.count == 1,
           Int(bufferList[0].mNumberChannels) == channelCount,
           let data = bufferList[0].mData {
            let sampleCount = Int(bufferList[0].mDataByteSize)
                / MemoryLayout<Float>.stride
            let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            ringBuffer.write(samples, count: sampleCount)
            spectrumAnalyzer?.submitInterleaved(samples, count: sampleCount)
            return
        }

        var availableChannels = 0
        var frameCount = Int.max
        for buffer in bufferList {
            guard buffer.mData != nil else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            availableChannels += channels
            frameCount = min(frameCount, samples / channels)
        }

        guard frameCount > 0,
              frameCount != Int.max,
              availableChannels >= channelCount
        else { return }
        let sampleCount = frameCount * channelCount
        guard sampleCount <= scratchCapacity else { return }

        for frame in 0..<frameCount {
            var destinationChannel = 0
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let samples = data.assumingMemoryBound(to: Float.self)
                for sourceChannel in 0..<channels {
                    guard destinationChannel < channelCount else { break }
                    scratch[frame * channelCount + destinationChannel] =
                        samples[frame * channels + sourceChannel]
                    destinationChannel += 1
                }
                if destinationChannel == channelCount { break }
            }
        }

        ringBuffer.write(scratch, count: sampleCount)
        spectrumAnalyzer?.submitInterleaved(scratch, count: sampleCount)
    }
}

// MARK: - AudioEngine

/// System-wide EQ engine using Core Audio Process Taps (macOS 14.2+).
///
/// Pipeline:
///   Apps → (muted) CATap → Aggregate Device IOProc → Ring Buffer
///        → AVAudioSourceNode/Crossfeed/RBJ biquads → Peak Limiter
///        → Output Device
@available(macOS 14.2, *)
@MainActor
final class AudioEngine: ObservableObject {
    enum LatencyMode: String, CaseIterable, Sendable {
        case low = "Low"
        case balanced = "Balanced"
        case safe = "Safe"

        var targetMilliseconds: Double {
            switch self {
            case .low: return 8
            case .balanced: return 20
            case .safe: return 50
            }
        }

        var capacityMilliseconds: Double {
            switch self {
            case .low: return 40
            case .balanced: return 100
            case .safe: return 250
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var outputDeviceName = "Unknown"
    @Published private(set) var outputDeviceUID: String?
    @Published private(set) var errorMessage: String?
    /// 64 normalized 0...1 bins, spaced logarithmically from 20 Hz to 20 kHz
    /// (or Nyquist when lower).
    @Published private(set) var spectrumMagnitudes = Array(
        repeating: Float(0),
        count: SpectrumAnalyzer.binCount
    )
    @Published private(set) var crossfeedIntensity: Float = 0
    @Published private(set) var measuredLatencyMilliseconds: Double = 0
    @Published private(set) var latencyMode: LatencyMode = .balanced
    @Published var bypassed = false {
        didSet {
            applyEQ()
            updateStereoProcessorSettings()
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var limiterNode: AVAudioUnitEffect?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: AudioRingBuffer?
    private var spectrumAnalyzer: SpectrumAnalyzer?
    private var stereoProcessor: StereoProcessor?
    private var biquadProcessor: BiquadProcessor?
    private var renderContext: AudioRenderContext?
    private var tapInputContext: TapInputContext?
    private var tapUUID = UUID()
    nonisolated(unsafe) private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var outputFormatListener: AudioObjectPropertyListenerBlock?
    private var observedOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    nonisolated(unsafe) private var restartWorkItem: DispatchWorkItem?
    private var startupTask: Task<Void, Never>?
    nonisolated(unsafe) private var latencyTimer: Timer?
    private var restartGeneration: UInt64 = 0
    private var spectrumMonitoringEnabled = false
    private var activePreset: EQPreset = .flat()
    private var activeOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private let renderScratchFrameCapacity = 16_384
    private var sampleRate: Double = 48_000
    private var activeChannelCount = 2

    var onStateChange: (() -> Void)?
    var onOutputDeviceChange: ((_ uid: String, _ name: String) -> Void)?

    init() {
        if let rawValue = UserDefaults.standard.string(
            forKey: "EQForMac.latencyMode"
        ), let storedMode = LatencyMode(rawValue: rawValue) {
            latencyMode = storedMode
        }
        do {
            let id = try getRoutableOutputDeviceID()
            refreshOutputDeviceInfo(id, notify: false)
            installOutputFormatListener(for: id)
        } catch {
            outputDeviceName = "Unknown"
            outputDeviceUID = nil
        }
        installDeviceChangeListener()
    }

    deinit {
        // Best-effort cleanup; full stop() is @MainActor so call from app terminate path.
        if let block = deviceChangeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
        }
        if observedOutputDeviceID != kAudioObjectUnknown,
           let block = outputFormatListener {
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                observedOutputDeviceID,
                &rateAddress,
                DispatchQueue.main,
                block
            )
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                observedOutputDeviceID,
                &streamAddress,
                DispatchQueue.main,
                block
            )
        }
        restartWorkItem?.cancel()
        latencyTimer?.invalidate()
    }

    // MARK: - Public control

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !isRunning, startupTask == nil else { return }
            startupTask = Task { [weak self] in
                guard let self else { return }
                defer { startupTask = nil }
                do {
                    try await start()
                    errorMessage = nil
                } catch is CancellationError {
                    tearDownAudioGraph(notify: false)
                } catch {
                    tearDownAudioGraph(notify: false)
                    errorMessage = error.localizedDescription
                    isRunning = false
                    os_log(
                        .error,
                        log: log,
                        "start failed: %{public}@",
                        error.localizedDescription
                    )
                }
                onStateChange?()
            }
        } else {
            stop()
        }
    }

    func setSpectrumMonitoringEnabled(_ enabled: Bool) {
        spectrumMonitoringEnabled = enabled
        spectrumAnalyzer?.setMonitoringEnabled(enabled)
    }

    func setCrossfeedIntensity(_ intensity: Float) {
        crossfeedIntensity = max(0, min(1, intensity))
        updateStereoProcessorSettings()
    }

    func setLatencyMode(_ mode: LatencyMode) {
        guard latencyMode != mode else { return }
        latencyMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "EQForMac.latencyMode")
        if isRunning {
            scheduleRestart(reconnectDelay: 0)
        }
    }

    func apply(preset: EQPreset) {
        activePreset = preset
        applyEQ()
        onStateChange?()
    }

    // MARK: - Start / Stop

    func start() async throws {
        guard !isRunning else { return }
        errorMessage = nil

        let outputDeviceID = try getRoutableOutputDeviceID()
        activeOutputDeviceID = outputDeviceID
        let outputUID = try getDeviceUID(outputDeviceID)
        refreshOutputDeviceInfo(outputDeviceID, notify: true)
        installOutputFormatListener(for: outputDeviceID)

        // Exclude our own process from the tap so we don't mute our playback.
        var translateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var myPID = ProcessInfo.processInfo.processIdentifier
        var myProcessObjectID = AudioObjectID(kAudioObjectUnknown)
        var processObjectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try caCheck(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &translateAddress,
                UInt32(MemoryLayout<pid_t>.size),
                &myPID,
                &processObjectSize,
                &myProcessObjectID
            ),
            "Failed to identify EQ for Mac's audio process"
        )

        // Tap only the selected output device. A global tap would also mute
        // source apps routed into BlackHole before Downmix can render them.
        tapUUID = UUID()
        let exclude: [AudioObjectID] = myProcessObjectID != kAudioObjectUnknown
            ? [myProcessObjectID] : []
        let tapDesc = CATapDescription(
            excludingProcesses: exclude,
            deviceUID: outputUID,
            stream: 0
        )
        tapDesc.uuid = tapUUID
        tapDesc.isMixdown = true
        tapDesc.isMono = false
        tapDesc.muteBehavior = .muted
        tapDesc.name = "EQForMac-Tap"

        tapID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateProcessTap(tapDesc, &tapID), "Failed to create process tap")

        // Tap stream format
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try caCheck(
            AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapFormat),
            "Failed to get tap format"
        )
        let channels = tapFormat.mChannelsPerFrame
        guard channels == 2 else {
            throw AudioError.message(
                "The output tap did not provide the requested stereo mixdown"
            )
        }
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32
        else {
            throw AudioError.message(
                "The output tap uses an unsupported audio format; Float32 PCM is required"
            )
        }

        // Prefer device native sample rate
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        try caCheck(
            AudioObjectGetPropertyData(
                outputDeviceID,
                &rateAddress,
                0,
                nil,
                &rateSize,
                &deviceRate
            ),
            "Failed to read output sample rate"
        )
        let rate = deviceRate > 0 ? deviceRate : tapFormat.mSampleRate
        sampleRate = rate

        os_log(
            .default, log: log,
            "starting EQ  device=%{public}@  rate=%.0f  ch=%u",
            outputDeviceName, rate, channels
        )

        // The aggregate only transports the tap. Physical playback belongs to
        // AVAudioEngine below, so adding the hardware as a subdevice would open
        // the same DAC twice and can fail with nonmixable devices.
        let aggregateUID = UUID().uuidString
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EQForMac-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]

        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(
            AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateDeviceID),
            "Failed to create aggregate device"
        )

        try await waitUntilDeviceIsAlive(aggregateDeviceID)
        try Task.checkCancellation()

        // Ring buffer + AVAudioEngine
        let ring = AudioRingBuffer(
            capacityFrames: Int(
                rate * latencyMode.capacityMilliseconds / 1_000
            ),
            channels: Int(channels),
            overrunBehavior: .discardStaleOnRead
        )
        ringBuffer = ring
        activeChannelCount = Int(channels)

        let avEngine = AVAudioEngine()

        // Route engine output to the real hardware device.
        var outputID = outputDeviceID
        let outputAU = avEngine.outputNode.audioUnit!
        try caCheck(
            AudioUnitSetProperty(
                outputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &outputID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "Failed to route processed audio to the output device"
        )

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: rate,
            channels: AVAudioChannelCount(channels)
        ) else {
            throw AudioError.message("Failed to create AVAudioFormat")
        }

        let processor = StereoProcessor(sampleRate: rate)
        stereoProcessor = processor
        updateStereoProcessorSettings()
        processor.scheduleGainRamp(
            to: 1,
            durationFrames: max(1, Int(rate * 0.02))
        )

        let analyzer = SpectrumAnalyzer(
            sampleRate: rate,
            channelCount: Int(channels)
        ) { [weak self] magnitudes in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.spectrumMagnitudes = magnitudes
            }
        }
        analyzer?.setMonitoringEnabled(spectrumMonitoringEnabled)
        spectrumAnalyzer = analyzer

        let biquad = BiquadProcessor(
            sampleRate: rate,
            channelCount: Int(channels)
        )
        biquad.update(
            bands: activePreset.bands,
            preampDB: activePreset.preampDB,
            bypassed: bypassed
        )
        biquadProcessor = biquad
        let context = AudioRenderContext(
            ringBuffer: ring,
            channelCount: Int(channels),
            scratchFrameCapacity: renderScratchFrameCapacity,
            targetFillFrames: Int(
                rate * latencyMode.targetMilliseconds / 1_000
            ),
            stereoProcessor: processor,
            biquadProcessor: biquad
        )
        renderContext = context
        let source = AVAudioSourceNode(format: format) {
            _, _, frameCount, audioBufferList in
            context.render(
                frameCount: frameCount,
                audioBufferList: audioBufferList
            )
        }
        sourceNode = source

        // Soft peak limiter to avoid clipping after boosts
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        let au = limiter.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        limiter.bypass = false
        limiterNode = limiter

        avEngine.attach(source)
        avEngine.attach(limiter)
        avEngine.connect(source, to: limiter, format: format)
        avEngine.connect(limiter, to: avEngine.outputNode, format: format)

        try avEngine.start()
        engine = avEngine

        // IOProc: normalize the tap's buffer layout into the ring buffer and
        // silence aggregate output (AVAudioEngine owns physical playback).
        let tapInput = TapInputContext(
            ringBuffer: ring,
            spectrumAnalyzer: analyzer,
            channelCount: Int(channels),
            scratchFrameCapacity: renderScratchFrameCapacity
        )
        tapInputContext = tapInput
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            tapInput.consume(inInputData)

            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            for i in 0..<outList.count {
                if let data = outList[i].mData {
                    memset(data, 0, Int(outList[i].mDataByteSize))
                }
            }
        }

        try caCheck(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock),
            "Failed to create IOProc"
        )
        try caCheck(
            AudioDeviceStart(aggregateDeviceID, procID),
            "Failed to start aggregate device"
        )

        isRunning = true
        startLatencyUpdates()
        analyzer?.start()
        // Real proof that system-audio capture is allowed (preflight can lie).
        PermissionMonitor.shared.markEngineSucceeded()
        onStateChange?()
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        restartGeneration &+= 1
        restartWorkItem?.cancel()
        restartWorkItem = nil
        tearDownAudioGraph()
    }

    private func tearDownAudioGraph(notify: Bool = true) {
        guard isRunning
                || engine != nil
                || tapID != kAudioObjectUnknown
                || aggregateDeviceID != kAudioObjectUnknown
        else {
            return
        }
        isRunning = false
        latencyTimer?.invalidate()
        latencyTimer = nil
        measuredLatencyMilliseconds = 0
        activeOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)

        if let procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.procID = nil
        }

        engine?.stop()

        spectrumAnalyzer?.stop()
        spectrumAnalyzer = nil
        spectrumMagnitudes = Array(
            repeating: 0,
            count: SpectrumAnalyzer.binCount
        )
        stereoProcessor = nil
        biquadProcessor = nil
        ringBuffer = nil

        engine = nil
        limiterNode = nil
        sourceNode = nil
        renderContext = nil
        tapInputContext = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        if notify {
            onStateChange?()
        }
    }

    // MARK: - EQ application

    private func applyEQ() {
        biquadProcessor?.update(
            bands: activePreset.bands,
            preampDB: activePreset.preampDB,
            bypassed: bypassed
        )
        // Keep protection active on both sides of A/B. The bypass path still
        // applies the preset preamp, so wet and dry are level matched.
        limiterNode?.bypass = false
    }

    private func updateStereoProcessorSettings() {
        stereoProcessor?.update(
            settings: StereoProcessor.Settings(
                crossfeedIntensity: crossfeedIntensity,
                bypassed: bypassed
            )
        )
    }

    private func waitUntilDeviceIsAlive(_ deviceID: AudioDeviceID) async throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<30 {
            try Task.checkCancellation()
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try caCheck(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    &alive
                ),
                "Failed to query aggregate-device readiness"
            )
            if alive != 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AudioError.message("Timed out waiting for the aggregate audio device")
    }

    private func startLatencyUpdates() {
        latencyTimer?.invalidate()
        latencyTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard isAudioDeviceAlive(self.activeOutputDeviceID) else {
                    let name = self.outputDeviceName
                    self.stop()
                    self.errorMessage =
                        "\(name) disconnected. Reconnect it, then toggle EQ off and on."
                    self.onStateChange?()
                    return
                }
                guard let ringBuffer = self.ringBuffer,
                      self.sampleRate > 0
                else { return }
                let queuedFrames =
                    Double(ringBuffer.availableSamples)
                    / Double(max(1, self.activeChannelCount))
                // The Apple peak limiter contributes its configured 7 ms
                // look-ahead in addition to the queue.
                self.measuredLatencyMilliseconds =
                    queuedFrames / self.sampleRate * 1_000 + 7
            }
        }
    }

    // MARK: - Device changes

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleDefaultDeviceChange()
            }
        }
        deviceChangeListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func installOutputFormatListener(for deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        if observedOutputDeviceID == deviceID, outputFormatListener != nil {
            return
        }

        removeOutputFormatListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleOutputFormatChange()
            }
        }
        outputFormatListener = block
        observedOutputDeviceID = deviceID

        for var address in outputFormatPropertyAddresses() {
            AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                block
            )
        }
    }

    private func removeOutputFormatListener() {
        guard observedOutputDeviceID != kAudioObjectUnknown,
              let block = outputFormatListener
        else {
            return
        }
        for var address in outputFormatPropertyAddresses() {
            AudioObjectRemovePropertyListenerBlock(
                observedOutputDeviceID,
                &address,
                DispatchQueue.main,
                block
            )
        }
        outputFormatListener = nil
        observedOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func outputFormatPropertyAddresses() -> [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
    }

    private func refreshOutputDeviceInfo(
        _ deviceID: AudioDeviceID,
        notify: Bool
    ) {
        let previousUID = outputDeviceUID
        let previousName = outputDeviceName
        do {
            let uid = try getDeviceUID(deviceID)
            let name = try getDeviceName(deviceID)
            outputDeviceUID = uid
            outputDeviceName = name
            if notify, uid != previousUID || name != previousName {
                onOutputDeviceChange?(uid, name)
            }
        } catch {
            // Preserve the last valid identity while a Bluetooth device is
            // still publishing its Core Audio properties.
        }
    }

    private func handleDefaultDeviceChange() {
        do {
            let id = try getRoutableOutputDeviceID()
            refreshOutputDeviceInfo(id, notify: true)
            installOutputFormatListener(for: id)
        } catch {
            // Keep the prior identity until Core Audio finishes reconnecting.
        }

        if isRunning {
            scheduleRestart(reconnectDelay: 0.35)
        } else {
            onStateChange?()
        }
    }

    private func handleOutputFormatChange() {
        guard isRunning else { return }
        // Stream-format notifications frequently repeat without changing the
        // rate that defines this graph. Ignore those instead of rebuilding the
        // tap and aggregate device.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            observedOutputDeviceID,
            &address,
            0,
            nil,
            &size,
            &rate
        )
        guard status == noErr, rate > 0, abs(rate - sampleRate) >= 1 else {
            return
        }
        // AVAudioSourceNode's format is immutable, so a genuine rate change
        // still requires a debounced graph rebuild.
        scheduleRestart(reconnectDelay: 0.12)
    }

    private func scheduleRestart(reconnectDelay: TimeInterval) {
        restartGeneration &+= 1
        let generation = restartGeneration
        restartWorkItem?.cancel()

        let fadeDuration: TimeInterval = 0.02
        stereoProcessor?.scheduleGainRamp(
            to: 0,
            durationFrames: max(1, Int(sampleRate * fadeDuration))
        )

        let fadeWork = DispatchWorkItem { [weak self] in
            guard let self, self.restartGeneration == generation else { return }
            self.tearDownAudioGraph()

            let restartWork = DispatchWorkItem { [weak self] in
                guard let self, self.restartGeneration == generation else { return }
                self.restartWorkItem = nil
                self.setEnabled(true)
            }
            self.restartWorkItem = restartWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + reconnectDelay,
                execute: restartWork
            )
        }
        restartWorkItem = fadeWork
        DispatchQueue.main.asyncAfter(
            deadline: .now() + fadeDuration + 0.005,
            execute: fadeWork
        )
    }
}
