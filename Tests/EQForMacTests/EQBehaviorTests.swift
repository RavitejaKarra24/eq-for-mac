import Foundation
import XCTest
@testable import EQForMac

@available(macOS 14.2, *)
final class EQBehaviorTests: XCTestCase {
    @MainActor
    func testParametricProjectionIsStableAndBounded() {
        let bands = [
            EQBand(frequency: 62, gain: 6, bandwidth: 1),
            EQBand(frequency: 1_000, gain: -3, bandwidth: 0.8),
            EQBand(frequency: 8_000, gain: 18, bandwidth: 1),
        ]

        let first = EQViewModel.approximateGains(from: bands, mode: .ten)
        let second = EQViewModel.approximateGains(from: bands, mode: .ten)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, EQBandMode.ten.bandCount)
        XCTAssertTrue(first.allSatisfy { (-12...12).contains($0) })
        XCTAssertGreaterThan(first[1], 0)
        XCTAssertLessThan(first[5], 0)
        XCTAssertEqual(first[8], 12)
    }

    @MainActor
    func testGraphicModeResamplingPreservesFrequencyLocation() {
        var tenBand = Array(repeating: Float(0), count: EQBandMode.ten.bandCount)
        tenBand[5] = 6 // 1 kHz

        let fifteenBand = EQViewModel.resampleGraphicGains(
            tenBand,
            from: EQBandMode.ten.frequencies,
            to: EQBandMode.fifteen.frequencies
        )

        XCTAssertEqual(fifteenBand.count, EQBandMode.fifteen.bandCount)
        XCTAssertEqual(fifteenBand[8], 6, accuracy: 0.001) // still 1 kHz
        XCTAssertEqual(fifteenBand[5], 0, accuracy: 0.001) // 250 Hz is not shifted
    }

    func testHeadroomCalculatorAccountsForSummedOverlappingBoosts() {
        let bands = [
            EQBand(frequency: 1_000, gain: 4, bandwidth: 1.2),
            EQBand(frequency: 1_000, gain: 3, bandwidth: 1.2),
        ]

        let maximum = EQHeadroomCalculator.maximumBoost(for: bands)
        let preamp = EQHeadroomCalculator.recommendedPreamp(for: bands)

        XCTAssertEqual(maximum, 7, accuracy: 0.05)
        XCTAssertLessThanOrEqual(preamp, -7.25)
        XCTAssertEqual(preamp * 2, (preamp * 2).rounded())
    }

    func testHeadroomCalculatorLeavesCutOnlyPresetAtUnity() {
        let bands = [
            EQBand(frequency: 100, gain: -5),
            EQBand(filterType: .highShelf, frequency: 8_000, gain: -3),
        ]

        XCTAssertEqual(EQHeadroomCalculator.recommendedPreamp(for: bands), 0)
    }
}

final class PresetStorePersistenceTests: XCTestCase {
    @MainActor
    func testUserPresetFavoriteAndDeviceProfileSurviveReload() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
            preset: saved.preset,
            eqEnabled: true
        )

        let reloaded = PresetStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.userPresets.count, 1)
        XCTAssertEqual(reloaded.userPresets.first?.name, "Desk")
        XCTAssertEqual(reloaded.favoriteUserPresets.map(\.id), [saved.id])
        XCTAssertEqual(reloaded.deviceProfile(for: "test-output")?.preset.name, "Desk")
        XCTAssertTrue(reloaded.deviceProfile(for: "test-output")?.eqEnabled == true)
    }

    @MainActor
    func testFuzzySearchFindsCompactedHeadphoneModel() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PresetStore(userDefaults: defaults)

        let results = store.searchCatalog("wh1000xm5", limit: 20)

        XCTAssertTrue(
            results.contains {
                $0.name.localizedCaseInsensitiveContains("WH-1000XM5")
            }
        )
    }

    @MainActor
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "EQForMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
