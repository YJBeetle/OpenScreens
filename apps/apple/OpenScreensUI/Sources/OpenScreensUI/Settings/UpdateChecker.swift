import Foundation

public struct AppRelease: Sendable {
    public let version: String
    public let tag: String
    public let label: String
    public let notes: String
    public let pageURL: URL?
    public let downloadURL: URL?

    public init(
        version: String,
        tag: String,
        label: String,
        notes: String,
        pageURL: URL?,
        downloadURL: URL?
    ) {
        self.version = version
        self.tag = tag
        self.label = label
        self.notes = notes
        self.pageURL = pageURL
        self.downloadURL = downloadURL
    }
}

public enum UpdateCheckResult: Sendable {
    case available(AppRelease)
    case upToDate
    case noReleases
}

/// Reads GitHub Releases for the channel selected in settings. Release and
/// pre-release use semantic versions; the rolling `snapshot` tag is always
/// offered until the same snapshot label has been installed locally.
public enum UpdateChecker {
    private static let snapshotTag = "snapshot"

    public static let releasesURL = URL(
        string: "https://api.github.com/repos/YJBeetle/OpenScreens/releases?per_page=20"
    )!

    public static func check(
        currentVersion: String,
        channel: UpdateChannel,
        installedSnapshot: String?,
        session: URLSession = .shared
    ) async throws -> UpdateCheckResult {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenScreens-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return .noReleases }
            guard (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        return try parse(
            data: data,
            currentVersion: currentVersion,
            channel: channel,
            installedSnapshot: installedSnapshot
        )
    }

    static func parse(
        data: Data,
        currentVersion: String,
        channel: UpdateChannel,
        installedSnapshot: String?
    ) throws -> UpdateCheckResult {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        let selected = releases.first { release in
            guard !release.draft else { return false }
            let isSnapshot = release.tag_name.caseInsensitiveCompare(snapshotTag) == .orderedSame
            switch channel {
            case .snapshot: return isSnapshot
            case .prerelease: return !isSnapshot
            case .release: return !isSnapshot && !release.prerelease
            }
        }
        guard let release = selected else { return .noReleases }

        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name
        let label = (release.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? (version.isEmpty ? release.tag_name : version)

        if channel == .snapshot {
            if installedSnapshot == label { return .upToDate }
        } else if version.isEmpty || !isNewer(version, than: currentVersion) {
            return .upToDate
        }

        let assetURL = selectAsset(release.assets)
        return .available(
            AppRelease(
                version: version.isEmpty ? release.tag_name : version,
                tag: release.tag_name,
                label: label,
                notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                pageURL: URL(string: release.html_url),
                downloadURL: assetURL
            )
        )
    }

    fileprivate static func selectAsset(_ assets: [Release.Asset]) -> URL? {
        let candidates = assets.compactMap { asset -> (name: String, url: URL)? in
            guard let url = URL(string: asset.browser_download_url),
                  url.scheme == "https"
            else { return nil }
            let name = asset.name.lowercased()
            guard name.hasSuffix(".dmg") || name.hasSuffix(".zip") else { return nil }
            return (name, url)
        }
        func first(dmg: Bool, macosOnly: Bool) -> URL? {
            candidates.first { candidate in
                let isDMG = candidate.name.hasSuffix(".dmg")
                return isDMG == dmg && (!macosOnly || candidate.name.contains("macos"))
            }?.url
        }
        return first(dmg: true, macosOnly: true)
            ?? first(dmg: true, macosOnly: false)
            ?? first(dmg: false, macosOnly: true)
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }

    static func compare(_ candidate: String, _ current: String) -> Int {
        func core(_ value: String) -> [Substring] {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "v", with: "", options: .anchored)
                .split(separator: "-", maxSplits: 1)
                .first?
                .split(separator: "+", maxSplits: 1)
                .first?
                .split(separator: ".") ?? []
        }

        let left = core(candidate)
        let right = core(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? Int(left[index]) ?? 0 : 0
            let b = index < right.count ? Int(right[index]) ?? 0 : 0
            if a != b { return a < b ? -1 : 1 }
        }

        let candidateIsPrerelease = candidate.contains("-")
        let currentIsPrerelease = current.contains("-")
        if candidateIsPrerelease && !currentIsPrerelease { return -1 }
        if !candidateIsPrerelease && currentIsPrerelease { return 1 }
        return 0
    }
}

fileprivate struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}
