import AppKit
import ApplicationServices
import Foundation

/// The native desktop operations extracted from AlfalfaCode. Call through DesktopController for authorization.
final class NativeDesktop {
    private let arguments: [String: String]
    private let flags: Set<String>

    init(arguments: [String: String] = [:], flags: Set<String> = []) {
        self.arguments = arguments
        self.flags = flags
    }

    private func integer(_ key: String) -> Int? { arguments[key].flatMap(Int.init) }

    private func number(_ key: String) -> Double? {
        guard let value = arguments[key].flatMap(Double.init), value.isFinite else { return nil }
        return value
    }

    func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func text(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let windowIndex = value as? NSNumber { return windowIndex.stringValue }
        return nil
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as String),
              let size = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func windows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    func window(_ pid: pid_t, _ windowIndex: Int?) throws -> (AXUIElement, Int) {
        let allWindows = windows(pid)
        guard !allWindows.isEmpty else {
            throw DesktopError(AXIsProcessTrusted() ? "The app has no accessible windows."
                   : "Accessibility permission is required.")
        }
        let index = windowIndex ?? 0
        guard allWindows.indices.contains(index) else {
            throw DesktopError("Window \(index) is unavailable. The app has \(allWindows.count) windows.")
        }
        return (allWindows[index], index)
    }

    func elementAtPath(path: String, from root: AXUIElement) throws -> AXUIElement {
        var current = root
        if path.isEmpty { return current }
        for step in path.split(separator: ".") {
            guard let n = Int(step) else { throw DesktopError("Invalid accessibility path.") }
            let entries = children(current)
            guard entries.indices.contains(n) else {
                throw DesktopError("The accessibility path has changed. Inspect the window again.")
            }
            current = entries[n]
        }
        return current
    }

