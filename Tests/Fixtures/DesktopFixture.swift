import AppKit

final class DesktopFixture: NSObject, NSApplicationDelegate {
    private let output: URL
    private let countLabel = NSTextField(labelWithString: "Count: 0")
    private var count = 0
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 350, width: 400, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AlfalfaDesktop fixture"
        countLabel.frame = NSRect(x: 24, y: 120, width: 260, height: 38)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        let button = NSButton(title: "Increment", target: self, action: #selector(increment))
        button.frame = NSRect(x: 24, y: 40, width: 130, height: 34)
        window.contentView?.addSubview(countLabel)
        window.contentView?.addSubview(button)
        self.window = window
        window.orderFrontRegardless()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.write(["event": "activation", "pid": Int(app.processIdentifier)])
            }
        }
        write(["event": "ready", "pid": Int(ProcessInfo.processInfo.processIdentifier)])
    }

    @objc private func increment() {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        count += 1
        countLabel.stringValue = "Count: \(count)"
        window?.backgroundColor = count.isMultiple(of: 2) ? .systemGreen : .systemYellow
        let after = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        write(["event": "click", "count": count, "before": Int(before), "after": Int(after)])
    }

    private func write(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(0x0A)
        if let file = try? FileHandle(forWritingTo: output) {
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
            try? file.close()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let fixture = DesktopFixture(output: URL(fileURLWithPath: CommandLine.arguments[1]))
app.delegate = fixture
app.run()
