import Accelerate
import AVFAudio
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os.log

private let log = OSLog(subsystem: "com.eqformac.app", category: "audio")

// MARK: - Real-time callback state (must be free of actor isolation)

nonisolated(unsafe) private var rtRingBuffer: AudioRingBuffer?
nonisolated(unsafe) private var rtChannelCount: UInt32 = 2
nonisolated(unsafe) private var rtScratchBuffer: UnsafeMutablePointer<Float>?
nonisolated(unsafe) private var rtScratchCapacity: Int = 0
nonisolated(unsafe) private var rtStereoProcessor: StereoProcessor?

/// AVAudioSourceNode render block: pull interleaved samples from the ring buffer
/// and deinterleave into the engine's non-interleaved format.
private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    let channels = Int(rtChannelCount)
    let frames = Int(frameCount)
    let interleavedCount = frames * channels
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)

    guard let ringBuf = rtRingBuffer,
          let scratch = rtScratchBuffer,
          rtScratchCapacity >= interleavedCount
    else {
        for buffer in bufferList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }

    let read = ringBuf.read(scratch, count: interleavedCount)
    if read < interleavedCount {
        memset(
            scratch.advanced(by: read),
            0,
            (interleavedCount - read) * MemoryLayout<Float>.stride
        )
    }

    var unity: Float = 1
    for channelIndex in 0..<bufferList.count {
        guard let outData = bufferList[channelIndex].mData?.assumingMemoryBound(to: Float.self)
        else { continue }
        let sourceChannel = min(channelIndex, channels - 1)
        vDSP_vsmul(
            scratch.advanced(by: sourceChannel),
            vDSP_Stride(channels),
            &unity,
            outData,
            1,
            vDSP_Length(frames)
        )
    }
    rtStereoProcessor?.process(bufferList, frameCount: frames)
    return noErr
}

// MARK: - AudioEngine

/// System-wide EQ engine using Core Audio Process Taps (macOS 14.2+).
///
/// Pipeline:
///   Apps → (muted) CATap → Aggregate Device IOProc → Ring Buffer
///        → AVAudioSourceNode/Stereo Stage → AVAudioUnitEQ → Peak Limiter
///        → Output Device
@available(macOS 14.2, *)
@MainActor
final class AudioEngine: ObservableObject {
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
    @Published private(set) var stereoWidth: Float = 1
    @Published private(set) var balance: Float = 0
    @Published private(set) var monoEnabled = false
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
    private var eqNode: AVAudioUnitEQ?
    private var limiterNode: AVAudioUnitEffect?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: AudioRingBuffer?
    private var spectrumAnalyzer: SpectrumAnalyzer?
    private var stereoProcessor: StereoProcessor?
    private var tapUUID = UUID()
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var outputFormatListener: AudioObjectPropertyListenerBlock?
    private var observedOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var restartWorkItem: DispatchWorkItem?
    private var restartGeneration: UInt64 = 0
    private var spectrumMonitoringEnabled = false
    private var activePreset: EQPreset = .flat()
    // Imported presets commonly use 10 bands; non-destructive curve edits add
    // overlay filters instead of replacing them, so leave ample headroom.
    private let maxBandSlots = 64
    private let renderScratchFrameCapacity = 16_384
    private var sampleRate: Double = 48_000

    var onStateChange: (() -> Void)?
    var onOutputDeviceChange: ((_ uid: String, _ name: String) -> Void)?