    func windowID(pid: pid_t, frame target: CGRect?, title: String?) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let owned = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0 }
        func rect(_ row: [String: Any]) -> CGRect? {
            guard let d = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: d as CFDictionary)
        }
        let frameMatches = target.map { target in
            owned.filter { row in
                guard let frame = rect(row) else { return false }
                return abs(frame.minX - target.minX) < 2 && abs(frame.minY - target.minY) < 2
                    && abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
            }
        } ?? []
        let titleMatches = (frameMatches.isEmpty ? owned : frameMatches).filter { row in
            title?.isEmpty == false && row[kCGWindowName as String] as? String == title
        }
        let matches = frameMatches.count == 1 ? frameMatches : titleMatches
        if matches.count == 1, let number = matches[0][kCGWindowNumber as String] as? NSNumber {
            return CGWindowID(number.uint32Value)
        }
        return nil
    }

    func permissions() -> [String: Any] {
        if flags.contains("request") {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        }
        return ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()]
    }

    func listApplications() -> [String: Any] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app -> [String: Any] in
                var record: [String: Any] = [
                    "pid": Int(app.processIdentifier), "name": app.localizedName ?? "", "active": app.isActive
                ]
                if let identifier = app.bundleIdentifier { record["bundleIdentifier"] = identifier }
                return record
            }
        return ["apps": apps, "accessibility": AXIsProcessTrusted()]
    }

    func inspect(root: AXUIElement, index: Int) throws -> [String: Any] {
        guard let pidNumber = integer("pid") else { throw DesktopError("A process ID is required.") }
        let pid = pid_t(pidNumber)
        guard let origin = frame(root) else { throw DesktopError("Could not read the window frame.") }
        let maximum = integer("max") ?? 400
        var elements: [[String: Any]] = []
        var lines: [String] = []
        var truncated = false
        func visit(_ element: AXUIElement, path: String, depth: Int) {
            if elements.count >= maximum || depth >= 40 { truncated = true; return }
            let role = text(element, kAXRoleAttribute as String) ?? "?"
            let elementIndex = elements.count
            var row: [String: Any] = ["index": elementIndex, "path": path, "role": role]
            var parts = [role.replacingOccurrences(of: "AX", with: "")]
            if let sub = text(element, kAXSubroleAttribute as String) { row["subrole"] = sub }
            for (key, name) in [("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
                                    ("value", kAXValueAttribute), ("help", kAXHelpAttribute),
                                    ("id", kAXIdentifierAttribute)] {
                if let value = text(element, name as String) {
                    let shortValue = String(value.prefix(key == "value" ? 200 : 120))
                    row[key] = shortValue
                    if key != "id" {
                        let line = shortValue.replacingOccurrences(of: "\n", with: " ")
                        parts.append("\(key)=\"\(line)\"")
                    }
                }
            }
            if let m = frame(element) {
                let x = Int(m.minX - origin.minX), y = Int(m.minY - origin.minY)
                row["x"] = x
                row["y"] = y
                row["width"] = Int(m.width)
                row["height"] = Int(m.height)
                parts.append("(\(x),\(y) \(Int(m.width))×\(Int(m.height)))")
            }
            if (attribute(element, kAXEnabledAttribute as String) as? Bool) == false {
                row["disabled"] = true
                parts.append("disabled")
            }
            if (attribute(element, kAXFocusedAttribute as String) as? Bool) == true {
                row["focused"] = true
                parts.append("focused")
            }
            let entries = actions(element).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
            if !entries.isEmpty { row["actions"] = entries }
            elements.append(row)
            lines.append(String(repeating: "  ", count: depth) + "[\(elementIndex)] " + parts.joined(separator: " "))
            for (n, child) in children(element).enumerated() {
                visit(child, path: path.isEmpty ? "\(n)" : "\(path).\(n)", depth: depth + 1)
            }
        }
        visit(root, path: "", depth: 0)
        var response: [String: Any] = [
            "window": index, "title": text(root, kAXTitleAttribute as String) ?? "",
            "width": Int(origin.width), "height": Int(origin.height), "elements": elements,
            "tree": lines.joined(separator: "\n"), "truncated": truncated,
        ]
        if let path = arguments["capture"] {
            if !CGPreflightScreenCaptureAccess() {
                response["screenRecordingRequired"] = true
                response["captureError"] = "Screen Recording permission is required."
            } else if let id = windowID(pid: pid, frame: origin, title: text(root, kAXTitleAttribute as String)) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(id), path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0, FileManager.default.fileExists(atPath: path) {
                        response["capture"] = path
                    } else {
                        response["captureError"] = "Could not capture the window."
                    }
                } catch {
                    response["captureError"] = "Could not start screencapture."
                }
            } else {
                response["captureError"] = "The window is not visible on this desktop."
            }
        }
        return response
    }

    let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116,
        "pagedown": 121, "left": 123, "right": 124, "down": 125,
        "up": 126, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift,
        "alt": .maskAlternate, "option": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
    ]

    func activate(_ pid: pid_t, _ root: AXUIElement) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(root, kAXRaiseAction as CFString)
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            usleep(50_000)
        }
        usleep(100_000)
    }

    func isPointOwnedByWindow(_ location: CGPoint, _ pid: pid_t, _ window: CGWindowID) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for row in info {
            guard let d = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: d as CFDictionary),
                  rect.contains(location) else { continue }
            if let alpha = row[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let owner = row[kCGWindowOwnerPID as String] as? Int32
            if owner == pid {
                return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window
            }
            let name = row[kCGWindowOwnerName as String] as? String ?? "another app"
            if name == "Window Server" || owner == ownPID || name.hasPrefix("alfalfa-apps") { continue }
            if name == "Dock", (row[kCGWindowLayer as String] as? Int) == 20, rect.width >= 600, rect.height >= 400 {
                continue
            }
            return false
        }
        return false
    }

    let popupRoles: Set<String> = ["AXPopUpButton", "AXMenuButton", "AXComboBox", "AXMenuItem"]

    func popupAtPoint(_ pid: pid_t, _ location: CGPoint) -> (AXUIElement, String)? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(location.x), Float(location.y),
                                               &found) == .success, var current = found else { return nil }
        for _ in 0..<3 {
            if let role = text(current, kAXRoleAttribute as String), popupRoles.contains(role) {
                let entries = actions(current)
                if entries.contains(kAXPressAction as String) { return (current, kAXPressAction as String) }
                if entries.contains(kAXShowMenuAction as String) { return (current, kAXShowMenuAction as String) }
                return nil
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return nil }
            current = next as! AXUIElement
        }
        return nil
    }

    func point(_ origin: CGRect, _ x: Double?, _ y: Double?) throws -> CGPoint {
        guard let x, let y else { throw DesktopError("Window-relative coordinates x and y are required.") }
        guard x >= 0, y >= 0, x < origin.width, y < origin.height else {
            throw DesktopError("The point (\(x), \(y)) is outside the window.")
        }
        return CGPoint(x: x, y: y)
    }

    // Window-relative events reach the target PID without moving the system pointer.
    let windowNumberField = CGEventField(rawValue: 51)!

    // Optional Window Server focus notification. The foreground application is not activated.
    typealias PostFocusRecord = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    typealias LookupProcessSerialNumber = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    static let postFocusRecord: PostFocusRecord? = {
        let framework = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        return dlopen(framework, RTLD_NOW).flatMap { dlsym($0, "SLPSPostEventRecordTo") }
            .map { unsafeBitCast($0, to: PostFocusRecord.self) }
    }()
    static let lookupProcessSerialNumber: LookupProcessSerialNumber? = {
        let framework = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        return dlopen(framework, RTLD_NOW).flatMap { dlsym($0, "GetProcessForPID") }
            .map { unsafeBitCast($0, to: LookupProcessSerialNumber.self) }
    }()

    func focusRecord(_ window: CGWindowID, _ changes: [(Int, UInt8)], fill: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        for (index, value) in changes { bytes[index] = value }
        withUnsafeBytes(of: window.littleEndian) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        if fill { for i in 0x20..<0x30 { bytes[i] = 0xff } }
        return bytes
    }

    func notifyFocus(_ pid: pid_t, _ window: CGWindowID, acquire: Bool) {
        guard let postFocusRecord = Self.postFocusRecord,
              let lookupProcessSerialNumber = Self.lookupProcessSerialNumber else { return }
        var psn = ProcessSerialNumber()
        guard lookupProcessSerialNumber(pid, &psn) == noErr else { return }
        var records = [focusRecord(window, [(0x08, 0x0d), (0x8a, acquire ? 0x01 : 0x02)], fill: false)]
        if acquire {
            records.append(focusRecord(window, [(0x08, 0x01), (0x3a, 0x10)], fill: true))
            records.append(focusRecord(window, [(0x08, 0x02), (0x3a, 0x10)], fill: true))
        }
        for record in records { _ = withUnsafePointer(to: &psn) { postFocusRecord($0, record) } }
        usleep(30_000)
    }

    func windowEvent(_ kind: NSEvent.EventType, _ local: CGPoint, window: CGWindowID, clickCount: Int) -> CGEvent? {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let pressure: Float = [.leftMouseDown, .rightMouseDown, .leftMouseDragged].contains(kind) ? 1 : 0
        guard let event = NSEvent.mouseEvent(with: kind, location: NSPoint(x: local.x, y: height - local.y),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: Int(window), context: nil, eventNumber: 0,
                                              clickCount: clickCount, pressure: pressure)?.cgEvent else { return nil }
        event.setIntegerValueField(windowNumberField, value: Int64(window))
        return event
    }

    func clickInBackground(_ local: CGPoint, pid: pid_t, window: CGWindowID, isRightClick: Bool, count: Int) {
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = isRightClick ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)
        windowEvent(.mouseMoved, local, window: window, clickCount: 0)?.postToPid(pid)
        usleep(20_000)
        for n in 1...max(1, count) {
            windowEvent(down, local, window: window, clickCount: n)?.postToPid(pid)
            usleep(30_000)
            windowEvent(up, local, window: window, clickCount: n)?.postToPid(pid)
            usleep(60_000)
        }
    }

    func dragInBackground(_ from: CGPoint, _ destination: CGPoint, pid: pid_t, window: CGWindowID) {
        windowEvent(.leftMouseDown, from, window: window, clickCount: 1)?.postToPid(pid)
        usleep(40_000)
        for step in 1...16 {
            let t = Double(step) / 16
            let location = CGPoint(x: from.x + (destination.x - from.x) * t, y: from.y + (destination.y - from.y) * t)
            windowEvent(.leftMouseDragged, location, window: window, clickCount: 1)?.postToPid(pid)
            usleep(16_000)
        }
        windowEvent(.leftMouseUp, destination, window: window, clickCount: 1)?.postToPid(pid)
    }

    func scrollInBackground(_ local: CGPoint, dx: Double, dy: Double, pid: pid_t, window: CGWindowID) {
        windowEvent(.mouseMoved, local, window: window, clickCount: 0)?.postToPid(pid)
        usleep(20_000)
        let steps = max(1, Int((max(abs(dx), abs(dy)) / 40).rounded(.up)))
        for _ in 0..<steps {
            guard let event = windowEvent(.mouseMoved, local, window: window, clickCount: 0) else { continue }
            event.type = .scrollWheel
            let y = -dy / Double(steps), x = -dx / Double(steps)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((y / 10).rounded()))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((x / 10).rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y.rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x.rounded()))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y / 10)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x / 10)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.postToPid(pid)
            usleep(16_000)
        }
    }

    private func postSystemMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    func clickWithSystemMouse(_ location: CGPoint, button: CGMouseButton, count: Int) {
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)
        postSystemMouse(.mouseMoved, at: location, button: button)
        usleep(40_000)
        for n in 1...max(1, count) {
            let pressEvent = CGEvent(mouseEventSource: nil, mouseType: down,
                                     mouseCursorPosition: location, mouseButton: button)
            let releaseEvent = CGEvent(mouseEventSource: nil, mouseType: up,
                                       mouseCursorPosition: location, mouseButton: button)
            pressEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            releaseEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            pressEvent?.post(tap: .cghidEventTap)
            usleep(30_000)
            releaseEvent?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    func requireFrontmostWindow(_ location: CGPoint, _ pid: pid_t, _ root: AXUIElement) throws {
        activate(pid, root)
        guard let target = windowID(pid: pid, frame: frame(root), title: text(root, kAXTitleAttribute as String)),
              isPointOwnedByWindow(location, pid, target) else {
            throw DesktopError("The system pointer requires the target window to be frontmost at that point.")
        }
    }

    func showPointer(_ global: CGPoint, destination: CGPoint? = nil, kind: String) {
        guard !flags.contains("hide-pointer") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var entries = ["cursor-overlay", "--x=\(global.x)", "--y=\(global.y)", "--kind=\(kind)"]
        if let destination { entries += ["--x2=\(destination.x)", "--y2=\(destination.y)"] }
        process.arguments = entries
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func runPointer() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let height = NSScreen.screens.first?.frame.height ?? 0
        let size = NSSize(width: 64, height: 64)
        let view = PointerView(frame: NSRect(origin: .zero, size: size))
        func origin(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: x - view.tip.x, y: height - y - view.tip.y)
        }
        let x = number("x") ?? 0, y = number("y") ?? 0
        let window = NSWindow(contentRect: NSRect(origin: origin(x, y), size: size), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.sharingType = .none
        window.contentView = view
        window.orderFrontRegardless()
        let start = Date()
        let end = (number("x2"), number("y2"))
        let isClick = arguments["kind"] != "move"
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            let t = Date().timeIntervalSince(start)
            if let x2 = end.0, let y2 = end.1 {
                let progress = min(1, t / 0.45)
                window.setFrameOrigin(origin(x + (x2 - x) * progress, y + (y2 - y) * progress))
            }
            if isClick {
                view.pulse = CGFloat(min(1, t / 0.5))
                view.needsDisplay = true
            }
            if t > 1.1 { window.alphaValue = CGFloat(max(0, 1 - (t - 1.1) / 0.4)) }
            if t > 1.55 { exit(0) }
        }
        app.run()
        exit(0)
    }

    func typeText(_ string: String, pid: pid_t) {
        for chunk in Array(string).chunked(16) {
            let units = Array(String(chunk).utf16)
            let pressEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let releaseEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            units.withUnsafeBufferPointer { buffer in
                pressEvent?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                releaseEvent?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            pressEvent?.postToPid(pid)
            releaseEvent?.postToPid(pid)
            usleep(20_000)
        }
    }

    func sendKey(_ chord: String, pid: pid_t) throws {
        var flags = CGEventFlags()
        var code: CGKeyCode?
        for component in chord.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let m = modifiers[component] { flags.insert(m) } else if let k = keyCodes[component] { code = k }
            else { throw DesktopError("Unknown key: \(component).") }
        }
        guard let code else { throw DesktopError("The key chord has no main key: \(chord).") }
        let pressEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let releaseEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        pressEvent?.flags = flags
        releaseEvent?.flags = flags
        pressEvent?.postToPid(pid)
        usleep(30_000)
        releaseEvent?.postToPid(pid)
    }

    func selectMenu(_ pid: pid_t, _ path: String) throws -> [String: Any] {
        let steps = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !steps.isEmpty else { throw DesktopError("A menu path such as File > Save is required.") }
        guard let menuBar = attribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as String) else {
            throw DesktopError("The app has no accessible menu bar.")
        }
        var current = menuBar as! AXUIElement
        func titles(_ entries: [AXUIElement]) -> [String] {
            entries.compactMap { text($0, kAXTitleAttribute as String) }
        }
        for (n, step) in steps.enumerated() {
            var options = children(current)
            if options.count == 1, text(options[0], kAXRoleAttribute as String) == "AXMenu" {
                options = children(options[0])
            }
            let query = step.lowercased()
            let candidate = options.first { (text($0, kAXTitleAttribute as String) ?? "").lowercased() == query }
                ?? options.first { (text($0, kAXTitleAttribute as String) ?? "").lowercased().hasPrefix(query) }
            guard let selected = candidate else {
                let available = titles(options).filter { !$0.isEmpty }.prefix(30).joined(separator: ", ")
                throw DesktopError("No menu item matches \(step). Available items: \(available).")
            }
            if n == steps.count - 1 {
                if (attribute(selected, kAXEnabledAttribute as String) as? Bool) == false {
                    throw DesktopError("The menu item \(step) is disabled.")
                }
                let response = AXUIElementPerformAction(selected, kAXPressAction as CFString)
                guard response == .success else {
                    throw DesktopError("The menu did not accept \(step) (\(response.rawValue)).")
                }
            } else {
                current = selected
            }
        }
        usleep(250_000)
        return ["performed": true, "method": "menu"]
    }

    func performAction(root: AXUIElement) throws -> [String: Any] {
        guard AXIsProcessTrusted() else {
            throw DesktopError("Accessibility permission is required.")
        }
        guard let pidNumber = integer("pid"), let kind = arguments["kind"] else {
            throw DesktopError("A process ID and action kind are required.")
        }
        let pid = pid_t(pidNumber)
        if kind == "menu" { return try selectMenu(pid, arguments["text"] ?? "") }
        guard let origin = frame(root) else { throw DesktopError("Could not read the window frame.") }
        let usesSystemMouse = flags.contains("system-mouse")
        var element: AXUIElement?
        if let path = arguments["path"] {
            let found = try elementAtPath(path: path, from: root)
            if let role = arguments["role"], text(found, kAXRoleAttribute as String) != role {
                throw DesktopError("The element role has changed from \(role). Inspect the window again.")
            }
            element = found
        }
        func targetPoint() throws -> CGPoint {
            if let element, let frame = frame(element) {
                return try point(origin, frame.midX - origin.minX, frame.midY - origin.minY)
            }
            return try point(origin, number("x"), number("y"))
        }
        func global(_ local: CGPoint) -> CGPoint { CGPoint(x: origin.minX + local.x, y: origin.minY + local.y) }
        func requireWindowID() throws -> CGWindowID {
            guard let id = windowID(pid: pid, frame: origin, title: text(root, kAXTitleAttribute as String)) else {
                throw DesktopError("The target window is not visible on this desktop.")
            }
            return id
        }
        var method = usesSystemMouse ? "system-mouse" : "background"
        var focusedWindow: CGWindowID?
        defer {
            if let focusedWindow { notifyFocus(pid, focusedWindow, acquire: false) }
        }
        func backgroundWindow() throws -> CGWindowID {
            let id = try requireWindowID()
            notifyFocus(pid, id, acquire: true)
            focusedWindow = id
            return id
        }
        switch kind {
        case "focus":
            activate(pid, root)
            method = "focus"
        case "press":
            guard let element else { throw DesktopError("Press requires an accessibility element.") }
            let name = kAXPressAction as String
            let response = AXUIElementPerformAction(element, name as CFString)
            guard response == .success else {
                throw DesktopError("The element did not accept \(name) (\(response.rawValue)).")
            }
            showPointer(global(try targetPoint()), kind: "click")
            method = "AXPress"
        case "click", "double-click", "right-click":
            let local = try targetPoint()
            if kind == "click", !usesSystemMouse, element == nil,
               let (popup, action) = popupAtPoint(pid, global(local)),
               attribute(popup, kAXWindowAttribute as String).map({ CFEqual($0, root) }) == true,
               AXUIElementPerformAction(popup, action as CFString) == .success {
                showPointer(global(local), kind: "click")
                method = "AXPress"
                break
            }
            if kind == "click", !usesSystemMouse, let element, actions(element).contains(kAXPressAction as String),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                method = "AXPress"
            } else if usesSystemMouse {
                try requireFrontmostWindow(global(local), pid, root)
                clickWithSystemMouse(global(local), button: kind == "right-click" ? .right : .left,
                                     count: kind == "double-click" ? 2 : 1)
            } else {
                clickInBackground(local, pid: pid, window: try backgroundWindow(), isRightClick: kind == "right-click",
                            count: kind == "double-click" ? 2 : 1)
            }
            showPointer(global(local), kind: "click")
        case "type", "key":
            if usesSystemMouse { activate(pid, root) } else { _ = try backgroundWindow() }
            if let element {
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                usleep(80_000)
            }
            if kind == "type" {
                guard let string = arguments["text"] else { throw DesktopError("Text is required.") }
                typeText(string, pid: pid)
            } else {
                guard let chord = arguments["key"] else { throw DesktopError("A key chord is required.") }
                try sendKey(chord, pid: pid)
            }
            method = usesSystemMouse ? "keyboard" : "backgroundKeyboard"
        case "hover":
            let local = try targetPoint()
            if usesSystemMouse {
                try requireFrontmostWindow(global(local), pid, root)
                postSystemMouse(.mouseMoved, at: global(local))
            } else {
                let id = try backgroundWindow()
                for step in 0..<3 {
                    let location = CGPoint(x: local.x - 2 + Double(step), y: local.y)
                    windowEvent(.mouseMoved, location, window: id, clickCount: 0)?.postToPid(pid)
                    usleep(30_000)
                }
            }
            showPointer(global(local), kind: "move")
            usleep(700_000)
        case "value":
            guard let element, let string = arguments["text"] else {
                throw DesktopError("Setting a value requires an element and text.")
            }
            let response = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, string as CFString)
            guard response == .success else {
                throw DesktopError("The element did not accept the new value (\(response.rawValue)).")
            }
            method = "AXValue"
        case "scroll":
            let local = try targetPoint()
            let dx = number("dx") ?? 0, dy = number("dy") ?? 0
            if usesSystemMouse {
                try requireFrontmostWindow(global(local), pid, root)
                postSystemMouse(.mouseMoved, at: global(local))
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                     wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
                event?.location = global(local)
                event?.post(tap: .cghidEventTap)
            } else {
                scrollInBackground(local, dx: dx, dy: dy, pid: pid, window: try backgroundWindow())
            }
            showPointer(global(local), kind: "move")
        case "drag":
            let from = try targetPoint()
            let destination = try point(origin, number("x2"), number("y2"))
            if usesSystemMouse {
                try requireFrontmostWindow(global(from), pid, root)
                try requireFrontmostWindow(global(destination), pid, root)
                postSystemMouse(.leftMouseDown, at: global(from))
                for step in 1...12 {
                    let t = Double(step) / 12
                    let location = CGPoint(x: global(from).x + (global(destination).x - global(from).x) * t,
                                        y: global(from).y + (global(destination).y - global(from).y) * t)
                    postSystemMouse(.leftMouseDragged, at: location)
                    usleep(15_000)
                }
                postSystemMouse(.leftMouseUp, at: global(destination))
            } else {
                dragInBackground(from, destination, pid: pid, window: try backgroundWindow())
            }
            showPointer(global(from), destination: global(destination), kind: "move")
        default:
            throw DesktopError("Unknown action: \(kind).")
        }
        usleep(250_000)
        return ["performed": true, "method": method]
    }
}

