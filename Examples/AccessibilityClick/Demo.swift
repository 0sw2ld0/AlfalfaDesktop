import AppKit

final class ClickDemo: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let resultLabel = NSTextField(labelWithString: "Pendiente")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 70, y: 150, width: 380, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prueba de AlfalfaDesktop — Botón"

        let button = NSButton(title: "Verificar control", target: self, action: #selector(verifyClick))
        resultLabel.font = .systemFont(ofSize: 24, weight: .medium)

        let stack = NSStackView(views: [resultLabel, button])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        self.window = window
        window.orderFront(nil)
    }

    @objc private func verifyClick() {
        resultLabel.stringValue = "Control confirmado"
        resultLabel.textColor = .systemGreen
    }
}

let demo = ClickDemo()
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = demo
application.run()
