import SwiftUI
import UIKit
import UserNotifications

@main
struct BridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { WindowGroup { ConnectionView(model: delegate.model) } }
}

@MainActor
final class ConnectionModel: ObservableObject {
    @Published var connected = ConnectionStore.load() != nil
    @Published var status = ""
    @Published var busy = false
    @Published var apnsToken: String?

    private func report(_ error: Error) {
        if case BridgeError.disconnected = error {
            ConnectionStore.clear()
            connected = false
        }
        status = error.localizedDescription
    }

    var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func register() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard allowed else { status = "Enable notifications in iPhone Settings."; return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch { status = "Couldn’t enable notifications." }
    }

    func updateToken(_ token: String) async {
        apnsToken = token
        guard let connection = ConnectionStore.load() else { return }
        do {
            _ = try await BridgeAPI.request(server: connection.server, path: "v1/device/registration", token: connection.token,
                                            body: ["apns_token": token, "environment": environment])
            status = "Connected"
        } catch { report(error) }
    }

    func enroll(server: String, code: String) async {
        busy = true
        defer { busy = false }
        do {
            let origin = try BridgeAPI.server(server.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let apnsToken else { status = "Waiting for Apple push registration. Try again shortly."; return }
            let data = try await BridgeAPI.request(server: origin, path: "v1/enroll", body: [
                "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
                "name": UIDevice.current.name, "apns_token": apnsToken, "environment": environment
            ])
            struct Credential: Decodable { let id: String; let token: String }
            let result = try JSONDecoder().decode(Credential.self, from: data)
            try ConnectionStore.save(EnrollmentCredential(server: origin, id: result.id, token: result.token))
            connected = true
            status = "Connected"
        } catch { report(error) }
    }

    func settings() async {
        guard let connection = ConnectionStore.load() else { return }
        do {
            let data = try await BridgeAPI.request(server: connection.server, path: "v1/device/settings", token: connection.token, body: [:])
            struct Link: Decodable { let url: URL }
            let url = try JSONDecoder().decode(Link.self, from: data).url
            guard url.scheme == "https", url.host == connection.server.host else { throw BridgeError.unavailable }
            await UIApplication.shared.open(url)
        } catch { report(error) }
    }

    func disconnect() async {
        guard let connection = ConnectionStore.load() else { return }
        do {
            _ = try await BridgeAPI.request(server: connection.server, path: "v1/device/revoke", token: connection.token, body: [:])
            ConnectionStore.clear()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            connected = false
            status = "Disconnected"
        } catch { report(error) }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: ConnectionModel
    @State private var server = ""
    @State private var code = ""
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                if model.connected {
                    Button("Notification settings") { Task { await model.settings() } }
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                } else {
                    TextField("https://notifications.example.com", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Enrollment code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Connect") {
                        Task { await model.enroll(server: server, code: code); code = "" }
                    }.disabled(model.busy || model.apnsToken == nil || server.isEmpty || code.isEmpty)
                }
                if !model.status.isEmpty { Text(model.status).accessibilityIdentifier("connectionStatus") }
            }
            .navigationTitle("Notifications")
            .task { await model.register() }
            .confirmationDialog("Disconnect this device?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = ConnectionModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let value = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await model.updateToken(value) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.status = "Couldn’t register for Apple push. Check your connection and try reopening the app."
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task {
            defer { completionHandler() }
            guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
                  let bridge = response.notification.request.content.userInfo["bridge"] as? [String: Any],
                  bridge["version"] as? Int == 1,
                  let id = bridge["id"] as? String else { return }
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let value = bridge["url"] as? String, let url = URL(string: value),
               url.scheme == "https", url.user == nil, url.password == nil {
                await UIApplication.shared.open(url)
                return
            }
            guard let connection = ConnectionStore.load() else { return }
            do {
                let notification = try await BridgeAPI.notification(id, connection: connection)
                let action = notification.actions.first { $0.id == response.actionIdentifier }
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier || action?.kind == "open" {
                    let url = action?.url ?? notification.url
                    guard url.scheme == "https", url.user == nil, url.password == nil else { throw BridgeError.unavailable }
                    await UIApplication.shared.open(url)
                    return
                }
                guard notification.active, notification.expires > Date().timeIntervalSince1970,
                      let action, ["respond", "reply"].contains(action.kind) else { throw BridgeError.unavailable }
                var body: [String: Any] = ["action": action.id]
                if action.kind == "reply" {
                    guard let reply = response as? UNTextInputNotificationResponse else { throw BridgeError.unavailable }
                    body["text"] = reply.userText
                }
                // One explicit attempt. Never queue or automatically retry decisions.
                _ = try await BridgeAPI.request(server: connection.server, path: "v1/device/notifications/\(id)/response",
                                                token: connection.token, body: body)
            } catch {
                model.status = error.localizedDescription
                let content = UNMutableNotificationContent()
                content.title = "Open the service to check"
                content.body = "Your response couldn’t be confirmed."
                content.userInfo = ["bridge": bridge]
                try? await center.add(UNNotificationRequest(identifier: "response-error-\(id)", content: content, trigger: nil))
            }
        }
    }
}
