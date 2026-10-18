import XCTest
@testable import Idiophile_One

final class RadioQualityTests: XCTestCase {
    private func station(_ name: String, codec: String, kbps: Int, ok: Int = 1, hls: Int = 0, country: String = "FR",
                         votes: Int = 0, id: String = UUID().uuidString) -> RadioStation {
        RadioStation(stationuuid: id, name: name, url_resolved: "https://example.org/\(id)", favicon: nil, tags: nil,
                     country: nil, countrycode: country, codec: codec, bitrate: kbps, homepage: nil,
                     lastcheckok: ok, hls: hls, ssl_error: 0, votes: votes, clickcount: 0)
    }

    func testNamesOfTheSameStationCollapse() {
        let names = ["RTL", "RTL 128k MP3", "Rtl (HQ)", "RTL [AAC 64k]", "RTL - 192 kbps"]
        XCTAssertEqual(Set(names.map(RadioQuality.normalizedName)), ["rtl"])
        XCTAssertNotEqual(RadioQuality.normalizedName("RTL 2"), RadioQuality.normalizedName("RTL"))
        XCTAssertEqual(RadioQuality.normalizedName("France Inter"), RadioQuality.normalizedName("FRANCE  INTER (AAC 128k)"))
    }

    func testCodecAwareBestStream() {
        // AAC 128 beats MP3 128; MP3 320 beats both; FLAC beats everything.
        let mp3 = station("X", codec: "MP3", kbps: 128), aac = station("X", codec: "AAC", kbps: 128)
        let mp3hi = station("X", codec: "MP3", kbps: 320), flac = station("X", codec: "FLAC", kbps: 0)
        XCTAssertEqual(RadioQuality.best([mp3, aac])?.id, aac.id)
        XCTAssertEqual(RadioQuality.best([aac, mp3hi])?.id, mp3hi.id)
        XCTAssertEqual(RadioQuality.best([aac, mp3hi, flac])?.id, flac.id)
    }

    func testBrokenStreamsLose() {
        let working = station("X", codec: "MP3", kbps: 64)
        let dead = station("X", codec: "MP3", kbps: 320, ok: 0)
        XCTAssertEqual(RadioQuality.best([dead, working])?.id, working.id)
    }

    func testStreamsTheEngineCanDecodeAreFavoured() {
        let direct = station("X", codec: "MP3", kbps: 128)
        let hls = station("X", codec: "AAC", kbps: 128, hls: 1)
        // Same codec-weighted rate (AAC would win), but HLS loses the meters and the EQ.
        XCTAssertFalse(RadioQuality.isNativelyDecodable(hls))
        XCTAssertGreaterThan(RadioQuality.score(direct), RadioQuality.score(hls) * 0.9)
    }

    func testPreferenceCapsTheBitrate() {
        let hi = station("X", codec: "MP3", kbps: 320), mid = station("X", codec: "MP3", kbps: 128), lo = station("X", codec: "MP3", kbps: 64)
        XCTAssertEqual(RadioQuality.best([lo, mid, hi], preference: .best)?.id, hi.id)
        XCTAssertEqual(RadioQuality.best([lo, mid, hi], preference: .balanced)?.id, mid.id)
        XCTAssertEqual(RadioQuality.best([lo, mid, hi], preference: .light)?.id, lo.id)
        // Nothing within the cap: the lightest available is still better than nothing.
        XCTAssertNotNil(RadioQuality.best([hi], preference: .light))
    }

    func testGroupingKeepsOrderAndRanksEachGroup() {
        let a64 = station("Radio A 64k", codec: "AAC", kbps: 64), a128 = station("Radio A", codec: "MP3", kbps: 128)
        let b = station("Radio B", codec: "MP3", kbps: 96), aOtherCountry = station("Radio A", codec: "MP3", kbps: 320, country: "BE")
        let groups = RadioQuality.groups([a64, b, a128, aOtherCountry])
        XCTAssertEqual(groups.count, 3)                               // A (FR), B, A (BE): a country is part of the identity
        XCTAssertEqual(groups[0].map(\.id), [a128.id, a64.id])        // ranked: MP3 128 (128) vs AAC 64 (89.6)
        XCTAssertEqual(groups[1].first?.id, b.id)
    }
}
