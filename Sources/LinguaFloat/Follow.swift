import AppKit
import ApplicationServices
import LinguaCore

/// Watches whatever window is in front and reports three things: a selection that settled, text being typed that paused,
/// and new output that appeared in a terminal. Accessibility notifications wake it up; a slow poll covers apps that send none.
@MainActor final class FollowEngine {
    enum Event {
        case selection(TextSnapshot)
        case typing(TextSnapshot)
        /// New rows in the focused terminal pane, above the input box.
        case content(String, TextSnapshot)
    }
    var handler: (Event) -> Void = { _ in }
    var excludedBundleIDs: () -> Set<String> = { [] }
    static let selectionDelay: TimeInterval = 0.6
    static let typingDelay: TimeInterval = 1.5
    static let contentDelay: TimeInterval = 2.0

    private(set) var running = false
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var timer: Timer?
    private var activation: Any?
    private var lastSelection = ""
    private var lastTyped: String?
    private var lastScreen: [String] = []
    private var pendingRows: [String] = []
    private var work: [String: DispatchWorkItem] = [:]
    private var lastPoll = Date.distantPast
    private var pollQueued = false

    func start() {
        guard !running else { return }
        running = true
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.switchedApp() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        switchedApp()
    }
    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        unsubscribe()
        work.values.forEach { $0.cancel() }; work = [:]
        lastSelection = ""; lastTyped = nil; lastScreen = []; pendingRows = []
    }

    // MARK: Subscriptions

    private func switchedApp() {
        guard running, let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.processIdentifier != observedPID else { return }
        unsubscribe()
        lastSelection = ""; lastTyped = nil; lastScreen = []; pendingRows = []
        work.values.forEach { $0.cancel() }; work = [:]
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        observedPID = app.processIdentifier
        if Capture.isWebShell(app) { Capture.enableWebAccessibility(app.processIdentifier) }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let engine = Unmanaged<FollowEngine>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in engine.poll() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        observer = created
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for name in [kAXFocusedUIElementChangedNotification, kAXSelectedTextChangedNotification, kAXValueChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        poll()
    }
    private func unsubscribe() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil; observedPID = 0
    }

    // MARK: Evaluation

    func poll() {
        // Streaming terminal output raises a value-changed notification per write; read the screen at most a few times a second.
        let elapsed = Date().timeIntervalSince(lastPoll)
        if elapsed < 0.3 {
            if !pollQueued {
                pollQueued = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.3 - elapsed)) { [weak self] in self?.pollQueued = false; self?.poll() }
            }
            return
        }
        lastPoll = Date()
        guard running, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !excludedBundleIDs().contains(app.bundleIdentifier ?? "") else { return }
        if app.processIdentifier != observedPID { switchedApp(); return }
        guard let element = Capture.focused(in: app) else { return }
        if Capture.attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return }
        let selected = Capture.attribute(element, kAXSelectedTextAttribute) as? String ?? ""
        if !selected.isEmpty {
            if selected != lastSelection {
                lastSelection = selected
                debounce("selection", Self.selectionDelay) { [weak self] in
                    guard let self, let snapshot = try? Capture.snapshot(), snapshot.kind == .selection, snapshot.text == self.lastSelection else { return }
                    self.handler(.selection(snapshot))
                }
            }
            return
        }
        lastSelection = ""
        if Capture.terminals.contains(app.bundleIdentifier ?? "") {
            terminalPoll(app: app, element: element)
        } else {
            fieldPoll(element: element)
        }
    }
    private func fieldPoll(element: AXUIElement) {
        let role = Capture.attribute(element, kAXRoleAttribute) as? String ?? ""
        guard [kAXTextFieldRole, kAXTextAreaRole].contains(role), let value = Capture.attribute(element, kAXValueAttribute) as? String else { lastTyped = nil; return }
        guard value != lastTyped else { return }
        let first = lastTyped == nil
        lastTyped = value
        // Landing on a field that already holds text is not typing; only changes after that are.
        guard !first else { return }
        debounce("typing", Self.typingDelay) { [weak self] in
            guard let self, let snapshot = try? Capture.snapshot(), snapshot.kind == .field, snapshot.text == self.lastTyped else { return }
            self.handler(.typing(snapshot))
        }
    }
    private func terminalPoll(app: NSRunningApplication, element: AXUIElement) {
        guard let screen = Capture.terminalScreen(element) else { return }
        let typed = TerminalText.inputText(lines: screen.lines, cursorLine: screen.cursorLine, cursorColumn: screen.cursorColumn) ?? ""
        if typed != (lastTyped ?? "") {
            let first = lastTyped == nil
            lastTyped = typed
            if !first, !typed.isEmpty {
                debounce("typing", Self.typingDelay) { [weak self] in
                    guard let self, typed == self.lastTyped else { return }
                    let bounds = Capture.lineBounds(element, line: screen.cursorLine)
                    let snapshot = TextSnapshot(text: typed, element: element, fullValue: nil, pid: app.processIdentifier, editable: false, kind: .field,
                                                selectionReplaceable: false, bounds: bounds, appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "")
                    self.handler(.typing(snapshot))
                }
            }
        }
        if screen.lines != lastScreen {
            let fresh = TerminalText.newLines(previous: lastScreen, current: screen.lines, cursorLine: screen.cursorLine, cursorColumn: screen.cursorColumn)
            let hadHistory = !lastScreen.isEmpty
            lastScreen = screen.lines
            guard hadHistory, let fresh else { pendingRows = []; work["content"]?.cancel(); return }
            // Only real rows restart the quiet timer; a spinner repainting every second must not postpone the event forever.
            guard !fresh.isEmpty else { return }
            pendingRows += fresh
            do {
                debounce("content", Self.contentDelay) { [weak self] in
                    guard let self else { return }
                    let text = self.pendingRows.joined(separator: "\n"); self.pendingRows = []
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let bounds = Capture.lineBounds(element, line: max(0, screen.cursorLine - 1))
                    let snapshot = TextSnapshot(text: text, element: element, fullValue: nil, pid: app.processIdentifier, editable: false, kind: .stream,
                                                selectionReplaceable: false, bounds: bounds, appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "")
                    self.handler(.content(text, snapshot))
                }
            }
        }
    }
    private func debounce(_ key: String, _ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        work[key]?.cancel()
        let item = DispatchWorkItem { Task { @MainActor in action() } }
        work[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
