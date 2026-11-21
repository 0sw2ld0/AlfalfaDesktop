import AppKit
import ApplicationServices
import Foundation

struct DesktopError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

enum DesktopOperation: String {
    case list, inspect, action, permissions
}

struct DesktopRequest {
    let operation: DesktopOperation
    let options: [String: String]

    init(command: String, options: [String: String]) throws {
        guard let operation = DesktopOperation(rawValue: command) else {
            throw DesktopError("Unknown command: \(command).")
        }
        let allowed: Set<String>
        switch operation {
        case .list: allowed = []
        case .permissions: allowed = ["request"]
        case .inspect: allowed = ["pid", "window", "capture", "max"]
        case .action:
            allowed = ["pid", "window", "kind", "path", "role", "x", "y", "x2", "y2",
                       "dx", "dy", "text", "key", "system-mouse", "hide-pointer"]
        }
        guard options.keys.allSatisfy(allowed.contains), options.values.allSatisfy({ $0.utf8.count <= 8_000 }) else {
            throw DesktopError("Unknown or oversized command option.")
        }
        for key in ["capture", "request", "system-mouse", "hide-pointer"] where options[key] != nil {
            guard options[key] == "true" || options[key] == "false" else {
                throw DesktopError("Option \(key) must be true or false.")
            }
        }
        if operation == .inspect || operation == .action {
            guard let pid = options["pid"].flatMap(Int32.init), pid > 0,
                  let index = Int(options["window"] ?? "0"), (0...1000).contains(index) else {
                throw DesktopError("A positive process ID and a valid window index are required.")
            }
        }
        if let maximum = options["max"] {
            guard let limit = Int(maximum), (1...400).contains(limit) else {
                throw DesktopError("The element limit must be between 1 and 400.")
            }
        }
        for key in ["x", "y", "x2", "y2", "dx", "dy"] {
            guard let value = options[key] else { continue }
            guard let number = Double(value), number.isFinite, abs(number) <= 20_000 else {
                throw DesktopError("Invalid coordinate or scroll distance.")
            }
        }
        if operation == .action {
            let actions = ["click", "double-click", "right-click", "type", "key", "scroll", "value",
                           "press", "drag", "focus", "hover", "menu"]
            guard let kind = options["kind"], actions.contains(kind) else {
                throw DesktopError("An action kind is required.")
            }
            if let path = options["path"] {
                let pattern = #"\A[0-9]+(?:\.[0-9]+){0,39}\z"#
                guard path.range(of: pattern, options: .regularExpression) != nil,
                      let role = options["role"], role.hasPrefix("AX") else {
                    throw DesktopError("An inspected element path requires its matching AX role.")
                }
            }
        }
        self.operation = operation
        self.options = options
    }

    var needsApproval: Bool { operation == .inspect || operation == .action || options["request"] == "true" }
}

enum AppAccess: Equatable {
    case blocked, readOnly, limited, full

    static func level(bundle: String, name: String, executable: String) -> Self {
        let blockedNames = [
            "alfalfacode", "alfalfamac", "alfalfadesktop", "alfalfa-desktop", "claude", "codex", "chatgpt"
        ]
        let blockedBundles = [
            "com.apple.scripteditor2", "com.apple.automator", "com.apple.shortcuts", "com.apple.keychainaccess",
            "com.apple.passwords", "com.1password.", "com.agilebits.", "com.bitwarden.", "com.lastpass.",
            "com.apple.systempreferences", "com.apple.systemsettings", "com.apple.securityagent",
            "com.apple.localauthentication", "com.anthropic.", "com.openai.", "com.alfalfacode.app",
            "com.cuycoders.alfalfacode", "com.cuycoders.alfalfadesktop"
        ]
        let limitedBundles = [
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "co.zeit.hyper", "com.microsoft.vscode",
            "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.zed",
            "com.jetbrains.", "com.apple.dt.xcode"
        ]
        let browsers = [
            "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
            "company.thebrowser.", "com.brave.browser", "com.operasoftware.", "com.vivaldi.vivaldi"
        ]
        let identifier = bundle.lowercased()
        func matches(_ entries: [String]) -> Bool {
            entries.contains { $0.hasSuffix(".") ? identifier.hasPrefix($0) : identifier == $0 }
        }
        if matches(blockedBundles) || blockedNames.contains(name.lowercased())
            || blockedNames.contains(executable.lowercased()) { return .blocked }
        if matches(limitedBundles) || name.lowercased() == "terminal" { return .limited }
        return matches(browsers) ? .readOnly : .full
    }

    func allows(_ request: DesktopRequest) -> Bool {
        switch self {
        case .blocked: return false
        case .readOnly: return request.operation == .inspect
        case .limited:
            return request.operation == .inspect ||
                (["click", "scroll", "hover"].contains(request.options["kind"] ?? "") &&
                 request.options["system-mouse"] != "true")
        case .full: return true
        }
    }
}

struct DesktopController {
    struct Prepared {
        let request: DesktopRequest
        let name: String?
        fileprivate let app: NSRunningApplication?
        fileprivate let window: AXUIElement?
    }

    func prepare(_ request: DesktopRequest) throws -> Prepared {
        guard let pid = request.options["pid"].flatMap(Int32.init) else {
            return Prepared(request: request, name: nil, app: nil, window: nil)
        }
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              !app.isTerminated, pid != ProcessInfo.processInfo.processIdentifier else {
            throw DesktopError("The target is not an available regular application.")
        }
        let level = AppAccess.level(bundle: app.bundleIdentifier ?? "", name: app.localizedName ?? "",
                                    executable: app.executableURL?.lastPathComponent ?? "")
        guard level.allows(request) else { throw DesktopError("The target application does not allow this operation.") }
        let (window, _) = try NativeDesktop().window(pid, Int(request.options["window"] ?? "0"))
        return Prepared(request: request, name: app.localizedName, app: app, window: window)
    }

    func execute(_ prepared: Prepared, approved: Bool) throws -> [String: Any] {
        let request = prepared.request
        guard !request.needsApproval || approved else { throw DesktopError("This operation requires approval.") }
        if let app = prepared.app, let window = prepared.window {
            let (current, _) = try NativeDesktop().window(app.processIdentifier, Int(request.options["window"] ?? "0"))
            guard !app.isTerminated, CFEqual(current, window) else {
                throw DesktopError("The target window changed after approval. Inspect it again.")
            }
        }

        var options = request.options
        var captureFolder: URL?
        if options["capture"] == "true" {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("alfalfa-desktop-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            options["capture"] = folder.appendingPathComponent("window.png").path
            captureFolder = folder
        } else {
            options.removeValue(forKey: "capture")
        }
        let flags = Set(request.options.filter { $0.value == "true" }.map(\.key))
        let native = NativeDesktop(arguments: options, flags: flags)
        switch request.operation {
        case .list: return native.listApplications()
        case .permissions: return native.permissions()
        case .action:
            guard let window = prepared.window else { throw DesktopError("Missing approved window.") }
            return try native.performAction(root: window)
        case .inspect:
            var keepCapture = false
            defer {
                if let captureFolder, !keepCapture { try? FileManager.default.removeItem(at: captureFolder) }
            }
            guard let window = prepared.window else { throw DesktopError("Missing approved window.") }
            let result = try native.inspect(root: window, index: Int(request.options["window"] ?? "0") ?? 0)
            keepCapture = result["capture"] != nil
            return result
        }
    }
}