    init() {
        do {
            let id = try getDefaultOutputDeviceID()
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
    }

    // MARK: - Public control

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try start()
                errorMessage = nil
            } catch {
                tearDownAudioGraph(notify: false)
                errorMessage = error.localizedDescription
                isRunning = false
                os_log(.error, log: log, "start failed: %{public}@", error.localizedDescription)
            }
        } else {
            stop()
        }
        onStateChange?()
    }

    func setSpectrumMonitoringEnabled(_ enabled: Bool) {
        spectrumMonitoringEnabled = enabled
        spectrumAnalyzer?.setMonitoringEnabled(enabled)
    }

    func setCrossfeedIntensity(_ intensity: Float) {
        crossfeedIntensity = max(0, min(1, intensity))
        updateStereoProcessorSettings()
    }

    func setStereoWidth(_ width: Float) {
        stereoWidth = max(0, min(2, width))
        updateStereoProcessorSettings()
    }

    func setBalance(_ balance: Float) {
        self.balance = max(-1, min(1, balance))
        updateStereoProcessorSettings()
    }

    func setMonoEnabled(_ enabled: Bool) {
        monoEnabled = enabled
        updateStereoProcessorSettings()
    }

    func apply(preset: EQPreset) {
        activePreset = preset
        applyEQ()
        onStateChange?()
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRunning else { return }
        errorMessage = nil

        let outputDeviceID = try getDefaultOutputDeviceID()
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
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translateAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &myPID,
            &processObjectSize,
            &myProcessObjectID
        )

        // Create muted global stereo tap.
        tapUUID = UUID()
        let exclude: [AudioObjectID] = myProcessObjectID != kAudioObjectUnknown
            ? [myProcessObjectID] : []
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        tapDesc.uuid = tapUUID
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
        guard channels > 0 else {
            throw AudioError.message("Tap reported no audio channels")
        }

        // Prefer device native sample rate
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(outputDeviceID, &rateAddress, 0, nil, &rateSize, &deviceRate)
        let rate = deviceRate > 0 ? deviceRate : tapFormat.mSampleRate
        sampleRate = rate

        os_log(
            .default, log: log,
            "starting EQ  device=%{public}@  rate=%.0f  ch=%u",
            outputDeviceName, rate, channels
        )

        // Aggregate device: hardware output + tap (tap list must be present at create time).
        let aggregateUID = UUID().uuidString
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EQForMac-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
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

        // Wait until device is alive
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<30 {
            var alive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(aggregateDeviceID, &aliveAddress, 0, nil, &aliveSize, &alive)
            if alive != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Ring buffer + AVAudioEngine
        let ring = AudioRingBuffer(
            capacityFrames: Int(rate * 0.5),
            channels: Int(channels),
            overrunBehavior: .discardStaleOnRead
        )
        ringBuffer = ring
        rtRingBuffer = ring
        rtChannelCount = channels

        let requiredScratchSamples = renderScratchFrameCapacity * Int(channels)
        let oldScratch = rtScratchBuffer
        rtScratchBuffer = .allocate(capacity: requiredScratchSamples)
        rtScratchBuffer?.initialize(repeating: 0, count: requiredScratchSamples)
        rtScratchCapacity = requiredScratchSamples
        oldScratch?.deallocate()

        let avEngine = AVAudioEngine()

        // Route engine output to the real hardware device.
        var outputID = outputDeviceID
        let outputAU = avEngine.outputNode.audioUnit!
        AudioUnitSetProperty(
            outputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &outputID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: rate,
            channels: AVAudioChannelCount(channels)
        ) else {
            throw AudioError.message("Failed to create AVAudioFormat")
        }

        let processor = StereoProcessor(sampleRate: rate)
        stereoProcessor = processor
        rtStereoProcessor = processor
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

        let source = AVAudioSourceNode(format: format, renderBlock: renderCallback)
        sourceNode = source

        let eq = AVAudioUnitEQ(numberOfBands: maxBandSlots)
        configureEQBands(eq, with: activePreset)
        eq.globalGain = max(-24, min(6, activePreset.preampDB))
        eq.bypass = bypassed || activePreset.isFlat
        eqNode = eq

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
        limiter.bypass = bypassed
        limiterNode = limiter

        avEngine.attach(source)
        avEngine.attach(eq)
        avEngine.attach(limiter)
        avEngine.connect(source, to: eq, format: format)
        avEngine.connect(eq, to: limiter, format: format)
        avEngine.connect(limiter, to: avEngine.outputNode, format: format)

        try avEngine.start()
        engine = avEngine

        // IOProc: write tap audio into ring buffer; silence aggregate output
        // (playback is done by AVAudioEngine on the real device).
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            guard let ringBuf = rtRingBuffer else { return }

            let inList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            for i in 0..<inList.count {
                guard let data = inList[i].mData else { continue }
                let sampleCount = Int(inList[i].mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                ringBuf.write(samples, count: sampleCount)
                analyzer?.submitInterleaved(samples, count: sampleCount)
            }

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
        analyzer?.start()
        // Real proof that system-audio capture is allowed (preflight can lie).
        PermissionMonitor.shared.markEngineSucceeded()
        onStateChange?()
    }

    func stop() {
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

        if let procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.procID = nil
        }

        engine?.stop()
        rtRingBuffer = nil
        rtStereoProcessor = nil

        spectrumAnalyzer?.stop()
        spectrumAnalyzer = nil
        spectrumMagnitudes = Array(
            repeating: 0,
            count: SpectrumAnalyzer.binCount
        )
        stereoProcessor = nil
        ringBuffer = nil

        let oldScratch = rtScratchBuffer
        rtScratchBuffer = nil
        rtScratchCapacity = 0
        oldScratch?.deallocate()

        engine = nil
        eqNode = nil
        limiterNode = nil
        sourceNode = nil

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
        if let eq = eqNode {
            configureEQBands(eq, with: activePreset)
            eq.globalGain = max(-24, min(6, activePreset.preampDB))
            eq.bypass = bypassed || activePreset.isFlat
        }
        limiterNode?.bypass = bypassed
    }

    private func updateStereoProcessorSettings() {
        stereoProcessor?.update(
            settings: StereoProcessor.Settings(
                crossfeedIntensity: crossfeedIntensity,
                stereoWidth: stereoWidth,
                balance: balance,
                monoEnabled: monoEnabled,
                bypassed: bypassed
            )
        )
    }

    private func configureEQBands(_ eq: AVAudioUnitEQ, with preset: EQPreset) {
        let bands = preset.bands
        for i in 0..<eq.bands.count {
            let slot = eq.bands[i]
            if i < bands.count {
                let band = bands[i]
                slot.filterType = band.filterType.avType
                slot.frequency = max(20, min(20_000, band.frequency))
                slot.bandwidth = max(0.05, min(5.0, band.bandwidth))
                slot.gain = max(-24, min(24, band.gain))
                slot.bypass = !band.enabled
            } else {
                slot.bypass = true
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
            let id = try getDefaultOutputDeviceID()
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
        // Debounce bursts of nominal-rate and stream-format notifications.
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