final class PointerView: NSView {
    var pulse: CGFloat = 0
    let tip = CGPoint(x: 14, y: 46)

    override func draw(_ dirtyRect: NSRect) {
        let green = NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.29, alpha: 1)
        if pulse > 0 {
            let radius = 6 + 14 * pulse
            let bounds = NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)
            let ring = NSBezierPath(ovalIn: bounds)
            green.withAlphaComponent(0.55 * (1 - pulse)).setStroke()
            ring.lineWidth = 3
            ring.stroke()
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: tip.x + x, y: tip.y + y) }
        let leaf = NSBezierPath()
        leaf.move(to: tip)
        leaf.curve(to: p(16, -11), controlPoint1: p(10, -1), controlPoint2: p(15, -4))
        leaf.curve(to: p(27, -8), controlPoint1: p(19, -7), controlPoint2: p(23, -7))
        leaf.curve(to: p(18, -21), controlPoint1: p(27, -15), controlPoint2: p(23, -20))
        leaf.line(to: p(23, -25))
        leaf.curve(to: p(20, -28), controlPoint1: p(23, -27), controlPoint2: p(22, -29))
        leaf.line(to: p(14, -22))
        leaf.curve(to: p(2, -24), controlPoint1: p(11, -25), controlPoint2: p(6, -25))
        leaf.curve(to: p(6, -13), controlPoint1: p(2, -19), controlPoint2: p(3, -15))
        leaf.curve(to: tip, controlPoint1: p(2, -10), controlPoint2: p(0, -4))
        leaf.close()

        NSColor.black.withAlphaComponent(0.62).setStroke()
        leaf.lineWidth = 3.5
        leaf.lineJoinStyle = .round
        leaf.stroke()
        green.setFill()
        leaf.fill()
        NSColor.white.setStroke()
        leaf.lineWidth = 1.5
        leaf.stroke()

        let veins = NSBezierPath()
        veins.move(to: p(19, -24))
        veins.curve(to: p(4, -5), controlPoint1: p(15, -18), controlPoint2: p(10, -13))
        veins.move(to: p(14, -18))
        veins.curve(to: p(23, -12), controlPoint1: p(17, -18), controlPoint2: p(21, -14))
        veins.move(to: p(12, -15))
        veins.curve(to: p(6, -20), controlPoint1: p(10, -17), controlPoint2: p(8, -19))
        NSColor.white.withAlphaComponent(0.78).setStroke()
        veins.lineCapStyle = .round
        veins.lineWidth = 1.2
        veins.stroke()
    }
}
extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
