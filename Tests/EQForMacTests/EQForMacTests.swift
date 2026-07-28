import AVFAudio
import Foundation
import Testing
@testable import EQForMac

@Suite("EQ models and response")
struct EQModelAndResponseTests {
    @Test
    func presetRoundTripPreservesFields() throws {
        let preset = EQPreset(
            id: #require(UUID(uuidString: "A48583DC-C024-4467-9ED2-8A3B9EB19D4A")),
            name: "Reference",
            preampDB: -4.5,
            bands: [
                EQBand(
                    filterType: .lowShelf,
                    frequency: 105,
                    gain: 4.25,
                    bandwidth: 0.8
                ),
                EQBand(
                    filterType: .notch,
                    frequency: 7_500,
                    bandwidth: 0.12,
                    enabled: false
                ),
            ],
            bandMode: .parametric,
            isHeadphone: true,
            source: "Unit test"
        )

        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(EQPreset.self, from: encoded)
        #expect(decoded == preset)
    }

    @Test
    func legacyPreferencesUseSafeDefaults() throws {
        let json = """
        {
          "eqEnabled": true,
          "bandMode": "10-band",
          "selectedPresetName": "Bass Boost",
          "customGains": [1, 2, 3],
          "preampDB": -2
        }
        """
        let data = #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(decoded.eqEnabled)
        #expect(decoded.selectedPresetName == "Bass Boost")
        #expect(!decoded.autoPreampEnabled)
        #expect(!decoded.launchAtLogin)
        #expect(decoded.selectedUserPresetID == nil)
    }

    @Test
    func highQBandwidthIsNotClamped() {
        let highQ = EQBand.bandwidthFromQ(1_000)
        #expect(highQ > 0)
        #expect(highQ < 0.05)
    }

    @Test
    func dryComparisonDifferenceIgnoresSharedPreampButDetectsFilters() {
        var preampOnly = EQPreset.flat()
        preampOnly.preampDB = -9
        var shaped = preampOnly
        shaped.bands[5].gain = 6

        #expect(!EQPreset.flat().changesFrequencyResponse)
        #expect(!preampOnly.changesFrequencyResponse)
        #expect(shaped.changesFrequencyResponse)
    }

    @Test
    func exactParametricResponseMatchesAuthoredPeak() {
        let bands = [
            EQBand(frequency: 1_000, gain: 6, bandwidth: 0.5),
        ]
        let peak = EQResponse.magnitudeDB(bands: bands, at: 1_000)
        let farAway = EQResponse.magnitudeDB(bands: bands, at: 100)

        #expect(abs(peak - 6) < 0.01)
        #expect(abs(farAway) < 0.5)
    }

    @Test
    func headroomUsesCombinedExactResponse() {
        let bands = [
            EQBand(frequency: 1_000, gain: 4, bandwidth: 1.2),
            EQBand(frequency: 1_000, gain: 3, bandwidth: 1.2),
        ]
        let maximum = EQHeadroomCalculator.maximumBoost(for: bands)
        let preamp = EQHeadroomCalculator.recommendedPreamp(for: bands)

        #expect(abs(maximum - 7) < 0.05)
        #expect(preamp <= -7.25)
        #expect(preamp * 2 == (preamp * 2).rounded())
    }

    @Test
    func apoExportRoundTrips() throws {
        let preset = EQPreset(
            name: "Export",
            preampDB: -5.5,
            bands: [
                EQBand(frequency: 120, gain: 3, bandwidth: 0.8),
                EQBand(
                    filterType: .highShelf,
                    frequency: 8_000,
                    gain: -2,
                    bandwidth: 0.7
                ),
            ],
            bandMode: .parametric
        )
        let text = EqualizerAPOExporter.export(preset)
        let parsed = #require(EqualizerAPOParser.parse(text: text))

        #expect(abs(parsed.preampDB - preset.preampDB) < 0.01)
        #expect(parsed.bands.count == 2)
        #expect(parsed.bands.map(\.filterType) == [.parametric, .highShelf])
        #expect(abs(parsed.bands[0].frequency - 120) < 0.01)
    }
}

