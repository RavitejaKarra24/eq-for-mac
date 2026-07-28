import Foundation
import XCTest
@testable import EQForMac

final class EQModelsTests: XCTestCase {
    func testPresetCodableRoundTripPreservesAllFields() throws {
        let preset = EQPreset(
            id: try XCTUnwrap(UUID(uuidString: "A48583DC-C024-4467-9ED2-8A3B9EB19D4A")),
            name: "Reference",
            preampDB: -4.5,
            bands: [
                EQBand(
                    id: try XCTUnwrap(
                        UUID(uuidString: "5ED131B2-4E70-44D3-BF34-39E05901D601")
                    ),
                    filterType: .lowShelf,
                    frequency: 105,
                    gain: 4.25,
                    bandwidth: 0.8,
                    enabled: true
                ),
                EQBand(
                    id: try XCTUnwrap(
                        UUID(uuidString: "89E9A3A5-B7D8-4C78-80AB-8B9DD01D246E")
                    ),
                    filterType: .notch,
                    frequency: 7_500,
                    gain: -2,
                    bandwidth: 1.2,
                    enabled: false
                ),
            ],
            bandMode: .parametric,
            isBuiltIn: false,
            isHeadphone: true,
            source: "Unit test"
        )

        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(EQPreset.self, from: encoded)

        XCTAssertEqual(decoded, preset)
    }

    func testAppPreferencesCodableRoundTripPreservesState() throws {
        var preferences = AppPreferences()
        preferences.eqEnabled = true
        preferences.bandMode = .fifteen
        preferences.selectedPresetName = "Custom"
        preferences.selectedUserPresetID = try XCTUnwrap(
            UUID(uuidString: "132A6731-E01A-4425-B730-F092304183C8")
        )
        preferences.customGains = (0..<15).map(Float.init)
        preferences.preampDB = -7.25
        preferences.lastHeadphoneName = "Example Headphone"
        preferences.autoPreampEnabled = true
        preferences.launchAtLogin = true
        preferences.hotKeyEnabled = true
        preferences.hotKeyKeyCode = 14
        preferences.hotKeyModifiers = 2_304
        preferences.favoriteHeadphoneNames = ["Example Headphone"]
        preferences.recentHeadphoneNames = ["Another Headphone"]

        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)

        XCTAssertEqual(decoded, preferences)
    }

    func testLegacyPreferencesDecodeWithSafeDefaultsForNewSettings() throws {
        let legacyJSON = """
        {
          "eqEnabled": true,
          "bandMode": "10-band",
          "selectedPresetName": "Bass Boost",
          "customGains": [1, 2, 3],
          "preampDB": -2
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertTrue(decoded.eqEnabled)
        XCTAssertEqual(decoded.selectedPresetName, "Bass Boost")
        XCTAssertFalse(decoded.autoPreampEnabled)
        XCTAssertFalse(decoded.launchAtLogin)
        XCTAssertFalse(decoded.hotKeyEnabled)
        XCTAssertEqual(decoded.stereoWidth, 1)
        XCTAssertNil(decoded.selectedUserPresetID)
        XCTAssertTrue(decoded.favoritePresetIDs.isEmpty)
        XCTAssertTrue(decoded.deviceProfiles.isEmpty)
    }

    func testFlatPresetAndGraphicBandDefinitionsAreStable() {
        let flat = EQPreset.flat(mode: .fifteen)

        XCTAssertTrue(flat.isFlat)
        XCTAssertEqual(flat.bands.map(\.frequency), EQBandMode.fifteen.frequencies)
        XCTAssertEqual(flat.bands.count, EQBandMode.fifteen.bandCount)
        XCTAssertTrue(flat.bands.allSatisfy { $0.bandwidth == 0.67 })

        let boosted = EQPreset.graphic(
            name: "Test",
            mode: .ten,
            gains: Array(repeating: 1, count: EQBandMode.ten.bandCount)
        )
        XCTAssertFalse(boosted.isFlat)
    }

    func testZeroGainPassAndNotchFiltersAreNotTreatedAsFlat() {
        for filterType in [
            EQFilterType.lowPass,
            .highPass,
            .bandPass,
            .notch,
        ] {
            let preset = EQPreset(
                name: "Filter",
                bands: [
                    EQBand(
                        filterType: filterType,
                        frequency: 1_000,
                        gain: 0,
                        enabled: true
                    )
                ],
                bandMode: .parametric
            )
            XCTAssertFalse(preset.isFlat, "\(filterType) must remain active")
        }
    }

    func testBandwidthConversionIsFiniteAndClamped() {
        let nominal = EQBand.bandwidthFromQ(1)
        let minimumQ = EQBand.bandwidthFromQ(0)
        let veryHighQ = EQBand.bandwidthFromQ(1_000_000)

        XCTAssertGreaterThan(nominal, 0.05)
        XCTAssertLessThanOrEqual(nominal, 5)
        XCTAssertEqual(minimumQ, 5)
        XCTAssertEqual(veryHighQ, 0.05)
    }
}
