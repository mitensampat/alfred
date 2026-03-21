import Foundation
import SQLite3

/// Reads Chrome browsing history from the local SQLite database
/// Chrome sync means all devices (iPhone, iPad, work Mac, etc.) contribute to this single DB
struct BrowsingEntry {
    let url: String
    let title: String
    let visitCount: Int
    let visitTime: Date
    let domain: String
}

struct BrowsingCluster {
    let domain: String
    let entries: [BrowsingEntry]
    let totalVisits: Int
    let timeRange: (start: Date, end: Date)
}

class ChromeHistoryReader {

    // Chrome epoch: microseconds since 1601-01-01
    // Offset from Unix epoch: 11644473600 seconds
    private static let chromeEpochOffset: Int64 = 11_644_473_600

    /// Default Chrome profile path
    private let profilePath: String
    private let noiseDomains: Set<String>
    private let dwellTimeSeconds: Int

    /// Default noise domains to filter out
    private static let defaultNoiseDomains: Set<String> = [
        "google.com", "www.google.com", "google.co.in",
        "gmail.com", "mail.google.com",
        "calendar.google.com",
        "accounts.google.com",
        "myaccount.google.com",
        "drive.google.com",
        "docs.google.com",  // Keep specific docs but filter the listing
        "localhost", "127.0.0.1",
        "chrome-extension", "chrome",
        "about",
        "facebook.com", "www.facebook.com",
        "instagram.com", "www.instagram.com",
        "twitter.com", "x.com",
        "reddit.com", "www.reddit.com",
        "amazon.com", "www.amazon.com", "amazon.in", "www.amazon.in",
        "flipkart.com", "www.flipkart.com",
        "id.atlassian.com",  // SSO flows
        "login.microsoftonline.com",
        "auth0.com",
    ]

    /// URL path patterns to filter
    private static let noisePathPatterns: [String] = [
        "/auth", "/login", "/logout", "/oauth", "/callback",
        "/api/", "/cart", "/checkout", "/order",
        "/aclk",  // Google ad clicks
        "/url?",  // Google redirect
        "/_/",    // Internal API paths
    ]

    init(chromeProfilePath: String = "Default", noiseDomains: [String] = [], dwellTimeSeconds: Int = 30) {
        let homeDir = NSHomeDirectory()
        self.profilePath = "\(homeDir)/Library/Application Support/Google/Chrome/\(chromeProfilePath)/History"
        self.noiseDomains = Self.defaultNoiseDomains.union(Set(noiseDomains))
        self.dwellTimeSeconds = dwellTimeSeconds
    }

