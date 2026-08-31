import Foundation
import UserNotifications

private final class WallpaperNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

enum WallpaperNotificationAuthorization: String, Sendable {
    case notDetermined = "not-determined"
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}

struct WallpaperNotificationState: Equatable, Sendable {
    let enabled: Bool
    let authorization: WallpaperNotificationAuthorization

    var eventDetail: [String: Any] {
        ["enabled": enabled, "authorization": authorization.rawValue]
    }
}

struct WallpaperNotificationRequest: Sendable {
    let requestID: String
    let packID: String
    let title: String
    let body: String
    let tag: String?

    init(message: [String: Any], packID: String) throws {
        guard let requestID = message["requestId"] as? String,
              requestID.count >= 1, requestID.count <= 96,
              let notification = message["notification"] as? [String: Any],
              let title = notification["title"] as? String else {
            throw WallpaperNotificationValidationError.invalidPayload
        }
        let body = notification["body"] as? String ?? ""
        let tag = notification["tag"] as? String
        guard Self.isPlainText(title, maximum: 80, allowEmpty: false),
              Self.isPlainText(body, maximum: 240, allowEmpty: true),
              tag.map({ Self.isIdentifier($0, maximum: 64) }) ?? true else {
            throw WallpaperNotificationValidationError.invalidPayload
        }
        self.requestID = requestID
        self.packID = packID
        self.title = title
        self.body = body
        self.tag = tag
    }

    private static func isPlainText(_ value: String, maximum: Int, allowEmpty: Bool) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty && trimmed.isEmpty { return false }
        return value.count <= maximum && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximum else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }
}

enum WallpaperNotificationValidationError: Error {
    case invalidPayload
}

struct WallpaperNotificationResult: Sendable {
    let requestID: String
    let status: String
    let reason: String?

    var eventDetail: [String: Any] {
        var detail: [String: Any] = ["requestId": requestID, "status": status]
        if let reason { detail["reason"] = reason }
        return detail
    }
}

struct WallpaperNotificationGate {
    let minimumInterval: TimeInterval
    private(set) var lastDeliveryByPack: [String: Date] = [:]
    private(set) var seenRequestIDs: Set<String> = []

    mutating func permits(_ request: WallpaperNotificationRequest, now: Date) -> Bool {
        guard !seenRequestIDs.contains(request.requestID) else { return false }
        seenRequestIDs.insert(request.requestID)
        if seenRequestIDs.count > 512 { seenRequestIDs.removeAll(keepingCapacity: true) }
        if let previous = lastDeliveryByPack[request.packID], now.timeIntervalSince(previous) < minimumInterval {
            return false
        }
        lastDeliveryByPack[request.packID] = now
        return true
    }
}

@MainActor
final class WallpaperNotificationService {
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let preferenceKey: String
    private let presenter = WallpaperNotificationPresenter()
    private var gate = WallpaperNotificationGate(minimumInterval: 60)
    private(set) var state: WallpaperNotificationState

    var onStateChange: ((WallpaperNotificationState) -> Void)?
    var onResult: ((WallpaperNotificationResult) -> Void)?

    init(defaultsPrefix: String, defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
        self.defaults = defaults
        self.center = center
        preferenceKey = "\(defaultsPrefix)wallpaperNotificationsEnabled"
        let enabled = defaults.bool(forKey: preferenceKey)
        state = WallpaperNotificationState(enabled: enabled, authorization: .notDetermined)
        center.delegate = presenter
    }

    func start() {
        Task { await refreshAuthorization() }
    }

    func setEnabled(_ requested: Bool) {
        if !requested {
            defaults.set(false, forKey: preferenceKey)
            updateState(enabled: false, authorization: state.authorization)
            return
        }
        Task {
            let settings = await center.notificationSettings()
            var authorization = Self.authorization(settings.authorizationStatus)
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert])
                    authorization = Self.authorization((await center.notificationSettings()).authorizationStatus)
                } catch {
                    authorization = .denied
                }
            }
            let enabled = Self.canDeliver(authorization)
            defaults.set(enabled, forKey: preferenceKey)
            updateState(enabled: enabled, authorization: authorization)
        }
    }

    func submit(_ request: WallpaperNotificationRequest) {
        Task {
            let settings = await center.notificationSettings()
            let authorization = Self.authorization(settings.authorizationStatus)
            let preference = defaults.bool(forKey: preferenceKey)
            let enabled = preference && Self.canDeliver(authorization)
            updateState(enabled: enabled, authorization: authorization)
            guard enabled else {
                onResult?(WallpaperNotificationResult(
                    requestID: request.requestID,
                    status: authorization == .denied ? "denied" : "disabled",
                    reason: authorization.rawValue
                ))
                return
            }
            guard gate.permits(request, now: Date()) else {
                onResult?(WallpaperNotificationResult(
                    requestID: request.requestID,
                    status: "rate-limited",
                    reason: "one-notification-per-wallpaper-per-minute"
                ))
                return
            }

            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.subtitle = request.packID.replacingOccurrences(of: "-", with: " ").capitalized
            let identifier = "ca.zenith-research.blank-canvas.\(request.packID).\(request.tag ?? request.requestID)"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                onResult?(WallpaperNotificationResult(requestID: request.requestID, status: "delivered", reason: nil))
            } catch {
                onResult?(WallpaperNotificationResult(requestID: request.requestID, status: "failed", reason: error.localizedDescription))
            }
        }
    }

    private func refreshAuthorization() async {
        let authorization = Self.authorization((await center.notificationSettings()).authorizationStatus)
        let enabled = defaults.bool(forKey: preferenceKey) && Self.canDeliver(authorization)
        if !enabled { defaults.set(false, forKey: preferenceKey) }
        updateState(enabled: enabled, authorization: authorization)
    }

    private func updateState(enabled: Bool, authorization: WallpaperNotificationAuthorization) {
        let next = WallpaperNotificationState(enabled: enabled, authorization: authorization)
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }

    static func authorization(_ status: UNAuthorizationStatus) -> WallpaperNotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    static func canDeliver(_ authorization: WallpaperNotificationAuthorization) -> Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }
}
