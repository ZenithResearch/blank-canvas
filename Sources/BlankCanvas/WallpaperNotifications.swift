import Foundation

struct WallpaperNotificationItem: Identifiable, Equatable, Sendable {
    let id: String
    let packID: String
    let wallpaperTitle: String
    let title: String
    let body: String
    let publishedAt: Date
    let link: URL?
}

struct WallpaperNotificationState: Equatable, Sendable {
    let enabled: Bool
    let isRefreshing: Bool
    let items: [WallpaperNotificationItem]
    let unreadCount: Int
    let lastUpdated: Date?
    let errorMessage: String?
}

private struct NotificationFeedSource: Sendable {
    let packID: String
    let wallpaperTitle: String
    let url: URL
    let format: NotificationFeedFormat
}

private struct ZenithNotificationFeed: Decodable {
    let schemaVersion: Int
    let wallpaperID: String
    let items: [ZenithNotificationEntry]
}

private struct ZenithNotificationEntry: Decodable {
    let id: String
    let publishedAt: String
    let title: String
    let body: String
    let url: URL?
}

struct WallpaperNotificationFeedParser {
    static func parseJSON(
        _ data: Data,
        packID: String,
        wallpaperTitle: String
    ) throws -> [WallpaperNotificationItem] {
        let feed = try JSONDecoder().decode(ZenithNotificationFeed.self, from: data)
        guard feed.schemaVersion == 1, feed.wallpaperID == packID, feed.items.count <= 100 else {
            throw RuntimeError.invalidManifest("notification feed identity is invalid")
        }
        return try feed.items.map { entry in
            guard validIdentifier(entry.id, maximum: 100),
                  validText(entry.title, maximum: 120, allowEmpty: false),
                  validText(entry.body, maximum: 500, allowEmpty: true),
                  let publishedAt = ISO8601DateFormatter().date(from: entry.publishedAt),
                  validLink(entry.url) else {
                throw RuntimeError.invalidManifest("notification feed entry is invalid")
            }
            return WallpaperNotificationItem(
                id: "\(packID):\(entry.id)",
                packID: packID,
                wallpaperTitle: wallpaperTitle,
                title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: entry.body.trimmingCharacters(in: .whitespacesAndNewlines),
                publishedAt: publishedAt,
                link: entry.url
            )
        }
    }

    static func parseRSS(
        _ data: Data,
        packID: String,
        wallpaperTitle: String
    ) throws -> [WallpaperNotificationItem] {
        let delegate = RSSDelegate(packID: packID, wallpaperTitle: wallpaperTitle)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.items.count <= 100 else {
            throw RuntimeError.invalidManifest("RSS notification feed is invalid")
        }
        return delegate.items
    }

    private static func validText(_ value: String, maximum: Int, allowEmpty: Bool) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (allowEmpty || !trimmed.isEmpty)
            && value.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
            }
    }

    private static func validLink(_ url: URL?) -> Bool {
        url == nil || url?.scheme?.lowercased() == "https"
    }
}

private final class RSSDelegate: NSObject, XMLParserDelegate {
    let packID: String
    let wallpaperTitle: String
    var items: [WallpaperNotificationItem] = []

    private var insideEntry = false
    private var currentElement = ""
    private var values: [String: String] = [:]

    init(packID: String, wallpaperTitle: String) {
        self.packID = packID
        self.wallpaperTitle = wallpaperTitle
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            insideEntry = true
            values = [:]
        }
        guard insideEntry else { return }
        currentElement = name
        if name == "link", let href = attributeDict["href"] { values["link", default: ""] += href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideEntry, !currentElement.isEmpty else { return }
        values[currentElement, default: ""] += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            if let item = makeItem(index: items.count) { items.append(item) }
            insideEntry = false
            values = [:]
        }
        currentElement = ""
    }

    private func makeItem(index: Int) -> WallpaperNotificationItem? {
        let title = clean(values["title"] ?? "", maximum: 120)
        let body = clean(
            values["description"] ?? values["summary"] ?? values["content"] ?? "",
            maximum: 500
        )
        guard !title.isEmpty else { return nil }
        let rawDate = values["pubdate"] ?? values["published"] ?? values["updated"] ?? ""
        guard let date = parseDate(rawDate) else { return nil }
        let link = URL(string: clean(values["link"] ?? "", maximum: 2048))
        guard link == nil || link?.scheme?.lowercased() == "https" else { return nil }
        let rawID = clean(values["guid"] ?? values["id"] ?? values["link"] ?? "entry-\(index)", maximum: 180)
        return WallpaperNotificationItem(
            id: "\(packID):\(rawID)",
            packID: packID,
            wallpaperTitle: wallpaperTitle,
            title: title,
            body: body,
            publishedAt: date,
            link: link
        )
    }

    private func clean(_ value: String, maximum: Int) -> String {
        let withoutTags = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return String(withoutTags.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }

    private func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = ISO8601DateFormatter().date(from: trimmed) { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: trimmed)
    }
}

