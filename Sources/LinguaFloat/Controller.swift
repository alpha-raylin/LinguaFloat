import ApplicationServices
import AppKit
import SwiftUI
import LinguaCore

enum Mode: String, CaseIterable { case translate, translateSecond, correct }
enum StatusTone { case idle, working, success, warning, error }
enum ProbeState: Equatable { case idle, running, ok(found: Bool, count: Int, translationFound: Bool?), failed(String) }

/// What the panel is showing text from. Drives the source bar and which actions make sense.
struct SourceInfo: Equatable {
    let kind: CaptureKind
    let appName: String
    let bundleID: String
    let count: Int
    var icon: NSImage? {
        guard !bundleID.isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
    }
    var title: String { appName.isEmpty ? kind.label : "\(appName) · \(kind.label)" }
}

/// Borderless, non-activating, but able to take key events so Esc / ↩ work without clicking first.
final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor final class Controller: ObservableObject {
    static let idleHint = "⌥⇧L 翻譯目前文字 · ⌥⇧C 校正選取文字"
    static let quickWidth: CGFloat = 400
    let settings = Settings()
    @Published var input = ""
    @Published var output = ""
    @Published var explanation = ""
    @Published var status = Controller.idleHint
    @Published var tone = StatusTone.idle
    @Published var mode = Mode.translate
    @Published var busy = false
    @Published var canApply = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var canRecordScreen = CGPreflightScreenCaptureAccess()
    /// Pinned panels stay put and keep a resizable workbench layout; unpinned ones hide on Esc or a click elsewhere.
    @Published var pinned = false
    @Published var sourceExpanded = false
    @Published var source: SourceInfo?
    /// Whole-window reads can be large and slow on a local model, so they wait for ↩.
    @Published var pendingWindowCapture = false
    @Published var captureFailure: CaptureFailure?
    /// An automatic correction finished while the user kept typing; the menu bar icon shows a badge until they look.
    @Published var hasSuggestion = false
    @Published var probe = ProbeState.idle
    /// Follow mode: watch the front window for settled selections, paused typing and new terminal output.
    @Published var following = false {
        didSet {
            guard following != oldValue else { return }
            settings.follow = following
            if following { follow.start() } else { follow.stop(); if automatic { invalidate(nil); automatic = false } }
        }
    }
    let follow = FollowEngine()
    /// Bumped after the panel becomes key so the editor can claim focus; a request made before that is dropped by AppKit.
    @Published private(set) var editorFocusToken = 0
    @Published private(set) var partial = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastCorrect: Bool?
    private var target: TextSnapshot?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var timer: Timer?
    private var automatic = false
    var panel: FloatingPanel!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var anchor: CGRect?
    private var edge = Placement.Edge.free
    private var workbenchFrame: NSRect?
    /// The app the user was in when the panel came up; focus goes back there when the panel hides.
    private var previousApp: NSRunningApplication?
    private var observers: [Any] = []
    private let makeClient: (Settings, String, Bool) -> any ModelRunning

    /// `makeClient` receives the settings, the target language, and whether to use the translation-only model in plain mode.
    init(makeClient: @escaping (Settings, String, Bool) -> any ModelRunning = { settings, language, plain in
        ModelClient(endpoint: settings.endpoint, model: plain ? settings.translationModel : settings.model, key: settings.key, language: language,
                    timeout: settings.requestTimeout, jsonMode: settings.jsonMode, plain: plain)
    }) {
        self.makeClient = makeClient
    }
    /// Translate mode goes to the dedicated translation model when one is configured; correction always needs the general model.
    func usesTranslationModel(correct: Bool) -> Bool { !correct && !settings.translationModel.trimmingCharacters(in: .whitespaces).isEmpty }
    var targetLanguage: String { mode == .translateSecond ? settings.secondLanguage : settings.language }
    var canSendToHerdr: Bool { Capture.terminals.contains(source?.bundleID ?? "") && FileManager.default.isExecutableFile(atPath: settings.herdr) }

    var showsError: Bool { !busy && output.isEmpty && tone == .error && captureFailure == nil && !pendingWindowCapture }
    var needsSetup: Bool { settings.model.isEmpty || !trusted }

    // MARK: Panel lifecycle

    func setup() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.quickWidth, height: 220), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in self?.escape() }
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.cornerCurve = .continuous; effect.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: MainView(controller: self))
        // The window's size is decided here (placement + fit), never by SwiftUI's intrinsic size pushing through autolayout.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor), hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        // Clicking into another app deactivates us; an unpinned panel takes that as "done" and gets out of the way.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lostFocus() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        follow.handler = { [weak self] event in self?.handle(event) }
        follow.excludedBundleIDs = { [weak self] in
            Set((self?.settings.followExcluded ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if settings.follow { following = true }
    }

    // MARK: Follow mode

    private func handle(_ event: FollowEngine.Event) {
        // Never cancel something the user asked for by hand; follow events only replace other follow results.
        guard !(busy && !automatic) else { return }
        let visible = panel?.isVisible == true
        switch event {
        case .selection(let snapshot):
            guard snapshot.text.count >= 2, snapshot.text != input || output.isEmpty else { return }
            adopt(snapshot)
            mode = Script.isCJK(snapshot.text) ? .translateSecond : .translate
            process(correct: false)
        case .typing(let snapshot):
            guard snapshot.text.count >= 4 else { return }
            adopt(snapshot)
            mode = Script.isCJK(snapshot.text) ? .translateSecond : .correct
            process(correct: mode == .correct, automatic: !visible)
        case .content(let text, let snapshot):
            guard text.count >= 4, !Script.isCJK(text) else { return }
            adopt(snapshot); target = nil
            mode = .translate
            process(correct: false, automatic: !visible)
        }
    }
    /// Drops the finished result into the focused Herdr pane as literal text (no Enter), via the CLI.
    func sendToHerdr() {
        guard !output.isEmpty else { return }
        let path = settings.herdr; let text = output
        report("正在送到 Herdr…", .working)
        Task {
            do {
                let data = try await Command.run(path, ["pane", "list"])
                struct List: Decodable { struct Result: Decodable { struct Pane: Decodable { let pane_id: String; let focused: Bool }; let panes: [Pane] }; let result: Result }
                guard let pane = try JSONDecoder().decode(List.self, from: data).result.panes.first(where: { $0.focused })?.pane_id else {
                    report("找不到目前聚焦的 Herdr 窗格。", .warning); return
                }
                _ = try await Command.run(path, ["pane", "send-text", pane, text])
                report("已送到 Herdr 目前的窗格，未按 Enter。", .success); hide()
            } catch { report("送到 Herdr 失敗：\(error.localizedDescription)", .error) }
        }
    }
    /// Tests drive observation by hand; the periodic poll would reset it from under them.
    func stopPolling() { timer?.invalidate(); timer = nil }
    /// Menu bar / Dock reopen: the persistent workbench with the editor open.
    func show() {
        pinned = true
        if source == nil { source = SourceInfo(kind: .draft, appName: "", bundleID: "", count: input.count) }
        sourceExpanded = true
        hasSuggestion = false
        present(reposition: panel?.isVisible == false)
    }
    private func present(reposition: Bool) {
        guard let panel else { return }
        if reposition {
            if pinned, let workbenchFrame {
                panel.setFrame(workbenchFrame, display: true)
            } else {
                let pointer = NSEvent.mouseLocation
                let screen = screenFor(anchor ?? CGRect(origin: pointer, size: .zero)).visibleFrame
                if pinned {
                    // The workbench is a place to work, not a tooltip: centre it rather than hanging it off the pointer.
                    let size = CGSize(width: 480, height: min(600, screen.height - 16))
                    panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
                    edge = .free
                } else {
                    let size = CGSize(width: Self.quickWidth, height: min(max(panel.frame.height, 200), 400))
                    let placement = Placement.place(size: size, anchor: anchor, pointer: pointer, screen: screen)
                    edge = placement.edge
                    panel.setFrame(placement.frame, display: true)
                }
            }
        }
        panel.styleMask = pinned ? [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable] : [.borderless, .nonactivatingPanel, .fullSizeContentView]
        // Take keyboard focus like Spotlight does: activate (no Dock icon, no menu bar for an accessory app) and return it on hide.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        NSApp.unhide(nil)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [self] in
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            // No focus ring on a toolbar button: the window holds focus unless the editor is open and wants it.
            if sourceExpanded { editorFocusToken += 1 } else { panel.makeFirstResponder(nil) }
        }
    }
    func hide() {
        guard let panel, panel.isVisible else { return }
        if pinned { workbenchFrame = panel.frame }
        panel.orderOut(nil)
        if NSApp.isActive, settingsWindow?.isVisible != true, onboardingWindow?.isVisible != true { returnFocus() }
    }
    /// Hands activation back to the app the user came from. Cooperative activation (macOS 14+) is the polite path;
    /// if the system ignores it, hiding ourselves makes it activate the previous app for us.
    private func returnFocus() {
        let target = previousApp; previousApp = nil
        if let target, !target.isTerminated { target.activate(from: .current, options: []) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            guard NSApp.isActive, panel?.isVisible != true else { return }
            if let target, !target.isTerminated { target.activate(options: []) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                guard NSApp.isActive, panel?.isVisible != true else { return }
                NSApp.hide(nil)
            }
        }
    }
    func togglePin() {
        pinned.toggle()
        if pinned { workbenchFrame = nil; sourceExpanded = sourceExpanded || source?.kind == .draft } else { workbenchFrame = panel?.frame }
        present(reposition: true)
    }
    /// Called by the SwiftUI layout when the quick panel's ideal height changes; keeps the edge nearest the text fixed.
    func fit(height: CGFloat) {
        guard let panel, !pinned, height > 0 else { return }
        let screen = screenFor(panel.frame).visibleFrame
        let frame = Placement.resize(panel.frame, to: ceil(height), edge: edge, screen: screen)
        if abs(frame.height - panel.frame.height) >= 1 || abs(frame.minY - panel.frame.minY) >= 1 { panel.setFrame(frame, display: true) }
    }
    func escape() {
        if busy { invalidate() } else if pendingWindowCapture { pendingWindowCapture = false; hide() } else { hide() }
    }
    private func lostFocus() {
        guard !pinned, let panel, panel.isVisible, !NSApp.isActive else { return }
        panel.orderOut(nil)
    }
    private func screenFor(_ rect: CGRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.intersects(rect) || $0.frame.contains(rect.origin) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Windows

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            settingsWindow?.isReleasedWhenClosed = false; settingsWindow?.title = "LinguaFloat 設定"
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(settings: settings, controller: self)); settingsWindow?.center()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func openOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            onboardingWindow?.isReleasedWhenClosed = false; onboardingWindow?.title = "開始使用 LinguaFloat"
            onboardingWindow?.contentView = NSHostingView(rootView: OnboardingView(settings: settings, controller: self)); onboardingWindow?.center()
        }
        NSApp.activate(ignoringOtherApps: true); onboardingWindow?.makeKeyAndOrderFront(nil)
    }
    func closeOnboarding() { onboardingWindow?.orderOut(nil); settings.onboarded = true }
    func testConnection() {
        probe = .running
        let client = ModelClient(endpoint: settings.endpoint, model: settings.model, key: settings.key, language: settings.language)
        let model = settings.model; let translation = settings.translationModel.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let result = try await client.probe()
                probe = .ok(found: result.contains(model), count: result.models.count, translationFound: translation.isEmpty ? nil : result.contains(translation))
            } catch { probe = .failed(error.localizedDescription) }
        }
    }

    // MARK: Capture

    private func report(_ text: String, _ tone: StatusTone) { status = text; self.tone = tone }
    func capture(correct: Bool) {
        mode = correct ? .correct : .translate
        hasSuggestion = false
        do {
            let snapshot = try Capture.snapshot(selectionOnly: correct)
            adopt(snapshot)
            if snapshot.kind == .window {
                invalidate(nil); pendingWindowCapture = true
                report("整個視窗的文字較多，確認後才會送出。", .idle)
                present(reposition: !pinned)
            } else {
                process(correct: correct)
            }
        } catch let failure as CaptureFailure {
            invalidate(nil); captureFailure = failure; source = nil; target = nil; anchor = nil
            report(failure.localizedDescription, .error)
            present(reposition: !pinned)
        } catch { invalidate(nil); report(error.localizedDescription, .error); present(reposition: !pinned) }
    }
    private func adopt(_ snapshot: TextSnapshot) {
        input = snapshot.text; target = snapshot
        source = SourceInfo(kind: snapshot.kind, appName: snapshot.appName, bundleID: snapshot.bundleID, count: snapshot.text.count)
        anchor = snapshot.bounds; captureFailure = nil; pendingWindowCapture = false; sourceExpanded = false
    }
    func confirmWindowCapture() { guard pendingWindowCapture else { return }; pendingWindowCapture = false; process(correct: mode == .correct) }
    /// Fallback for apps without accessibility text (iTerm2 copies on select, for example). Reads the pasteboard only on this explicit request.
    func useClipboard() {
        guard let text = Capture.clipboardText() else { captureFailure = nil; report("剪貼簿沒有文字。", .warning); present(reposition: !pinned); return }
        input = text; target = nil; anchor = nil
        source = SourceInfo(kind: .clipboard, appName: "", bundleID: "", count: text.count)
        captureFailure = nil; pendingWindowCapture = false; sourceExpanded = false
        process(correct: mode == .correct)
    }
    func draft(correct: Bool) { target = nil; process(correct: correct) }
    func run() { draft(correct: mode == .correct) }
    func retry() { if let lastCorrect { process(correct: lastCorrect) } }
    /// Re-run the current text in the other mode (⌘1 / ⌘2) without losing the capture target.
    func rerun(_ mode: Mode) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.mode = mode; return }
        self.mode = mode; process(correct: mode == .correct)
    }
    func external(ocr: Bool) {
        invalidate(nil); automatic = false; target = nil; anchor = nil; captureFailure = nil; pendingWindowCapture = false; busy = true
        report(ocr ? "請框選螢幕上的文字區域…" : "正在讀取 Herdr 窗格…", .working)
        let id = generation; let path = settings.herdr; let pane = settings.pane
        if ocr { panel?.orderOut(nil) } else { present(reposition: !pinned) }
        task = Task {
            do {
                let text = try await (ocr ? ExternalCapture.ocr() : ExternalCapture.herdr(path: path, pane: pane))
                guard id == generation else { return }
                input = text; sourceExpanded = false
                source = SourceInfo(kind: ocr ? .ocr : .herdr, appName: "", bundleID: "", count: text.count)
                process(correct: false)
            } catch { guard id == generation else { return }; busy = false; report(error.localizedDescription, .error); present(reposition: !pinned) }
        }
    }
    /// Drops any in-flight work. A nil message resets the status line to the idle hint.
    func invalidate(_ message: String? = "已取消，未套用結果。") {
        task?.cancel(); task = nil; generation = UUID(); canApply = false; busy = false
        startedAt = nil; partial = ""
        output = ""; explanation = ""
        if let message { report(message, .warning) } else { report(Self.idleHint, .idle) }
    }
    func draftChanged() {
        let stale = busy || !output.isEmpty
        invalidate(stale ? "原文已修改，舊結果已清除。" : nil); automatic = false; target = nil; canApply = false
        source = SourceInfo(kind: .draft, appName: "", bundleID: "", count: input.count)
    }

    // MARK: Model

    func process(correct: Bool, automatic: Bool = false) {
        invalidate(nil)
        self.automatic = automatic
        if correct { mode = .correct } else if mode == .correct { mode = .translate }
        captureFailure = nil; pendingWindowCapture = false
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { report("請先取得或輸入文字。", .warning); return }
        let id = generation; let source = input
        let plain = usesTranslationModel(correct: correct)
        let client = makeClient(settings, targetLanguage, plain)
        let started = Date()
        lastCorrect = correct; startedAt = started
        busy = true; report(correct ? "校正中…" : "翻譯中…", .working)
        if !automatic { present(reposition: !pinned) }
        task = Task {
            do {
                let result = try await client.run(source, correct: correct) { text in
                    guard id == self.generation, !Task.isCancelled else { return }
                    self.partial = text
                }
                guard id == generation, !Task.isCancelled else { return }
                output = result.text; explanation = result.explanation; busy = false; startedAt = nil; partial = ""
                canApply = (target?.selectionReplaceable == true || target?.editable == true) && source != result.text
                let unchanged = source == result.text
                report(unchanged ? "未發現需要修改的內容" : "完成（\(Int(Date().timeIntervalSince(started))) 秒\(plain ? " · \(settings.translationModel)" : ""))", .success)
                if automatic {
                    hasSuggestion = !unchanged
                } else if settings.autoCopy, !unchanged {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
                    report("完成，已複製到剪貼簿。", .success)
                }
            } catch { guard id == generation else { return }; busy = false; startedAt = nil; partial = ""; report(error.localizedDescription, .error); if !automatic { present(reposition: false) } }
        }
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string); report("已複製；請在目標位置貼上。", .success) }
    func copyAndClose() { guard !output.isEmpty else { return }; copy(); hide() }
    /// Replaces the selected range or the whole field through accessibility, never by synthesising keystrokes.
    func apply() {
        guard let target, let element = target.element,
              let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { canApply = false; report("目標已失效，請重新擷取。", .warning); return }
        var actualPID: pid_t = 0; AXUIElementGetPid(element, &actualPID)
        if target.kind == .selection, target.selectionReplaceable {
            let current = Capture.attribute(element, kAXSelectedTextAttribute) as? String ?? ""
            guard TextPolicy.canReplace(original: target.text, current: current, pid: target.pid, currentPID: actualPID) else { canApply = false; report("選取範圍已改變，已取消取代。", .warning); return }
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, output as CFString) == .success else { report("此 App 不允許取代選取文字，請使用複製。", .warning); return }
            canApply = false; report("已取代選取文字，未送出。", .success); hide(); return
        }
        guard target.editable, let current = Capture.attribute(element, kAXValueAttribute) as? String else { canApply = false; report("此 App 無法替換，請使用複製。", .warning); return }
        guard TextPolicy.canReplace(original: target.text, current: current, pid: target.pid, currentPID: actualPID) else { canApply = false; report("原文已改變，已取消套用。", .warning); return }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, output as CFString) == .success else { report("此 App 無法替換，請使用複製。", .warning); return }
        canApply = false; report("已套用，未送出。", .success); hide()
    }

    // MARK: Permission polling

    private func poll() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted { trusted = nowTrusted }
        let nowRecord = CGPreflightScreenCaptureAccess()
        if nowRecord != canRecordScreen { canRecordScreen = nowRecord }
    }
}