    /// Fetch browsing clusters from the last N hours, with smart noise filtering
    func fetchBrowsingClusters(hours: Int = 24, minClusterSize: Int = 2) -> (clusters: [BrowsingCluster], youtubeVideoIds: [String]) {
        // Copy the database — Chrome locks it while running
        let tmpPath = "/tmp/alfred_chrome_history.db"
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: tmpPath) {
                try fm.removeItem(atPath: tmpPath)
            }
            try fm.copyItem(atPath: profilePath, toPath: tmpPath)
        } catch {
            print("⚠️ ChromeHistory: Failed to copy database: \(error.localizedDescription)")
            return ([], [])
        }

        // Open the copy read-only
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            print("⚠️ ChromeHistory: Failed to open database copy")
            return ([], [])
        }
        defer {
            sqlite3_close(db)
            try? fm.removeItem(atPath: tmpPath)
        }

        // Query recent visits
        let sinceTimestamp = chromeTimestamp(for: Date().addingTimeInterval(-Double(hours * 3600)))

        let sql = """
        SELECT u.url, u.title, u.visit_count, v.visit_time
        FROM urls u
        JOIN visits v ON u.id = v.url
        WHERE v.visit_time > ?
        ORDER BY v.visit_time DESC
        LIMIT 3000
        """

        var stmt: OpaquePointer?
        var rawEntries: [BrowsingEntry] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, sinceTimestamp)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlCStr = sqlite3_column_text(stmt, 0),
                      let titleCStr = sqlite3_column_text(stmt, 1) else { continue }

                let url = String(cString: urlCStr)
                let title = String(cString: titleCStr)
                let visitCount = Int(sqlite3_column_int(stmt, 2))
                let visitTimestamp = sqlite3_column_int64(stmt, 3)
                let visitDate = dateFromChromeTimestamp(visitTimestamp)

                guard let domain = extractDomain(from: url) else { continue }

                rawEntries.append(BrowsingEntry(
                    url: url,
                    title: title,
                    visitCount: visitCount,
                    visitTime: visitDate,
                    domain: domain
                ))
            }
        }
        sqlite3_finalize(stmt)

        // Apply smart filtering
        let filtered = applySmartFilter(entries: rawEntries)

        // Separate YouTube watch URLs
        var youtubeVideoIds: [String] = []
        var nonYoutubeEntries: [BrowsingEntry] = []

        for entry in filtered {
            if let videoId = extractYouTubeVideoId(from: entry.url) {
                if !youtubeVideoIds.contains(videoId) {
                    youtubeVideoIds.append(videoId)
                }
            } else {
                nonYoutubeEntries.append(entry)
            }
        }

        // Cluster by domain
        let clusters = clusterByDomain(entries: nonYoutubeEntries, minClusterSize: minClusterSize)

        return (clusters, youtubeVideoIds)
    }

    /// Format clusters into readable text for extraction
    func formatClustersForExtraction(_ clusters: [BrowsingCluster]) -> String {
        guard !clusters.isEmpty else { return "" }

        var text = "Browsing activity (last 24 hours):\n\n"

        for cluster in clusters.prefix(20) {
            text += "[\(cluster.domain)] — \(cluster.totalVisits) visits\n"
            for entry in cluster.entries.prefix(8) {
                let title = entry.title.isEmpty ? "(no title)" : entry.title
                text += "  • \(title)\n"
            }
            text += "\n"
        }

        return text
    }

    // MARK: - Smart Filtering

    private func applySmartFilter(entries: [BrowsingEntry]) -> [BrowsingEntry] {
        var filtered: [BrowsingEntry] = []

        // Sort by time for dwell-time calculation
        let sorted = entries.sorted { $0.visitTime > $1.visitTime }

        for (i, entry) in sorted.enumerated() {
            // Skip noise domains
            if isNoiseDomain(entry.domain) { continue }

            // Skip noise URL patterns
            if hasNoisePattern(entry.url) { continue }

            // Skip very short titles (likely loading pages)
            if entry.title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { continue }

            // Skip chrome:// and about: URLs
            if entry.url.hasPrefix("chrome://") || entry.url.hasPrefix("about:") || entry.url.hasPrefix("chrome-extension://") { continue }

            // Dwell-time heuristic: check if next visit was >N seconds later
            if i + 1 < sorted.count {
                let dwellTime = sorted[i].visitTime.timeIntervalSince(sorted[i + 1].visitTime)
                if dwellTime < Double(dwellTimeSeconds) && dwellTime >= 0 {
                    continue  // Clicked and bounced too fast
                }
            }

            filtered.append(entry)
        }

        // Deduplicate by URL, keeping the most recent visit
        var seen: Set<String> = []
        var deduped: [BrowsingEntry] = []
        for entry in filtered {
            let normalizedUrl = normalizeUrl(entry.url)
            if !seen.contains(normalizedUrl) {
                seen.insert(normalizedUrl)
                deduped.append(entry)
            }
        }

        return deduped
    }

    private func isNoiseDomain(_ domain: String) -> Bool {
        // Check exact match and parent domain
        if noiseDomains.contains(domain) { return true }
        // Check without www.
        let withoutWww = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
        if noiseDomains.contains(withoutWww) { return true }
        return false
    }

    private func hasNoisePattern(_ url: String) -> Bool {
        let lowered = url.lowercased()
        for pattern in Self.noisePathPatterns {
            if lowered.contains(pattern) { return true }
        }
        // Tracker/redirect URLs
        if lowered.contains("yamm-track") || lowered.contains("click.") { return true }
        return false
    }

    // MARK: - Clustering

    private func clusterByDomain(entries: [BrowsingEntry], minClusterSize: Int) -> [BrowsingCluster] {
        var domainGroups: [String: [BrowsingEntry]] = [:]

        for entry in entries {
            domainGroups[entry.domain, default: []].append(entry)
        }

        var clusters: [BrowsingCluster] = []
        for (domain, entries) in domainGroups {
            if entries.count < minClusterSize { continue }

            let sortedEntries = entries.sorted { $0.visitTime > $1.visitTime }
            let totalVisits = entries.reduce(0) { $0 + $1.visitCount }
            let start = sortedEntries.last?.visitTime ?? Date()
            let end = sortedEntries.first?.visitTime ?? Date()

            clusters.append(BrowsingCluster(
                domain: domain,
                entries: sortedEntries,
                totalVisits: totalVisits,
                timeRange: (start: start, end: end)
            ))
        }

        // Sort by total visit count (most-visited domains first)
        return clusters.sorted { $0.entries.count > $1.entries.count }
    }

    // MARK: - YouTube

    /// Extract YouTube video ID from a watch URL
    private func extractYouTubeVideoId(from url: String) -> String? {
        // Match youtube.com/watch?v=VIDEO_ID or youtu.be/VIDEO_ID
        guard url.contains("youtube.com/watch") || url.contains("youtu.be/") else { return nil }

        // Don't match YouTube homepage, search, feed, etc.
        if url.contains("youtube.com/feed") || url.contains("youtube.com/results") ||
           url.contains("youtube.com/@") || url.hasSuffix("youtube.com/") ||
           url.hasSuffix("youtube.com") { return nil }

        if let urlComponents = URLComponents(string: url),
           let videoId = urlComponents.queryItems?.first(where: { $0.name == "v" })?.value {
            return videoId
        }

        // youtu.be/VIDEO_ID format
        if url.contains("youtu.be/"),
           let lastComponent = URL(string: url)?.lastPathComponent,
           !lastComponent.isEmpty {
            return lastComponent
        }

        return nil
    }

    /// Fetch YouTube auto-generated transcript for a video
    /// Uses the timedtext API which doesn't require an API key
    func fetchYouTubeTranscript(videoId: String) async -> String? {
        // First, get the video page to find the captions track URL
        guard let pageUrl = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return nil }

        var request = URLRequest(url: pageUrl)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Extract the captions JSON from the page source
        guard let captionsStart = html.range(of: "\"captions\":")?.upperBound,
              let playerStart = html.range(of: "\"captionTracks\":", range: captionsStart..<html.endIndex)?.upperBound else {
            return nil
        }

        // Find the baseUrl for the first caption track
        guard let baseUrlStart = html.range(of: "\"baseUrl\":\"", range: playerStart..<html.endIndex)?.upperBound,
              let baseUrlEnd = html.range(of: "\"", range: baseUrlStart..<html.endIndex)?.lowerBound else {
            return nil
        }

        let captionUrl = String(html[baseUrlStart..<baseUrlEnd])
            .replacingOccurrences(of: "\\u0026", with: "&")

        // Fetch the transcript XML
        guard let transcriptUrl = URL(string: captionUrl),
              let (transcriptData, _) = try? await URLSession.shared.data(from: transcriptUrl),
              let transcriptXml = String(data: transcriptData, encoding: .utf8) else {
            return nil
        }

        // Parse the simple XML transcript format: <text start="..." dur="...">content</text>
        return parseTranscriptXml(transcriptXml)
    }

    private func parseTranscriptXml(_ xml: String) -> String {
        var lines: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex

        while let startTag = xml.range(of: "<text", range: searchRange),
              let contentStart = xml.range(of: ">", range: startTag.upperBound..<xml.endIndex),
              let contentEnd = xml.range(of: "</text>", range: contentStart.upperBound..<xml.endIndex) {

            let content = String(xml[contentStart.upperBound..<contentEnd.lowerBound])
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !content.isEmpty {
                lines.append(content)
            }

            searchRange = contentEnd.upperBound..<xml.endIndex
        }

        return lines.joined(separator: " ")
    }

    // MARK: - Helpers

    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return host.lowercased()
    }

    private func normalizeUrl(_ url: String) -> String {
        // Strip query params and fragments for dedup
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url
    }

    private func chromeTimestamp(for date: Date) -> Int64 {
        return Int64((date.timeIntervalSince1970 + Double(Self.chromeEpochOffset)) * 1_000_000)
    }

    private func dateFromChromeTimestamp(_ timestamp: Int64) -> Date {
        let seconds = Double(timestamp) / 1_000_000.0 - Double(Self.chromeEpochOffset)
        return Date(timeIntervalSince1970: seconds)
    }
}