@MainActor
final class WallpaperNotificationService {
    private let defaults: UserDefaults
    private let enabledKey: String
    private let lastReadKey: String
    private(set) var state: WallpaperNotificationState

    var onStateChange: ((WallpaperNotificationState) -> Void)?

    init(defaultsPrefix: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledKey = "\(defaultsPrefix)pullNotificationsEnabled"
        lastReadKey = "\(defaultsPrefix)pullNotificationsLastRead"
        state = WallpaperNotificationState(
            enabled: defaults.bool(forKey: enabledKey),
            isRefreshing: false,
            items: [],
            unreadCount: 0,
            lastUpdated: nil,
            errorMessage: nil
        )
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: enabledKey)
        update(enabled: enabled)
    }

    func markAllRead() {
        defaults.set(Date().timeIntervalSince1970, forKey: lastReadKey)
        update(unreadCount: 0)
    }

    func refresh(packs: [InstalledPack], titles: [String: String]) async {
        guard state.enabled, !state.isRefreshing else { return }
        update(isRefreshing: true)
        let sources = packs.compactMap { pack -> NotificationFeedSource? in
            guard let notifications = pack.manifest.notifications else { return nil }
            return NotificationFeedSource(
                packID: pack.manifest.id,
                wallpaperTitle: titles[pack.manifest.id]
                    ?? pack.manifest.id.replacingOccurrences(of: "-", with: " ").capitalized,
                url: notifications.feedURL,
                format: notifications.format
            )
        }

        var collected: [WallpaperNotificationItem] = []
        var failures = 0
        await withTaskGroup(of: Result<[WallpaperNotificationItem], Error>.self) { group in
            for source in sources { group.addTask { await Self.fetch(source) } }
            for await result in group {
                switch result {
                case .success(let items): collected.append(contentsOf: items)
                case .failure: failures += 1
                }
            }
        }
        let unique = Dictionary(grouping: collected, by: \.id).compactMap { $0.value.first }
            .sorted { $0.publishedAt > $1.publishedAt }
        let items = Array(unique.prefix(50))
        let lastRead = Date(timeIntervalSince1970: defaults.double(forKey: lastReadKey))
        update(
            isRefreshing: false,
            items: items,
            unreadCount: items.filter { $0.publishedAt > lastRead }.count,
            lastUpdated: Date(),
            errorMessage: failures > 0
                ? "\(failures) wallpaper update feed\(failures == 1 ? "" : "s") could not be reached."
                : nil
        )
    }

    private static func fetch(_ source: NotificationFeedSource) async -> Result<[WallpaperNotificationItem], Error> {
        do {
            var request = URLRequest(url: source.url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue(
                "application/json, application/rss+xml, application/atom+xml, application/xml;q=0.9",
                forHTTPHeaderField: "Accept"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 512 * 1024 else {
                throw RuntimeError.downloadFailed("notification feed response is invalid")
            }
            switch source.format {
            case .zenithJSON:
                return .success(try WallpaperNotificationFeedParser.parseJSON(
                    data,
                    packID: source.packID,
                    wallpaperTitle: source.wallpaperTitle
                ))
            case .rss:
                return .success(try WallpaperNotificationFeedParser.parseRSS(
                    data,
                    packID: source.packID,
                    wallpaperTitle: source.wallpaperTitle
                ))
            }
        } catch {
            return .failure(error)
        }
    }

    private func update(
        enabled: Bool? = nil,
        isRefreshing: Bool? = nil,
        items: [WallpaperNotificationItem]? = nil,
        unreadCount: Int? = nil,
        lastUpdated: Date? = nil,
        errorMessage: String? = nil
    ) {
        let next = WallpaperNotificationState(
            enabled: enabled ?? state.enabled,
            isRefreshing: isRefreshing ?? state.isRefreshing,
            items: items ?? state.items,
            unreadCount: unreadCount ?? state.unreadCount,
            lastUpdated: lastUpdated ?? state.lastUpdated,
            errorMessage: errorMessage
        )
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }
}
