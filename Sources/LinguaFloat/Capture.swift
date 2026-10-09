import AppKit
import ApplicationServices
import Vision

enum CaptureKind: Equatable {
    case selection, field, window, clipboard, ocr, herdr, draft, stream
    var label: String {
        switch self {
        case .stream: "新內容"
        case .selection: "選取文字"
        case .field: "焦點欄位"
        case .window: "整個視窗"
        case .clipboard: "剪貼簿"
        case .ocr: "框選 OCR"
        case .herdr: "Herdr 窗格"
        case .draft: "草稿"
        }
    }
}
/// Why a capture produced nothing. Each case maps to a different recovery the panel can offer.
enum CaptureFailure: LocalizedError, Equatable {
    case notTrusted, noSelection, noText, secureField
    var errorDescription: String? {
        switch self {
        case .notTrusted: "需要「輔助使用」權限才能讀取其他 App 的文字。"
        case .noSelection: "沒有選取的文字。"
        case .noText: "這個 App 沒有提供可讀取的文字。"
        case .secureField: "不讀取密碼欄位。"
        }
    }
}
struct TextSnapshot {
    let text: String
    let element: AXUIElement?
    let fullValue: String?
    let pid: pid_t
    /// Whole-field replacement is possible (focused field, settable, text is the entire value).
    let editable: Bool
    var kind: CaptureKind = .field
    /// The selected range itself can be swapped through AXSelectedText, leaving the rest of the field alone.
    var selectionReplaceable = false
    /// Screen rectangle of the captured text in Cocoa coordinates; nil when unknown.
    var bounds: CGRect? = nil
    var appName = ""
    var bundleID = ""
}
@MainActor enum Capture {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    /// The system-wide focused element fails for some apps (iTerm2 returns cannotComplete); the app-level query still works there.
    static func focused(in app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> AXUIElement? {
        if let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        guard let app, let value = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static let terminals = ["com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.github.wez.wezterm", "io.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
    static func snapshot(selectionOnly: Bool = false) throws -> TextSnapshot {
        guard AXIsProcessTrusted() else { throw CaptureFailure.notTrusted }
        guard let app = NSWorkspace.shared.frontmostApplication, let element = focused(in: app) else { throw CaptureFailure.noText }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        guard subrole != kAXSecureTextFieldSubrole else { throw CaptureFailure.secureField }
        let selected = attribute(element, kAXSelectedTextAttribute) as? String ?? ""
        let value = attribute(element, kAXValueAttribute) as? String
        let terminal = terminals.contains(app.bundleIdentifier ?? "")
        // A terminal's "value" is the whole screen, never the thing being typed: only an explicit selection makes sense there.
        if selected.isEmpty && (selectionOnly || terminal) { throw CaptureFailure.noSelection }
        let textRole = [kAXTextFieldRole, kAXTextAreaRole].contains(role)
        var snapshot = TextSnapshot(text: "", element: element, fullValue: value, pid: app.processIdentifier, editable: false)
        snapshot.appName = app.localizedName ?? ""
        snapshot.bundleID = app.bundleIdentifier ?? ""
        if !selected.isEmpty {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            snapshot = TextSnapshot(text: selected, element: element, fullValue: value, pid: app.processIdentifier, editable: false,
                                    kind: .selection, selectionReplaceable: !terminal && textRole && settable.boolValue,
                                    bounds: selectionBounds(element) ?? frame(element), appName: snapshot.appName, bundleID: snapshot.bundleID)
        } else if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            // Whole-field replacement only; the field's current value must be exactly what was captured.
            snapshot = TextSnapshot(text: value, element: element, fullValue: value, pid: app.processIdentifier, editable: !terminal && textRole && settable.boolValue,
                                    kind: .field, bounds: frame(element), appName: snapshot.appName, bundleID: snapshot.bundleID)
        } else if let windowValue = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute), CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            var budget = 1500
            let text = collect(windowValue as! AXUIElement, depth: 0, budget: &budget).joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureFailure.noText }
            snapshot = TextSnapshot(text: text, element: element, fullValue: nil, pid: app.processIdentifier, editable: false,
                                    kind: .window, bounds: frame(element), appName: snapshot.appName, bundleID: snapshot.bundleID)
        } else {
            throw CaptureFailure.noText
        }
        return snapshot
    }
    static func collect(_ element: AXUIElement, depth: Int, budget: inout Int) -> [String] {
        guard depth < 16, budget > 0 else { return [] }; budget -= 1
        if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return [] }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole].contains(role), let text = attribute(element, kAXValueAttribute) as? String, !text.isEmpty { return [text] }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.flatMap { collect($0, depth: depth + 1, budget: &budget) }
    }
    /// Screen rectangle of the selected range, so the panel can sit right under it.
    static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        guard let range = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return flipped(rect)
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0 else { return nil }
        return flipped(CGRect(origin: origin, size: extent))
    }
    struct TerminalScreen { let lines: [String]; let cursorLine: Int; let cursorColumn: Int }
    /// A terminal exposes its screen as one text area: rows split by newline, the cursor as the insertion point.
    static func terminalScreen(_ element: AXUIElement) -> TerminalScreen? {
        guard let value = attribute(element, kAXValueAttribute) as? String,
              let line = attribute(element, kAXInsertionPointLineNumberAttribute) as? Int, line >= 0 else { return nil }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var column = 0
        if let selection = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID(),
           let lineRange = rangeForLine(element, line) {
            var range = CFRange(); AXValueGetValue(selection as! AXValue, .cfRange, &range)
            column = max(0, range.location - lineRange.location)
        }
        return TerminalScreen(lines: lines, cursorLine: line, cursorColumn: column)
    }
    static func rangeForLine(_ element: AXUIElement, _ line: Int) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString, line as CFNumber, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(); AXValueGetValue(value as! AXValue, .cfRange, &range)
        return range
    }
    /// Screen rectangle of one terminal row, so the panel can sit under the input box or the latest output.
    static func lineBounds(_ element: AXUIElement, line: Int) -> CGRect? {
        guard let range = rangeForLine(element, line), let rangeValue = AXValueCreate(.cfRange, [range]) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 else { return nil }
        return flipped(rect)
    }
    static let chromiumBrowsers = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "company.thebrowser.dia", "com.operasoftware.Opera"]
    /// Chromium browsers and Electron apps; other apps are left alone because AXEnhancedUserInterface changes their behaviour.
    static func isWebShell(_ app: NSRunningApplication) -> Bool {
        if chromiumBrowsers.contains(app.bundleIdentifier ?? "") { return true }
        guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks").path,
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks) else { return false }
        return names.contains { $0.hasPrefix("Electron Framework") || $0.hasPrefix("Chromium Embedded Framework") }
    }
    /// Chromium and Electron apps publish their content tree only when asked.
    static func enableWebAccessibility(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
    /// Accessibility reports top-left-origin coordinates; AppKit wants bottom-left.
    static func flipped(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
    /// Read only when the user explicitly asks; nothing watches the pasteboard in the background.
    static func clipboardText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
    static func grant() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    enum Privacy: String { case accessibility = "Privacy_Accessibility", screenRecording = "Privacy_ScreenCapture" }
    static func openSettings(_ pane: Privacy) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
// Process arguments are passed directly; captured text is never executed as shell code.
enum Command {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> Data {
        try await Task.detached {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); watchdog.cancel()
            guard process.terminationStatus == 0 else { throw AppError.message("操作取消、逾時或執行失敗。請檢查路徑與權限。") }
            return data
        }.value
    }
}
enum ExternalCapture {
    static func herdr(path: String, pane: String) async throws -> String {
        guard path.hasPrefix("/"), !pane.isEmpty, !pane.hasPrefix("-") else { throw AppError.message("請設定 Herdr 執行檔與固定 pane ID。") }
        let data = try await Command.run(path, ["pane", "read", pane, "--source", "recent", "--lines", "200"])
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw AppError.message("Herdr 沒有回傳內容。") }
        return text
    }
    static func ocr() async throws -> String {
        // Without Screen Recording, screencapture silently returns only the desktop, so OCR finds nothing.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw AppError.message("框選 OCR 需要「螢幕錄製」權限。請在系統設定開啟 LinguaFloat，然後結束並重新開啟本 App。")
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: path) }
        _ = try await Command.run("/usr/sbin/screencapture", ["-i", "-x", path.path], timeout: 120)
        return try await Task.detached {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(url: path).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.isEmpty else { throw AppError.message("沒有辨識到文字。") }
            return text
        }.value
    }
}