@Suite("Equalizer APO parser")
struct APOParserTests {
    @Test
    func parsesTypesStateAndJunkLines() throws {
        let text = """
        # Exported by an equalizer
        Preamp: -6.25 dB
        This line should be ignored.
        Filter 1: ON PK Fc 100 Hz Gain 3.5 dB Q 1.00
        Filter 2: ON LSC Fc 80 Hz Gain 2.0 dB Q 0.70
        Filter 3: OFF HSC Fc 8000 Hz Gain -1.5 dB Q 0.80
        Filter 4: ON LPQ Fc 19000 Hz Q 0.71
        """
        let parsed = #require(EqualizerAPOParser.parse(text: text))

        #expect(abs(parsed.preampDB + 6.25) < 0.001)
        #expect(parsed.bands.count == 4)
        #expect(
            parsed.bands.map(\.filterType)
                == [.parametric, .lowShelf, .highShelf, .lowPass]
        )
        #expect(!parsed.bands[2].enabled)
    }

    @Test
    func preservesNarrowAndWideBandwidths() throws {
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 20
        Filter 2: ON PK Fc 2000 Hz Gain -2 dB BW Oct 8
        """
        let parsed = #require(EqualizerAPOParser.parse(text: text))

        #expect(parsed.bands[0].bandwidth < 0.1)
        #expect(parsed.bands[1].bandwidth == 8)
    }
}

@Suite("Audio ring buffer")
struct RingBufferTests {
    @Test
    func maintainsOrderAcrossWrap() {
        let buffer = AudioRingBuffer(capacityFrames: 4, channels: 1)
        write([1, 2, 3], to: buffer)
        #expect(read(2, from: buffer) == [1, 2])
        write([4, 5, 6], to: buffer)
        #expect(read(8, from: buffer) == [3, 4, 5, 6])
    }

    @Test
    func playbackOverrunTrimsStaleBacklog() {
        let buffer = AudioRingBuffer(
            capacityFrames: 4,
            channels: 1,
            overrunBehavior: .discardStaleOnRead
        )
        write([1, 2, 3, 4, 5, 6], to: buffer)
        #expect(read(2, from: buffer) == [3, 4])
    }

    private func write(_ samples: [Float], to buffer: AudioRingBuffer) {
        samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                _ = buffer.write(baseAddress, count: pointer.count)
            }
        }
    }

    private func read(_ count: Int, from buffer: AudioRingBuffer) -> [Float] {
        var destination = Array(repeating: Float.nan, count: count)
        let samplesRead = destination.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return buffer.read(baseAddress, count: pointer.count)
        }
        return Array(destination.prefix(samplesRead))
    }
}

@Suite("Render DSP and UI geometry")
struct RenderDSPTests {
    @Test
    func neutralStereoStageLeavesSamplesUnchanged() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 1)
        let result = process(
            left: [1, -0.5],
            right: [-1, 0.25]
        ) {
            processor.process($0, frameCount: 2)
        }

        #expect(result.left == [1, -0.5])
        #expect(result.right == [-1, 0.25])
    }

    @Test
    func stereoGainRampReachesItsTarget() {
        let processor = StereoProcessor(sampleRate: 48_000, initialGain: 0)
        processor.scheduleGainRamp(to: 1, durationFrames: 4)
        let result = process(
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ) {
            processor.process($0, frameCount: 4)
        }

        expectEqual(result.left, [0.25, 0.5, 0.75, 1])
        expectEqual(result.right, [0.25, 0.5, 0.75, 1])
    }

    @Test
    func acceleratedBiquadMatchesExactPeakResponse() {
        let sampleRate = 48_000.0
        let frameCount = 4_800
        let input = (0..<frameCount).map {
            0.1 * sin(2 * Float.pi * 1_000 * Float($0) / Float(sampleRate))
        }
        let processor = BiquadProcessor(sampleRate: sampleRate, channelCount: 2)
        processor.update(
            bands: [EQBand(frequency: 1_000, gain: 6, bandwidth: 0.5)],
            preampDB: 0,
            bypassed: false
        )
        let result = process(left: input, right: input) {
            processor.process($0, frameCount: frameCount)
        }

        let settled = result.left.dropFirst(1_000)
        let meanSquare = settled.reduce(Float(0)) { $0 + $1 * $1 }
            / Float(settled.count)
        let rms = sqrt(meanSquare)
        let expected = 0.1 * pow(Float(10), 6 / 20) / sqrt(2)
        #expect(abs(rms - expected) < 0.002)
    }

    @Test
    func flatPresetSurvivesRepeatedABTransitions() {
        let sampleRate = 48_000.0
        let input = (0..<512).map {
            0.2 * sin(2 * Float.pi * 440 * Float($0) / Float(sampleRate))
        }
        let preset = EQPreset.flat()
        let processor = BiquadProcessor(
            sampleRate: sampleRate,
            channelCount: 2
        )

        for bypassed in [false, true, false] {
            processor.update(
                bands: preset.bands,
                preampDB: preset.preampDB,
                bypassed: bypassed
            )
            let result = process(left: input, right: input) {
                processor.process($0, frameCount: input.count)
            }

            #expect(result.left == input)
            #expect(result.right == input)
            #expect(result.left.allSatisfy(\.isFinite))
        }
    }

    @Test
    func nonFlatABUsesProcessedAndLevelMatchedDryPaths() {
        let sampleRate = 48_000.0
        let frameCount = 4_800
        let input = (0..<frameCount).map {
            0.1 * sin(2 * Float.pi * 1_000 * Float($0) / Float(sampleRate))
        }
        let bands = [
            EQBand(frequency: 1_000, gain: 9, bandwidth: 0.5),
        ]
        let preampDB: Float = -9

        let wetProcessor = BiquadProcessor(
            sampleRate: sampleRate,
            channelCount: 2
        )
        wetProcessor.update(
            bands: bands,
            preampDB: preampDB,
            bypassed: false
        )
        let wet = process(left: input, right: input) {
            wetProcessor.process($0, frameCount: frameCount)
        }.left

        let dryProcessor = BiquadProcessor(
            sampleRate: sampleRate,
            channelCount: 2
        )
        dryProcessor.update(
            bands: bands,
            preampDB: preampDB,
            bypassed: true
        )
        let dry = process(left: input, right: input) {
            dryProcessor.process($0, frameCount: frameCount)
        }.left

        let expectedDryGain = pow(Float(10), preampDB / 20)
        for (actual, source) in zip(dry, input) {
            #expect(abs(actual - source * expectedDryGain) < 0.000_01)
        }
        let settledDifference = zip(
            wet.dropFirst(1_000),
            dry.dropFirst(1_000)
        ).reduce(Float(0)) { maximum, pair in
            max(maximum, abs(pair.0 - pair.1))
        }
        #expect(settledDifference > 0.03)
    }

    @Test
    func builtInPresetsProduceFiniteAudibleAudio() {
        let sampleRate = 48_000.0
        let input = (0..<512).map {
            0.2 * sin(2 * Float.pi * 440 * Float($0) / Float(sampleRate))
        }

        for preset in EQPreset.builtInPresets {
            let processor = BiquadProcessor(
                sampleRate: sampleRate,
                channelCount: 2
            )
            processor.update(
                bands: preset.bands,
                preampDB: preset.preampDB,
                bypassed: false
            )
            let result = process(left: input, right: input) {
                processor.process($0, frameCount: input.count)
            }
            let energy = result.left.reduce(Float(0)) {
                $0 + $1 * $1
            }

            #expect(
                result.left.allSatisfy(\.isFinite),
                "\(preset.name) emitted non-finite audio"
            )
            #expect(
                energy > 0.001,
                "\(preset.name) unexpectedly emitted silence"
            )
        }
    }

    @Test
    func renderContextWaitsForItsLatencyTarget() {
        let ring = AudioRingBuffer(
            capacityFrames: 16,
            channels: 2
        )
        let stereo = StereoProcessor(sampleRate: 48_000, initialGain: 1)
        let biquad = BiquadProcessor(sampleRate: 48_000, channelCount: 2)
        let context = AudioRenderContext(
            ringBuffer: ring,
            channelCount: 2,
            scratchFrameCapacity: 8,
            targetFillFrames: 2,
            stereoProcessor: stereo,
            biquadProcessor: biquad
        )

        write([1, 10, 2, 20], to: ring)
        let priming = process(left: [9, 9], right: [9, 9]) {
            _ = context.render(
                frameCount: 2,
                audioBufferList: $0.unsafeMutablePointer
            )
        }
        #expect(priming.left == [0, 0])
        #expect(priming.right == [0, 0])

        write([3, 30, 4, 40], to: ring)
        let rendered = process(left: [0, 0], right: [0, 0]) {
            _ = context.render(
                frameCount: 2,
                audioBufferList: $0.unsafeMutablePointer
            )
        }
        #expect(rendered.left == [1, 2])
        #expect(rendered.right == [10, 20])
        #expect(ring.availableSamples == 4)
    }

    @Test
    func curveGeometryRoundTripsLogFrequencyAndGain() {
        let plot = CGRect(x: 30, y: 8, width: 420, height: 180)
        for frequency: Float in [20, 100, 1_000, 10_000, 20_000] {
            let x = EQCurveGeometry.x(for: frequency, in: plot)
            let roundTrip = EQCurveGeometry.frequency(atX: x, in: plot)
            #expect(abs(roundTrip - frequency) / frequency < 0.000_1)
        }
        let midpoint = EQCurveGeometry.frequency(atX: plot.midX, in: plot)
        #expect(abs(midpoint - sqrt(20 * 20_000)) < 0.01)
        let y = EQCurveGeometry.y(for: 6, in: plot, range: -12...12)
        #expect(
            abs(EQCurveGeometry.gain(atY: y, in: plot, range: -12...12) - 6)
                < 0.000_1
        )
    }

    @Test
    func spectrumBallisticsAreTimeNormalized() {
        let oneFrame = SpectrumAnalyzer.smoothingCoefficient(
            frameInterval: 0.033,
            timeConstant: 0.300
        )
        let oneThirdFrame = SpectrumAnalyzer.smoothingCoefficient(
            frameInterval: 0.011,
            timeConstant: 0.300
        )
        let composed = 1 - pow(1 - oneThirdFrame, 3)
        #expect(abs(oneFrame - composed) < 0.000_01)
    }

    private func process(
        left: [Float],
        right: [Float],
        body: (UnsafeMutableAudioBufferListPointer) -> Void
    ) -> (left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        var left = left
        var right = right
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                let buffers = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(buffers.unsafeMutablePointer) }
                buffers.count = 2
                buffers[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(
                        leftBuffer.count * MemoryLayout<Float>.stride
                    ),
                    mData: leftBuffer.baseAddress
                )
                buffers[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(
                        rightBuffer.count * MemoryLayout<Float>.stride
                    ),
                    mData: rightBuffer.baseAddress
                )
                body(buffers)
            }
        }
        return (left, right)
    }

    private func write(_ samples: [Float], to ring: AudioRingBuffer) {
        samples.withUnsafeBufferPointer {
            if let baseAddress = $0.baseAddress {
                _ = ring.write(baseAddress, count: $0.count)
            }
        }
    }

    private func expectEqual(
        _ actual: [Float],
        _ expected: [Float],
        accuracy: Float = 0.000_01
    ) {
        #expect(actual.count == expected.count)
        for (actual, expected) in zip(actual, expected) {
            #expect(abs(actual - expected) <= accuracy)
        }
    }
}

@Suite("Preset store persistence")
@MainActor
struct PresetStoreTests {
    @Test
    func storeOwnsFavoritesAndDeviceProfiles() throws {
        let suite = "EQForMacTests.\(UUID().uuidString)"
        let defaults = #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PresetStore(userDefaults: defaults)
        let preset = EQPreset.graphic(
            name: "Working curve",
            mode: .ten,
            gains: [1, 2, 3, 2, 1, 0, -1, -2, -1, 0],
            preamp: -3
        )
        let saved = try store.saveUserPreset(preset, named: "Desk")
        _ = store.setUserPresetFavorite(id: saved.id, isFavorite: true)
        _ = try store.saveDeviceProfile(
            deviceUID: "test-output",
            deviceName: "Test Output",
            preset: saved.preset
        )

        let reloaded = PresetStore(userDefaults: defaults)
        #expect(reloaded.favoriteUserPresets.map(\.id) == [saved.id])
        #expect(reloaded.deviceProfile(for: "test-output")?.preset.name == "Desk")
        #expect(reloaded.catalogCount == 6_808)
        #expect(
            reloaded.searchCatalog("wh1000xm5", limit: 10).contains {
                $0.name.localizedCaseInsensitiveContains("WH-1000XM5")
            }
        )
    }
}
