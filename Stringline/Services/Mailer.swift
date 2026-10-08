import AppKit

/// Opens a Mail draft. Stringline never sends anything itself.
enum Mailer {
    @MainActor
    static func compose(to recipient: String?, subject: String, body: String, attachments: [URL] = []) {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        if let recipient, !recipient.isEmpty { service.recipients = [recipient] }
        service.subject = subject
        var items: [Any] = [body]
        items.append(contentsOf: attachments)
        if service.canPerform(withItems: items) {
            service.perform(withItems: items)
        } else if let url = URL(string: "mailto:\(recipient ?? "")") {
            NSWorkspace.shared.open(url)
        }
    }
}
