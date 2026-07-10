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

/// AVAudioSourceNode render block: pull interleaved samples from the ring buffer
/// and deinterleave into the engine's non-interleaved format.
private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    guard let ringBuf = rtRingBuffer else { return noErr }

    let channels = Int(rtChannelCount)
    let frames = Int(frameCount)
    let interleavedCount = frames * channels
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)

    if rtScratchCapacity < interleavedCount {
        rtScratchBuffer?.deallocate()
        rtScratchBuffer = .allocate(capacity: interleavedCount)
        rtScratchCapacity = interleavedCount
    }
    guard let scratch = rtScratchBuffer else { return noErr }

    let read = ringBuf.read(scratch, count: interleavedCount)
    if read < interleavedCount {
        scratch.advanced(by: read).initialize(repeating: 0, count: interleavedCount - read)
    }

    for channelIndex in 0..<bufferList.count {
        guard let outData = bufferList[channelIndex].mData?.assumingMemoryBound(to: Float.self)
        else { continue }
        for f in 0..<frames {
            let srcIndex = f * channels + min(channelIndex, channels - 1)
            outData[f] = scratch[srcIndex]
        }
    }
    return noErr
}

// MARK: - AudioEngine

/// System-wide EQ engine using Core Audio Process Taps (macOS 14.2+).
///
/// Pipeline:
///   Apps → (muted) CATap → Aggregate Device IOProc → Ring Buffer
///        → AVAudioSourceNode → AVAudioUnitEQ → Peak Limiter → Output Device
@available(macOS 14.2, *)
@MainActor
final class AudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var outputDeviceName = "Unknown"
    @Published private(set) var errorMessage: String?
    @Published var bypassed = false {
        didSet { applyEQ() }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var eqNode: AVAudioUnitEQ?
    private var limiterNode: AVAudioUnitEffect?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: AudioRingBuffer?
    private var tapUUID = UUID()
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var activePreset: EQPreset = .flat()
    private var maxBandSlots = 31
    private var sampleRate: Double = 48_000

    var onStateChange: (() -> Void)?

    init() {
        do {
            let id = try getDefaultOutputDeviceID()
            outputDeviceName = try getDeviceName(id)
        } catch {
            outputDeviceName = "Unknown"
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
    }

    // MARK: - Public control

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try start()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                isRunning = false
                os_log(.error, log: log, "start failed: %{public}@", error.localizedDescription)
            }
        } else {
            stop()
        }
        onStateChange?()
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
        outputDeviceName = try getDeviceName(outputDeviceID)

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

        // Prefer device native sample rate
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
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
        let ring = AudioRingBuffer(capacityFrames: Int(rate * 0.5), channels: Int(channels))
        ringBuffer = ring
        rtRingBuffer = ring
        rtChannelCount = channels

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

        let source = AVAudioSourceNode(format: format, renderBlock: renderCallback)
        sourceNode = source

        let eq = AVAudioUnitEQ(numberOfBands: maxBandSlots)
        configureEQBands(eq, with: activePreset)
        eq.globalGain = activePreset.preampDB
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
                ringBuf.write(data.assumingMemoryBound(to: Float.self), count: sampleCount)
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
        // Real proof that system-audio capture is allowed (preflight can lie).
        PermissionMonitor.shared.markEngineSucceeded()
        onStateChange?()
    }

    func stop() {
        guard isRunning || engine != nil || tapID != kAudioObjectUnknown else { return }
        isRunning = false

        rtRingBuffer = nil
        ringBuffer = nil

        if let procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.procID = nil
        }

        engine?.stop()
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

        onStateChange?()
    }

    // MARK: - EQ application

    private func applyEQ() {
        guard let eq = eqNode else { return }
        configureEQBands(eq, with: activePreset)
        eq.globalGain = activePreset.preampDB
        eq.bypass = bypassed || activePreset.isFlat
        limiterNode?.bypass = bypassed
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
            DispatchQueue.main.async {
                guard let self else { return }
                Task { @MainActor in
                    self.handleDefaultDeviceChange()
                }
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

    private func handleDefaultDeviceChange() {
        // Refresh device name; restart if EQ is running so we follow the new output.
        do {
            let id = try getDefaultOutputDeviceID()
            outputDeviceName = try getDeviceName(id)
        } catch {
            // keep previous name
        }

        if isRunning {
            stop()
            // Small delay helps Bluetooth devices finish reconnection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.setEnabled(true)
            }
        } else {
            onStateChange?()
        }
    }
}
