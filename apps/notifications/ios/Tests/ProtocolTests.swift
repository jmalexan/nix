import Foundation

@main
struct ProtocolTests {
    static func main() throws {
        // Compile/run on the macOS runner without signing or a simulator boot.
        for invalid in ["http://example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com?token=x"] {
            do {
                _ = try BridgeAPI.server(invalid)
                fatalError("Accepted an unsafe enrollment origin")
            } catch BridgeError.invalidServer { }
        }
        _ = try BridgeAPI.server("https://notifications.example.com")
        let data = Data("""
        {"id":"example","service":"backup","title":"Backup failed","body":"Open logs","url":"https://backup.example.com/jobs/1","image":null,"expires":2000000000,"active":true,"actions":[{"id":"logs","title":"Open logs","kind":"open","url":"https://backup.example.com/jobs/1"},{"id":"reply","title":"Reply","kind":"reply","url":null}],"future_field":true}
        """.utf8)
        let message = try JSONDecoder().decode(BridgeNotification.self, from: data)
        precondition(message.actions[1].kind == "reply")
        precondition(message.url.host == "backup.example.com")
        print("Notification protocol tests passed")
    }
}
