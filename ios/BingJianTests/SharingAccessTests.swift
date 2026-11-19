import XCTest
@testable import BingJian

final class SharingAccessTests: XCTestCase {
    func testGrantLeaseUsesServerClockSubtractsNetworkDelayAndFailsClosed() {
        let server = Date(timeIntervalSince1970: 1_800_000_000)
        var response: JSONObject = ["server_time": .string(TimeFormat.iso(server)),
                                    "expires_at": .string(TimeFormat.iso(server.addingTimeInterval(20)))]
        XCTAssertEqual(SharedSummaryLease.grantDuration(response, elapsed: 3), 17)
        XCTAssertEqual(SharedSummaryLease.grantDuration(response, elapsed: 21), 0)
        XCTAssertEqual(SharedSummaryLease.grantDuration(response, elapsed: -1), 0)
        response["expires_at"] = .string(TimeFormat.iso(server.addingTimeInterval(3600)))
        XCTAssertEqual(SharedSummaryLease.grantDuration(response, elapsed: 0), 60)
        response["server_time"] = .null
        XCTAssertEqual(SharedSummaryLease.grantDuration(response, elapsed: 0), 0)
        XCTAssertEqual(SharedSummaryLease.grantDuration([:], elapsed: 0), 0)
    }

    func testInviteStaysWithItsServerAndDoesNotPutCodeInHTTPSRequest() throws {
        let code = "A1234567890_-bcdefgh1234"
        XCTAssertTrue(ChallengeInvitation.valid(code))
        let server = "https://cloud.example.test"
        let url = try XCTUnwrap(URL(string: ChallengeInvitation.link(code: code, server: server)))
        XCTAssertEqual(url.fragment, code)
        XCTAssertNil(url.query)
        XCTAssertEqual(ChallengeInvitation.read(url, server: server), code)
        XCTAssertNil(ChallengeInvitation.read(url, server: server + ":444"))
        XCTAssertNil(ChallengeInvitation.read(url, server: "https://other.example.test"))
        XCTAssertNil(ChallengeInvitation.read(try XCTUnwrap(URL(string: server + "/other#" + code)), server: server))
        let fallback = try XCTUnwrap(URL(string: "bingjian://join?code=" + code + "&origin=" + server))
        XCTAssertEqual(ChallengeInvitation.read(fallback, server: server), code)
        XCTAssertNil(ChallengeInvitation.read(fallback, server: "https://other.example.test"))
        let old = try XCTUnwrap(URL(string: ChallengeInvitation.link(code: code, server: "http://localhost:8000")))
        XCTAssertEqual(ChallengeInvitation.read(old, server: "http://localhost:8000"), code)
        XCTAssertNil(ChallengeInvitation.read(try XCTUnwrap(URL(string: "bingjian://join?code=bad")), server: server))
    }

    func testExpiredSharedSummaryIsHiddenEvenWithLegacyLongLease() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let summary: JSONObject = [
            "cached_at_local": .string(TimeFormat.iso(base)), "server_time": .string(TimeFormat.iso(base)),
            "cached_until": .string(TimeFormat.iso(base.addingTimeInterval(86400)))
        ]
        XCTAssertEqual(SharedSummaryLease.expiry(summary, now: base), base.addingTimeInterval(300))
        XCTAssertNil(SharedSummaryLease.expiry(summary, now: base.addingTimeInterval(300)))
        XCTAssertNil(SharedSummaryLease.expiry(summary, now: base.addingTimeInterval(-1)))
        var shorter = summary
        shorter["cached_until"] = .string(TimeFormat.iso(base.addingTimeInterval(10)))
        XCTAssertNil(SharedSummaryLease.expiry(shorter, now: base.addingTimeInterval(20)))
        XCTAssertNil(SharedSummaryLease.expiry([:], now: base))
    }
}
