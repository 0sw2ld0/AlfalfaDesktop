import Foundation

enum DesktopRelease {
    static let displayName = "Alfalfa Computer Use"
    static let version = "0.1.1"
}

@main enum EntryPoint {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
                print("""
                    \(DesktopRelease.displayName)

                    Usage: alfalfa-desktop --version | list | permissions [--request] | pacai
                           alfalfa-desktop inspect --pid=PID [--window=0] [--capture] --approve
                           alfalfa-desktop action --pid=PID --kind=click --path=PATH --role=AXButton --approve
                    """)
                return
            }
            let (options, approved) = try parse(Array(arguments.dropFirst()))
            switch command {
            case "--version":
                guard options.isEmpty, !approved else { throw DesktopError("--version takes no options.") }
                print("AlfalfaDesktop \(DesktopRelease.version)")
            case "pacai", "--pacai":
                guard options.isEmpty, !approved else { throw DesktopError("PACAI uses per-operation approvals.") }
                try PACAIAdapter().run()
            case "cursor-overlay":
                NativeDesktop(arguments: options).runPointer()
            default:
                let request = try DesktopRequest(command: command, options: options)
                guard !request.needsApproval || approved else {
                    throw DesktopError("Pass --approve to authorize this operation.")
                }
                let controller = DesktopController()
                let response = try controller.execute(controller.prepare(request), approved: approved)
                try writeJSON(response, to: .standardOutput)
            }
        } catch {
            try? writeJSON(["error": error.localizedDescription], to: .standardError)
            exit(1)
        }
    }

    static func parse(_ arguments: [String]) throws -> ([String: String], Bool) {
        var options: [String: String] = [:]
        var approved = false
        for argument in arguments {
            if argument == "--approve" {
                guard !approved else { throw DesktopError("Duplicate --approve flag.") }
                approved = true
                continue
            }
            let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard argument.hasPrefix("--"), let name = parts.first, !name.isEmpty, options[String(name)] == nil else {
                throw DesktopError("Invalid or duplicate option: \(argument).")
            }
            options[String(name)] = parts.count == 2 ? String(parts[1]) : "true"
        }
        return (options, approved)
    }
}

func writeJSON(_ value: [String: Any], to handle: FileHandle, limit: Int = 1_048_576) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    guard data.count <= limit else { throw DesktopError("The JSONL record exceeds the negotiated size limit.") }
    try handle.write(contentsOf: data)
}
