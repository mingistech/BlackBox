import XCTest
@testable import BlackBoxCore

private final class UpdateURLProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var request: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() throws {
        XCTAssertEqual(ReleaseVersion("v1.0"), ReleaseVersion("1.0.0"))
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("1.10")), try XCTUnwrap(ReleaseVersion("1.9")))
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("2.0")), try XCTUnwrap(ReleaseVersion("1.99")))
        for invalid in ["", "v", "1..0", "1.0-beta", "release-2", "https://example.com", "999999999999999999999"] {
            XCTAssertNil(ReleaseVersion(invalid))
        }
    }

    @MainActor func testAutomaticWeeklyScheduleAndManualOverride() async {
        let suite = "UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.0", now: { now }, fetch: {
            calls += 1
            return GitHubRelease(tag_name: "v1.0", draft: false, prerelease: false)
        })
        await checker.check(automatically: true)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(checker.notice)
        now += UpdateChecker.interval - 1
        await checker.check(automatically: true)
        XCTAssertEqual(calls, 1)
        now += 1
        await checker.check(automatically: true)
        XCTAssertEqual(calls, 2)
        await checker.check()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(checker.notice?.title, "You’re up to date")
        XCTAssertNil(checker.notice?.releaseURL)
    }

    @MainActor func testNewerReleaseOffersRepositoryPage() async {
        let suite = "UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.0", fetch: {
            GitHubRelease(tag_name: "v1.1", draft: false, prerelease: false)
        })
        await checker.check(automatically: true)
        XCTAssertEqual(checker.notice?.releaseURL?.absoluteString, "https://github.com/mingistech/BlackBox/releases/tag/v1.1")
        XCTAssertFalse(checker.isChecking)
        XCTAssertNotNil(defaults.object(forKey: UpdateChecker.lastCheckKey))
    }

    @MainActor func testFailuresAreQuietAutomaticallyAndDoNotPostponeRetry() async {
        let suite = "UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, fetch: { throw URLError(.notConnectedToInternet) })
        await checker.check(automatically: true)
        XCTAssertNil(checker.notice)
        XCTAssertNil(defaults.object(forKey: UpdateChecker.lastCheckKey))
        await checker.check()
        XCTAssertEqual(checker.notice?.title, "Couldn’t check for updates")
        XCTAssertFalse(checker.isChecking)
    }

    @MainActor func testConcurrentChecksAreCoalesced() async {
        let suite = "UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<GitHubRelease?, Never>?
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, fetch: {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        })
        let first = Task { await checker.check() }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(checker.isChecking)
        await checker.check()
        XCTAssertEqual(calls, 1)
        continuation?.resume(returning: nil)
        await first.value
        XCTAssertFalse(checker.isChecking)
    }

    func testReleaseEndpointAndResponseValidation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ReleaseClient(session: session)
        UpdateURLProtocol.status = 200
        UpdateURLProtocol.body = Data(#"{"tag_name":"v1.2","draft":false,"prerelease":false}"#.utf8)
        let release = try await client.latest()
        XCTAssertEqual(release?.tag_name, "v1.2")
        XCTAssertEqual(UpdateURLProtocol.request?.url?.absoluteString, "https://api.github.com/repos/mingistech/BlackBox/releases/latest")
        XCTAssertNil(UpdateURLProtocol.request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(UpdateURLProtocol.request?.httpBody)
        for flag in ["draft", "prerelease"] {
            UpdateURLProtocol.body = Data("{\"tag_name\":\"v9.0\",\"draft\":\(flag == "draft"),\"prerelease\":\(flag == "prerelease")}".utf8)
            let ignored = try await client.latest()
            XCTAssertNil(ignored)
        }
        UpdateURLProtocol.status = 404
        let none = try await client.latest()
        XCTAssertNil(none)
        UpdateURLProtocol.status = 403
        do { _ = try await client.latest(); XCTFail("Rate limiting must fail, not report up to date") } catch {}
        UpdateURLProtocol.status = 200
        UpdateURLProtocol.body = Data(#"{"tag_name":"invalid","draft":false,"prerelease":false}"#.utf8)
        do { _ = try await client.latest(); XCTFail("Malformed version must fail") } catch {}
    }
}
