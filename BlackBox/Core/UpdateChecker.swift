import Combine
import Foundation

struct ReleaseVersion: Comparable {
    private let components: [Int]
    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 4 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    var pageURL: URL {
        URL(string: "https://github.com/mingistech/BlackBox/releases/tag/")!.appendingPathComponent(tag_name)
    }
}

struct ReleaseClient {
    var session: URLSession = .shared
    func latest() async throws -> GitHubRelease? {
        // Public release metadata only: no API keys, terminal data, or chat history.
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/mingistech/BlackBox/releases/latest")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BlackBox-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("GitHub returned an invalid response.") }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw AppError.message("GitHub could not complete the update check. Please try again later.")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard ReleaseVersion(release.tag_name) != nil else {
            throw AppError.message("The latest release has an unrecognized version number.")
        }
        return release
    }
}

struct UpdateNotice {
    let title: String
    let message: String
    var releaseURL: URL?
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    @Published var notice: UpdateNotice?
    static let lastCheckKey = "lastSuccessfulUpdateCheck"
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let currentVersion: String
    private let fetch: () async throws -> GitHubRelease?
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
         now: @escaping () -> Date = Date.init,
         fetch: @escaping () async throws -> GitHubRelease? = { try await ReleaseClient().latest() }) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        self.fetch = fetch
    }

    func check(automatically: Bool = false) async {
        guard !isChecking else { return }
        if automatically, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now().timeIntervalSince(last) >= 0, now().timeIntervalSince(last) < Self.interval { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await fetch()
            try Task.checkCancellation()
            guard let current = ReleaseVersion(currentVersion) else {
                throw AppError.message("The installed app's version could not be determined.")
            }
            defaults.set(now(), forKey: Self.lastCheckKey)
            if let release, let latest = ReleaseVersion(release.tag_name), latest > current {
                notice = UpdateNotice(title: "BlackBox \(release.tag_name) is available",
                                      message: "You’re using version \(currentVersion). Open the GitHub release page to see what’s new and download the update.",
                                      releaseURL: release.pageURL)
            } else if !automatically {
                notice = UpdateNotice(title: "You’re up to date", message: "No newer release of BlackBox is available. You’re using version \(currentVersion).")
            }
        } catch {
            if !automatically && !Task.isCancelled {
                notice = UpdateNotice(title: "Couldn’t check for updates", message: "Check your internet connection and try again. You can also visit the releases page on GitHub.",
                                      releaseURL: URL(string: "https://github.com/mingistech/BlackBox/releases"))
            }
        }
    }
}
