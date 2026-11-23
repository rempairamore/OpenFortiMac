import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let page: URL
}

/// Asks GitHub for the latest release: at most once a day, and only while the user leaves it on.
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/rempairamore/OpenFortiMac/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/rempairamore/OpenFortiMac/releases/latest")!

    private static let enabledKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let latestVersionKey = "latestKnownVersion"
    private static let latestPageKey = "latestKnownPage"

    private let defaults = UserDefaults.standard

    /// Replaced in tests
    var currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private init() {}

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The newer release found by the last check, if any.
    var knownUpdate: AvailableUpdate? {
        guard let version = defaults.string(forKey: Self.latestVersionKey),
              Self.isVersion(version, newerThan: currentVersion) else { return nil }
        let page = defaults.string(forKey: Self.latestPageKey).flatMap(URL.init(string:)) ?? Self.releasesPage
        return AvailableUpdate(version: version, page: page)
    }

    /// Checks if the automatic check is on and the last one is older than a day.
    func checkIfDue(completion: @escaping (AvailableUpdate?) -> Void) {
        guard isEnabled else {
            completion(nil)
            return
        }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600 {
            completion(knownUpdate)
            return
        }
        check { [weak self] _ in
            completion(self?.knownUpdate)
        }
    }

    /// Asks GitHub now. `completion` runs on the main thread: false when GitHub could not be reached.
    func check(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenFortiMac/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let release = data.flatMap { Self.parseRelease($0) }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 && release != nil
            DispatchQueue.main.async {
                if ok, let self = self, let release = release {
                    self.defaults.set(Date(), forKey: Self.lastCheckKey)
                    self.defaults.set(release.version, forKey: Self.latestVersionKey)
                    self.defaults.set(release.page.absoluteString, forKey: Self.latestPageKey)
                }
                completion(ok)
            }
        }.resume()
    }

    /// Reads version and page from GitHub's answer; the page is used only if it is this project's.
    static func parseRelease(_ data: Data) -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil else { return nil }

        var page = releasesPage
        if let address = json["html_url"] as? String, let url = URL(string: address),
           url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/rempairamore/OpenFortiMac/") {
            page = url
        }
        return AvailableUpdate(version: version, page: page)
    }

    static func isVersion(_ version: String, newerThan other: String) -> Bool {
        let left = version.split(separator: ".").map { Int($0) ?? 0 }
        let right = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a > b
            }
        }
        return false
    }
}
