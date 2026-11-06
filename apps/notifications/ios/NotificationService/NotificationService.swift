import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var task: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        guard let updated = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            handler = nil
            return
        }
        content = updated
        task = Task {
            defer { finish() }
            guard let bridge = updated.userInfo["bridge"] as? [String: Any],
                  bridge["version"] as? Int == 1,
                  let id = bridge["id"] as? String,
                  let connection = ConnectionStore.load(),
                  let notification = try? await BridgeAPI.notification(id, connection: connection),
                  notification.active else { return }
            let actions: [UNNotificationAction] = notification.actions.compactMap { action in
                switch action.kind {
                case "open":
                    return UNNotificationAction(identifier: action.id, title: action.title, options: [.foreground])
                case "respond":
                    return UNNotificationAction(identifier: action.id, title: action.title, options: [.authenticationRequired])
                case "reply":
                    return UNTextInputNotificationAction(identifier: action.id, title: action.title,
                                                         options: [.authenticationRequired],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
                default: return nil
                }
            }
            let identifier = "bridge-\(id)"
            let category = UNNotificationCategory(identifier: identifier, actions: actions,
                                                   intentIdentifiers: [], options: [])
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories()
            if categories.count >= 64 {
                let delivered = await center.deliveredNotifications()
                let active = Set(delivered.map { $0.request.content.categoryIdentifier })
                categories = Set(categories.filter { active.contains($0.identifier) }
                    .sorted { $0.identifier < $1.identifier }.prefix(63))
            }
            categories.insert(category)
            center.setNotificationCategories(categories)
            updated.categoryIdentifier = identifier
            if let image = notification.image,
               let attachment = try? await Self.attachment(image) {
                updated.attachments = [attachment]
            }
        }
    }

    private static func attachment(_ url: URL) async throws -> UNNotificationAttachment {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw BridgeError.unavailable }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (bytes, response) = try await session.bytes(for: request)
        let types = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif"]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let mime = response.mimeType, let suffix = types[mime],
              response.expectedContentLength <= 5_000_000 else { throw BridgeError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 5_000_000 else { throw BridgeError.unavailable }
            data.append(byte)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(suffix)")
        try data.write(to: file, options: .atomic)
        return try UNNotificationAttachment(identifier: "image", url: file)
    }

    private func finish() {
        lock.lock()
        let callback = handler
        handler = nil
        let best = content
        lock.unlock()
        if let callback, let best { callback(best) }
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        finish()
    }
}
