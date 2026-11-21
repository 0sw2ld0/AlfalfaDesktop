import CoreFoundation
import CryptoKit
import Darwin
import Foundation

final class PACAIAdapter {
    static let commandSchema = "urn:alfalfadesktop:command:v1"
    static let resultSchema = "urn:alfalfadesktop:result:v1"
    static let maxRecordBytes = 1_048_576

    private let input: FileHandle
    private let output: FileHandle
    private let controller = DesktopController()
    private let clock = ISO8601DateFormatter()
    private var session = ""
    private var clientSequence = 0
    private var agentSequence = 0
    private var clientLimit = maxRecordBytes
    private var received: [String: SHA256.Digest] = [:]
    private var buffer = Data()
    private var pending: Pending?
    private var queue: [[String: Any]] = []
    private var isClosed = false

    private struct Pending {
        let runID: String
        let toolID: String
        let approvalID: String
        let operation: DesktopController.Prepared
    }

    init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
    }

    func run() throws {
        guard let first = try read() else { return }
        session = try Self.string(first, "session", minimum: 16)
        try receive(first)
        while !isClosed, let record = try read() {
            try receive(record)
            while !isClosed, pending == nil, !queue.isEmpty {
                let queued = queue.removeFirst()
                try start(queued)
            }
        }
    }

    private func receive(_ record: [String: Any]) throws {
        let id = try Self.string(record, "id", minimum: 8)
        guard record["session"] as? String == session, record["sender"] as? String == "client",
              record["pacai"] as? String == "0.3", let sequence = Self.integer(record["seq"]),
              let time = record["time"] as? String, time.hasSuffix("Z"),
              Self.isTimeValid(time),
              let type = record["type"] as? String, let payload = record["payload"] as? [String: Any] else {
            try sendError("invalid_message", "Invalid PACAI envelope.", reference: id)
            return
        }
        let fingerprint = try Self.fingerprint(record)
        if let previous = received[id] {
            if previous != fingerprint { try sendError("invalid_message", "A message ID was reused.", reference: id) }
            return
        }
        guard sequence == clientSequence + 1 else {
            try sendError("seq_unrecoverable", "Unexpected client sequence.", reference: id)
            isClosed = true
            return
        }
        guard received.count < 4_096 else {
            try send("close", ["reason": "Session message limit reached."])
            isClosed = true
            return
        }
        received[id] = fingerprint
        clientSequence = sequence

        if sequence == 1 {
            guard type == "hello" else {
                try sendError("invalid_message", "The first message must be hello.", reference: id)
                isClosed = true
                return
            }
            try negotiate(id: id, payload: payload)
            return
        }

        switch type {
        case "input":
            guard payload["mode"] as? String != "steer", payload["blocks"] is [[String: Any]] else {
                try sendError("invalid_message", "Expected an input with structured command blocks.", reference: id)
                return
            }
            if pending == nil {
                try start(record)
            } else if queue.count < 16 {
                queue.append(record)
            } else {
                try sendError("invalid_message", "The execution queue is full.", reference: id)
            }
        case "approval_result":
            try resolve(record, payload: payload, id: id)
        case "interrupt":
            guard let pending, payload["run_id"] as? String == pending.runID else {
                try sendError("unknown_run", "There is no active execution with that ID.", reference: id)
                return
            }
            self.pending = nil
            try send("approval_result", ["decision": "cancelled"], replyTo: pending.approvalID)
            try end(pending.runID, toolID: pending.toolID, status: "cancelled", outcome: "interrupted",
                    detail: "Interrupted before execution.")
        case "close":
            pending = nil
            isClosed = true
        case "heartbeat", "error": break
        default:
            try sendError("invalid_message", "Unsupported client message: \(type).", reference: id)
        }
    }

    private func negotiate(id: String, payload: [String: Any]) throws {
        if let limits = payload["limits"] as? [String: Any], let raw = limits["max_message_bytes"] {
            guard let size = Self.integer(raw), size >= 1024 else {
                try sendError("invalid_message", "The PACAI record limit must be at least 1024 bytes.", reference: id)
                isClosed = true
                return
            }
            clientLimit = min(size, Self.maxRecordBytes)
        }
        try send("hello", [
            "versions": ["0.3"], "profiles": [], "extensions": [],
            "limits": ["max_message_bytes": Self.maxRecordBytes],
            "implementation": ["name": "AlfalfaDesktop"]
        ])
        guard (payload["versions"] as? [String])?.contains("0.3") == true else {
            try sendError("version_incompatible", "This adapter supports PACAI 0.3.", reference: id)
            isClosed = true
            return
        }
        try send("session_started", [
            "version": "0.3", "profiles": [], "extensions": [], "agent": ["name": "AlfalfaDesktop"]
        ], replyTo: id)
    }

    private func start(_ record: [String: Any]) throws {
        guard let id = record["id"] as? String, let payload = record["payload"] as? [String: Any],
              let blocks = payload["blocks"] as? [[String: Any]] else {
            throw DesktopError("Malformed queued input.")
        }
        let runID = try send("run_started", ["input_id": id])
        let request: DesktopRequest
        let operation: DesktopController.Prepared
        do {
            let commands = blocks.filter { $0["type"] as? String == "structured" &&
                $0["schema"] as? String == Self.commandSchema }
            guard commands.count == 1, let data = commands.first?["data"] as? [String: Any],
                  let command = data["command"] as? String, let options = data["options"] as? [String: String] else {
                throw DesktopError("Provide one structured AlfalfaDesktop command.")
            }
            request = try DesktopRequest(command: command, options: options)
            operation = try controller.prepare(request)
        } catch {
            try finish(runID, outcome: "failed", detail: error.localizedDescription)
            return
        }
        var arguments = request.options
        arguments["application"] = operation.name
        let toolID = try send("tool_start", [
            "run_id": runID, "name": request.operation.rawValue, "arguments": arguments, "side": "agent"
        ])
        if request.needsApproval {
            let approvalID = try send("approval_request", [
                "run_id": runID, "tool_call_id": toolID, "name": request.operation.rawValue,
                "arguments": arguments, "digest": try Self.argumentDigest(arguments), "reason": "policy",
                "scopes": ["once"]
            ])
            pending = Pending(runID: runID, toolID: toolID, approvalID: approvalID, operation: operation)
        } else {
            try execute(operation, runID: runID, toolID: toolID)
        }
    }

    private func resolve(_ record: [String: Any], payload: [String: Any], id: String) throws {
        guard let pending, record["reply_to"] as? String == pending.approvalID else {
            try sendError("unknown_approval", "No pending approval matches the reply.", reference: id)
            return
        }
        let decision = payload["decision"] as? String
        guard (decision == "approved" && payload["scope"] as? String == "once")
                || (decision == "denied" && payload["scope"] == nil) else {
            try sendError("invalid_message", "Expected a denial or approval with once scope.", reference: id)
            return
        }
        self.pending = nil
        if decision == "approved" {
            try execute(pending.operation, runID: pending.runID, toolID: pending.toolID)
        } else {
            try end(pending.runID, toolID: pending.toolID, status: "error", outcome: "blocked",
                    detail: "The client denied the operation.")
        }
    }

    private func execute(_ prepared: DesktopController.Prepared, runID: String, toolID: String) throws {
        do {
            let value = try controller.execute(prepared, approved: true)
            try send("tool_end", [
                "tool_call_id": toolID, "status": "success",
                "output": [["type": "structured", "schema": Self.resultSchema, "data": value]]
            ])
        } catch {
            try end(runID, toolID: toolID, status: "error", outcome: "failed", detail: error.localizedDescription)
            return
        }
        try finish(runID, outcome: "success")
    }

    private func end(_ runID: String, toolID: String, status: String, outcome: String, detail: String) throws {
        try send("tool_end", ["tool_call_id": toolID, "status": status, "summary": detail])
        try finish(runID, outcome: outcome, detail: detail)
    }

    private func finish(_ runID: String, outcome: String, detail: String? = nil) throws {
        var payload = ["run_id": runID, "outcome": outcome]
        if let detail { payload["detail"] = detail }
        try send("run_finished", payload)
    }

    private func sendError(_ code: String, _ message: String, reference: String) throws {
        try send("error", ["code": code, "message": message, "ref": reference])
    }

    @discardableResult
    private func send(_ type: String, _ payload: [String: Any], replyTo: String? = nil) throws -> String {
        let id = UUID().uuidString
        var envelope: [String: Any] = [
            "pacai": "0.3", "id": id, "type": type, "session": session, "sender": "agent",
            "seq": agentSequence + 1, "time": clock.string(from: Date()), "payload": payload
        ]
        envelope["reply_to"] = replyTo
        try writeJSON(envelope, to: output, limit: clientLimit)
        agentSequence += 1
        return id
    }

    private func read() throws -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let record = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard record.count < Self.maxRecordBytes, String(data: record, encoding: .utf8) != nil,
                      let value = try JSONSerialization.jsonObject(with: record) as? [String: Any] else {
                    throw DesktopError("Invalid PACAI JSONL record.")
                }
                return value
            }
            guard buffer.count < Self.maxRecordBytes else {
                throw DesktopError("The incoming PACAI record exceeds the JSONL size limit.")
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                if !buffer.isEmpty { throw DesktopError("PACAI JSONL requires a terminating newline.") }
                return nil
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    private static func string(_ record: [String: Any], _ key: String, minimum: Int) throws -> String {
        guard let value = record[key] as? String, (minimum...128).contains(value.utf8.count) else {
            throw DesktopError("Invalid PACAI \(key).")
        }
        return value
    }

    private static func isTimeValid(_ value: String) -> Bool {
        value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z\z"#,
                    options: .regularExpression) != nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private static func fingerprint(_ record: [String: Any]) throws -> SHA256.Digest {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: data)
    }

    static func argumentDigest(_ arguments: [String: String]) throws -> String {
        // Arguments are a flat string dictionary. Sort keys by UTF-16 as required by RFC 8785.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let pairs = try arguments.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { key in
            let name = String(decoding: try encoder.encode(key), as: UTF8.self)
            let value = String(decoding: try encoder.encode(arguments[key] ?? ""), as: UTF8.self)
            return name + ":" + value
        }
        let digest = SHA256.hash(data: Data(("{" + pairs.joined(separator: ",") + "}").utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
