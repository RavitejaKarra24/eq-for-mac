import XCTest
@testable import EQForMac

final class EqualizerAPOParserTests: XCTestCase {
    func testParsesPreampFilterTypesStateAndJunkLines() throws {
        let text = """
        # Exported by an equalizer
        Preamp: -6.25 dB
        This line should be ignored.
        Filter 1: ON PK Fc 100 Hz Gain 3.5 dB Q 1.00
        Filter 2: ON LSC Fc 80 Hz Gain 2.0 dB Q 0.70
        Filter 3: OFF HSC Fc 8000 Hz Gain -1.5 dB Q 0.80
        Filter 4: ON LPQ Fc 19000 Hz Q 0.71
        Filter 5: ON HP Fc 25 Hz Q 0.90
        """

        let parsed = try XCTUnwrap(EqualizerAPOParser.parse(text: text))

        XCTAssertEqual(parsed.preampDB, -6.25, accuracy: 0.001)
        XCTAssertEqual(parsed.bands.count, 5)
        XCTAssertEqual(
            parsed.bands.map(\.filterType),
            [.parametric, .lowShelf, .highShelf, .lowPass, .highPass]
        )
        XCTAssertEqual(parsed.bands[0].frequency, 100)
        XCTAssertEqual(parsed.bands[0].gain, 3.5)
        XCTAssertFalse(parsed.bands[2].enabled)
    }

    func testParsesOctaveBandwidthVariants() throws {
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 2 dB BW Oct 1.25
        Filter 2: ON PK Fc 2000 Hz Gain -2 dB BW 0.75
        """

        let parsed = try XCTUnwrap(EqualizerAPOParser.parse(text: text))

        XCTAssertEqual(parsed.bands[0].bandwidth, 1.25, accuracy: 0.001)
        XCTAssertEqual(parsed.bands[1].bandwidth, 0.75, accuracy: 0.001)
    }

    func testClampsUnsafeFilterValues() throws {
        let text = """
        Filter 1: ON PK Fc 5 Hz Gain 99 dB Q 1
        Filter 2: ON PK Fc 50000 Hz Gain -99 dB BW Oct 20
        """

        let parsed = try XCTUnwrap(EqualizerAPOParser.parse(text: text))

        XCTAssertEqual(parsed.bands[0].frequency, 20)
        XCTAssertEqual(parsed.bands[0].gain, 24)
        XCTAssertEqual(parsed.bands[1].frequency, 20_000)
        XCTAssertEqual(parsed.bands[1].gain, -24)
        XCTAssertEqual(parsed.bands[1].bandwidth, 5)
    }

    func testAcceptsPreampOnlyAndRejectsJunkOnlyInput() throws {
        let preampOnly = try XCTUnwrap(
            EqualizerAPOParser.parse(text: "Preamp: -3 dB")
        )

        XCTAssertEqual(preampOnly.preampDB, -3)
        XCTAssertTrue(preampOnly.bands.isEmpty)
        XCTAssertNil(EqualizerAPOParser.parse(text: "# comment\nnot a filter"))
    }
}
