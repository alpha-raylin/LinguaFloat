import AppKit
import SwiftUI

// Design tokens. Fill carries white labels (≥4.5:1 in both modes); accent is for tinted text/icons.
enum Theme {
    static let fill = Color(red: 0.059, green: 0.463, blue: 0.431)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.369, green: 0.918, blue: 0.831, alpha: 1)
            : NSColor(srgbRed: 0.059, green: 0.463, blue: 0.431, alpha: 1)
    })
    static let radius: CGFloat = 10
    static let inputLimit = 24_000
    /// Tallest the streamed result may grow in the quick panel before it scrolls.
    static let quickResultMax: CGFloat = 360
}

extension StatusTone {
    var symbol: String {
        switch self {
        case .idle: "info.circle"
        case .working: "hourglass"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .idle: .secondary
        case .working: Theme.accent
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

extension CaptureKind {
    var symbol: String {
        switch self {
        case .selection: "text.cursor"
        case .field: "rectangle.and.pencil.and.ellipsis"
        case .window: "macwindow"
        case .clipboard: "doc.on.clipboard"
        case .ocr: "text.viewfinder"
        case .herdr: "terminal"
        case .draft: "pencil.line"
        case .stream: "text.append"
        }
    }
}

private struct Surface: ViewModifier {
    var background = Color(nsColor: .controlBackgroundColor)
    func body(content: Content) -> some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Main panel

/// Two layouts over the same state: the quick panel sizes itself to its content and gets out of the way;
/// the pinned workbench fills a resizable window and keeps the editor open.
struct MainView: View {
    @ObservedObject var controller: Controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if controller.pinned {
                stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                stack
                    .frame(width: Controller.quickWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.fit(height: $0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .tint(Theme.accent)
        .onExitCommand { controller.escape() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controller.busy)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controller.sourceExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controller.output.isEmpty)
    }

    private var stack: some View {
        VStack(spacing: 0) {
            SourceBar(controller: controller, settings: controller.settings)
            if controller.settings.model.isEmpty { SetupNotice(controller: controller) }
            Divider()
            ResultBody(controller: controller, settings: controller.settings)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            if controller.pinned { Spacer(minLength: 0) }
            if showsSource {
                Divider()
                SourceSection(controller: controller)
            }
            Divider()
            ActionBar(controller: controller)
        }
    }
    private var showsSource: Bool {
        controller.source != nil || controller.sourceExpanded || controller.pinned
    }
}

private struct SourceBar: View {
    @ObservedObject var controller: Controller
    @ObservedObject var settings: Settings

    private var modeTitle: String {
        switch controller.mode {
        case .correct: "校正"
        case .translateSecond: "→ \(settings.secondLanguage)"
        case .translate: "翻譯"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let source = controller.source {
                if let icon = source.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                } else {
                    Image(systemName: source.kind.symbol).foregroundStyle(Theme.accent).frame(width: 16).accessibilityHidden(true)
                }
                Text(source.title).font(.callout.weight(.medium)).lineLimit(1)
                if source.kind != .draft {
                    Text("\(source.count.formatted()) 字").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Image(systemName: "character.bubble.fill").foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text("LinguaFloat").font(.callout.weight(.medium))
            }
            Spacer(minLength: 4)
            if controller.following {
                Image(systemName: "eye").foregroundStyle(Theme.accent).font(.caption)
                    .help("跟隨模式開啟中：選取、停止輸入或終端機出現新內容時自動處理")
                    .accessibilityLabel("跟隨模式開啟")
            }
            Menu {
                Button { controller.rerun(.translate) } label: { Label("翻譯為\(settings.language)", systemImage: "character.bubble") }
                    .keyboardShortcut("1", modifiers: .command)
                Button { controller.rerun(.correct) } label: { Label("同語言校正", systemImage: "checkmark.bubble") }
                    .keyboardShortcut("2", modifiers: .command)
                Button { controller.rerun(.translateSecond) } label: { Label("翻譯為\(settings.secondLanguage)", systemImage: "globe") }
                    .keyboardShortcut("3", modifiers: .command)
            } label: {
                Label(modeTitle, systemImage: controller.mode == .correct ? "checkmark.bubble" : (controller.mode == .translateSecond ? "globe" : "character.bubble"))
                    .font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.accessoryBar)
            .fixedSize()
            .disabled(controller.busy)
            .help("切換模式並重新處理（⌘1 翻譯 · ⌘2 校正）")
            .accessibilityLabel("處理模式")
            Button { controller.togglePin() } label: {
                Image(systemName: controller.pinned ? "pin.fill" : "pin").frame(width: 20, height: 20)
            }
            .buttonStyle(.accessoryBar)
            .help(controller.pinned ? "取消釘住：面板會在按 Esc 或點其他地方時關閉" : "釘住：面板留在畫面上，可拖曳與調整大小")
            .accessibilityLabel(controller.pinned ? "取消釘住" : "釘住")
            Menu {
                Button { controller.external(ocr: true) } label: { Label("框選 OCR…", systemImage: "text.viewfinder") }
                    .help(controller.canRecordScreen ? "" : "需要螢幕錄製權限")
                Button { controller.external(ocr: false) } label: { Label("讀取 Herdr 窗格", systemImage: "terminal") }
                Button { controller.useClipboard() } label: { Label("使用剪貼簿內容", systemImage: "doc.on.clipboard") }
                Divider()
                Button { controller.sourceExpanded.toggle() } label: { Label(controller.sourceExpanded ? "收合原文" : "展開原文", systemImage: "text.alignleft") }
                    .keyboardShortcut("e", modifiers: .command)
                Toggle(isOn: $controller.following) { Label("跟隨前景視窗", systemImage: "eye") }
                Divider()
                Button { controller.openSettings() } label: { Label("設定…", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .buttonStyle(.accessoryBar)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .focusEffectDisabled()
    }
}

private struct SetupNotice: View {
    @ObservedObject var controller: Controller
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text("尚未設定模型，無法翻譯。").font(.caption)
            Spacer()
            Button("開始設定") { controller.openOnboarding() }.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: Result

private struct ResultBody: View {
    @ObservedObject var controller: Controller
    @ObservedObject var settings: Settings
    @State private var contentHeight: CGFloat = 0
    /// Learning notes are the point for this user, so they start open.
    @State private var notesExpanded = true

    var body: some View {
        if controller.pendingWindowCapture {
            WindowConfirm(controller: controller)
        } else if let failure = controller.captureFailure {
            FailureCard(controller: controller, failure: failure)
        } else if controller.busy, controller.partial.isEmpty {
            Waiting(controller: controller)
        } else if controller.busy || !controller.output.isEmpty {
            resultText
        } else if controller.showsError {
            Notice(symbol: "xmark.octagon.fill", tint: .red, title: "未完成，未套用任何結果", detail: controller.status) {
                if controller.lastCorrect != nil, !controller.input.isEmpty {
                    Button { controller.retry() } label: { Label("重試", systemImage: "arrow.clockwise") }
                }
                if settings.model.isEmpty { Button("開啟設定") { controller.openSettings() } }
            }
        } else {
            Notice(symbol: "text.bubble", tint: .secondary, title: controller.sourceExpanded ? "輸入文字後按 ⌘↩" : "結果會顯示在這裡",
                   detail: "在任何 App 選取文字後按 ⌥⇧L 翻譯，或 ⌥⇧C 校正") { EmptyView() }
        }
    }

    private var resultText: some View {
        let text = controller.busy ? controller.partial : controller.output
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                (Text(text) + Text(controller.busy ? " ▍" : "").foregroundStyle(Theme.accent))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !controller.busy, !controller.explanation.isEmpty {
                    DisclosureGroup(isExpanded: $notesExpanded) {
                        Text(controller.explanation)
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Label(controller.mode == .correct ? "文法筆記" : "學習筆記", systemImage: "graduationcap").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.trailing, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: controller.pinned ? nil : min(max(contentHeight, 24), Theme.quickResultMax))
        .frame(maxHeight: controller.pinned ? .infinity : nil)
        .accessibilityLabel(controller.mode == .correct ? "建議" : "譯文")
    }
}

private struct Waiting: View {
    @ObservedObject var controller: Controller
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = controller.startedAt.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.status).font(.callout)
                    if seconds >= 5 {
                        Text("模型載入中，第一次通常較慢。").font(.caption).foregroundStyle(.secondary)
                    } else if seconds >= 2 {
                        Text("\(seconds) 秒").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct WindowConfirm: View {
    @ObservedObject var controller: Controller
    var body: some View {
        Notice(symbol: "macwindow", tint: Theme.accent,
               title: "沒有選取或焦點文字，要讀取\(controller.source?.appName ?? "這個 App")的整個視窗嗎？",
               detail: "共 \(controller.source?.count.formatted() ?? "0") 字。整個視窗通常包含選單與雜訊，本機模型處理也較慢。可先展開原文刪減。") {
            Button { controller.sourceExpanded = true } label: { Label("先看原文", systemImage: "text.alignleft") }
            Button { controller.useClipboard() } label: { Label("改用剪貼簿", systemImage: "doc.on.clipboard") }
        }
    }
}

private struct FailureCard: View {
    @ObservedObject var controller: Controller
    let failure: CaptureFailure

    var body: some View {
        switch failure {
        case .notTrusted:
            Notice(symbol: "lock.shield", tint: .orange, title: "需要「輔助使用」權限",
                   detail: "才能讀取其他 App 的文字。若系統設定裡已開啟仍看到這則訊息，那是舊版本的授權：移除後重新加入。") {
                Button("授予…") { Capture.grant() }.buttonStyle(.borderedProminent).tint(Theme.fill)
                Button("開啟系統設定") { Capture.openSettings(.accessibility) }
                Button { controller.useClipboard() } label: { Label("改用剪貼簿", systemImage: "doc.on.clipboard") }
            }
        case .noSelection:
            Notice(symbol: "text.cursor", tint: .orange, title: "沒有選取的文字",
                   detail: "先選取一段文字再按 ⌥⇧C。終端機或不支援選取的 App，可以先 ⌘C 再用剪貼簿。") {
                Button { controller.useClipboard() } label: { Label("使用剪貼簿", systemImage: "doc.on.clipboard") }.buttonStyle(.borderedProminent).tint(Theme.fill)
                Button { controller.external(ocr: true) } label: { Label("框選 OCR", systemImage: "text.viewfinder") }
            }
        case .noText:
            Notice(symbol: "questionmark.app", tint: .orange, title: "這個 App 沒有提供可讀取的文字",
                   detail: "先 ⌘C 複製再使用剪貼簿最快；畫面上的文字也可以框選 OCR。") {
                Button { controller.useClipboard() } label: { Label("使用剪貼簿", systemImage: "doc.on.clipboard") }.buttonStyle(.borderedProminent).tint(Theme.fill)
                Button { controller.external(ocr: true) } label: { Label("框選 OCR", systemImage: "text.viewfinder") }
                Button { controller.captureFailure = nil; controller.sourceExpanded = true } label: { Label("手動輸入", systemImage: "pencil.line") }
            }
        case .secureField:
            Notice(symbol: "eye.slash", tint: .secondary, title: "不讀取密碼欄位", detail: "請把游標移到其他欄位再試。") { EmptyView() }
        }
    }
}

private struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: 8) { actions }.controlSize(.small).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Source

private struct SourceSection: View {
    @ObservedObject var controller: Controller
    @FocusState private var editorFocused: Bool

    private var count: Int { controller.input.count }
    private var overLimit: Bool { count > Theme.inputLimit }
    private var preview: String {
        controller.input.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { controller.sourceExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(controller.sourceExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text("原文").font(.subheadline.weight(.semibold))
                    if !controller.sourceExpanded {
                        Text(preview.isEmpty ? "尚未輸入" : preview).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    if controller.sourceExpanded {
                        if overLimit {
                            Text("超過 24,000 字元上限").font(.caption).foregroundStyle(.red)
                        } else {
                            Text("\(count.formatted()) / 24,000").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.sourceExpanded ? "收合原文（⌘E）" : "展開並編輯原文（⌘E）")
            .accessibilityLabel(controller.sourceExpanded ? "收合原文" : "展開原文")
            .accessibilityAddTraits(.isHeader)
            if controller.sourceExpanded {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(get: { controller.input }, set: { controller.input = $0; controller.draftChanged() }))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .accessibilityLabel("原文")
                        .focused($editorFocused)
                        .onAppear { editorFocused = true }
                        .onChange(of: controller.editorFocusToken) { editorFocused = true }
                    if controller.input.isEmpty {
                        Text("輸入或貼上文字，⌘↩ 開始")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: controller.pinned ? 120 : 140, maxHeight: controller.pinned ? .infinity : 140)
                .modifier(Surface(background: Color(nsColor: .textBackgroundColor)))
                HStack {
                    Button("清除") { controller.input = ""; controller.draftChanged() }
                        .buttonStyle(.borderless)
                        .disabled(controller.input.isEmpty || controller.busy)
                    Spacer()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: Actions

private struct ActionBar: View {
    @ObservedObject var controller: Controller
    @State private var copied = false

    private var blocked: Bool {
        controller.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.input.count > Theme.inputLimit
    }
    private var applyTitle: String { controller.source?.kind == .selection ? "取代選取文字" : "套用至原欄位" }

    var body: some View {
        HStack(spacing: 8) {
            if controller.busy {
                Button("取消", role: .cancel) { controller.invalidate() }
                    .keyboardShortcut(.cancelAction)
                    .help("取消請求（Esc），不會套用任何結果")
            } else if controller.pendingWindowCapture {
                Button { controller.confirmWindowCapture() } label: {
                    Label(controller.mode == .correct ? "讀取並校正" : "讀取並翻譯", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent).tint(Theme.fill)
                .keyboardShortcut(.defaultAction)
                Button("取消") { controller.escape() }
            } else if !controller.output.isEmpty {
                Button {
                    copied = true
                    Task { try? await Task.sleep(for: .milliseconds(350)); controller.copyAndClose(); copied = false }
                } label: {
                    Label(copied ? "已複製" : "複製並關閉", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent).tint(Theme.fill)
                .keyboardShortcut(controller.sourceExpanded ? nil : .defaultAction)
                .help("複製結果並關閉面板（↩）")
                if controller.canApply {
                    Button { controller.apply() } label: { Label(applyTitle, systemImage: "arrow.uturn.backward") }
                        .help("透過輔助使用直接改寫原 App 的文字；不會送出或按 Enter")
                }
                if controller.canSendToHerdr {
                    Button { controller.sendToHerdr() } label: { Label("送到 Herdr", systemImage: "terminal") }
                        .help("用 herdr pane send-text 把結果放進目前聚焦的窗格，不按 Enter")
                }
                Button { controller.copy() } label: { Image(systemName: "doc.on.clipboard") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("只複製，不關閉（⌘⇧C）")
                    .accessibilityLabel("複製")
            } else {
                Button { controller.run() } label: {
                    Label(controller.mode == .correct ? "校正" : "翻譯", systemImage: controller.mode == .correct ? "checkmark.bubble" : "character.bubble")
                }
                .buttonStyle(.borderedProminent).tint(Theme.fill)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(blocked)
                .help("⌘↩")
                if controller.sourceExpanded == false, controller.source == nil {
                    Button("輸入文字") { controller.sourceExpanded = true }
                }
            }
            Spacer(minLength: 8)
            if controller.tone == .warning || controller.tone == .error || controller.tone == .success, !controller.busy {
                HStack(spacing: 4) {
                    Image(systemName: controller.tone.symbol).foregroundStyle(controller.tone.color).accessibilityHidden(true)
                    Text(controller.status).lineLimit(1).truncationMode(.tail).help(controller.status)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if !controller.pinned {
                Text("Esc 關閉").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("三個步驟就能開始").font(.title2.weight(.semibold))
                Text("LinguaFloat 常駐在選單列，在任何 App 按快捷鍵就會在文字旁彈出翻譯。").foregroundStyle(.secondary)
            }
            Step(number: 1, title: "連接模型服務", done: probeOK) {
                TextField("API base URL", text: $settings.endpoint, prompt: Text("http://127.0.0.1:11434/v1")).textFieldStyle(.roundedBorder)
                TextField("模型名稱", text: $settings.model, prompt: Text("例如 qwen2.5:14b")).textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("測試連線") { controller.testConnection() }.disabled(controller.probe == .running || settings.model.isEmpty)
                    ProbeStatus(state: controller.probe, model: settings.model)
                }
                Text("預設是本機 Ollama；需要自行啟動服務並下載模型。雲端服務與 API Key 請到設定填寫。").font(.caption).foregroundStyle(.secondary)
            }
            Step(number: 2, title: "允許讀取其他 App 的文字", done: controller.trusted) {
                if controller.trusted {
                    Label("已授權輔助使用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    HStack {
                        Button("授予輔助使用…") { Capture.grant() }
                        Button("開啟系統設定") { Capture.openSettings(.accessibility) }
                    }
                    Text("若系統設定裡已開啟卻仍未授權，那是舊版本的授權：移除 LinguaFloat 後重新加入。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Step(number: 3, title: "試試看", done: false) {
                HStack(spacing: 14) {
                    Shortcut(keys: "⌥⇧L", text: "翻譯選取或焦點的文字")
                    Shortcut(keys: "⌥⇧C", text: "校正選取的文字")
                }
                Text("面板會出現在文字旁邊：↩ 複製並關閉、Esc 關閉、📌 釘住成工作台。想不按熱鍵，在設定開「跟隨前景視窗」。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("其他設定…") { controller.openSettings() }
                Spacer()
                Button("完成") { controller.closeOnboarding() }.buttonStyle(.borderedProminent).tint(Theme.fill).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 560)
        .tint(Theme.accent)
    }
    private var probeOK: Bool { if case .ok(let found, _, _) = controller.probe { return found } else { return false } }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Theme.fill).frame(width: 24, height: 24)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white) }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Shortcut: View {
    let keys: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(keys).font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text).font(.callout)
        }
    }
}

struct ProbeStatus: View {
    let state: ProbeState
    let model: String
    static func summary(found: Bool, count: Int, translationFound: Bool?, model: String) -> String {
        var text = found ? "已連線，找到 \(model)" : "已連線，但清單裡沒有 \(model)（共 \(count) 個模型）"
        if let translationFound { text += translationFound ? "；翻譯專用模型也在" : "；清單裡沒有翻譯專用模型" }
        return text
    }
    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .ok(let found, let count, let translationFound):
            let good = found && (translationFound ?? true)
            Label(Self.summary(found: found, count: count, translationFound: translationFound, model: model), systemImage: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? .green : .orange).font(.callout)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).lineLimit(2)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: Controller
    @State private var keySaved = false

    private var timeoutValid: Bool { settings.requestTimeout.isFinite && (10...1800).contains(settings.requestTimeout) }

    var body: some View {
        Form {
            Section {
                TextField("API base URL", text: $settings.endpoint, prompt: Text("http://127.0.0.1:11434/v1"))
                    .accessibilityLabel("API base URL")
                TextField("模型", text: $settings.model, prompt: Text("例如 qwen2.5:14b"))
                    .accessibilityLabel("模型")
                TextField("目標／說明語言", text: $settings.language, prompt: Text("繁體中文"))
                    .accessibilityLabel("目標／說明語言")
                TextField("翻譯專用模型", text: $settings.translationModel, prompt: Text("選填，例如 translategemma:12b"))
                    .accessibilityLabel("翻譯專用模型")
                LabeledContent("連線") {
                    HStack(spacing: 10) {
                        ProbeStatus(state: controller.probe, model: settings.model)
                        Button("測試連線") { controller.testConnection() }.disabled(controller.probe == .running || settings.model.isEmpty)
                    }
                }
            } header: {
                Text("模型服務")
            } footer: {
                Text("OpenAI 相容 chat/completions，需支援 SSE 串流。只在你觸發時傳送文字；HTTP 僅限本機，遠端請用 HTTPS。填了翻譯專用模型（HY-MT、TranslateGemma 等純翻譯模型）後，翻譯模式改走它、用簡單提示詞、沒有學習筆記；校正與筆記仍用上面的模型。")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    SecureField("API Key", text: $settings.key, prompt: Text("本機服務可留空"))
                        .accessibilityLabel("API Key")
                    Button(keySaved ? "已儲存" : "儲存到鑰匙圈") { settings.saveKey(); keySaved = true }
                        .disabled(keySaved)
                }
            } header: {
                Text("認證")
            } footer: {
                Text("API Key 只存於鑰匙圈。").foregroundStyle(.secondary)
            }

            Section {
                Toggle("跟隨前景視窗", isOn: $controller.following)
                TextField("第二語言", text: $settings.secondLanguage, prompt: Text("English"))
                    .accessibilityLabel("第二語言")
                TextField("排除的 App", text: $settings.followExcluded, prompt: Text("com.apple.keychainaccess, com.1password.1password"))
                    .accessibilityLabel("排除的 App")
            } header: {
                Text("跟隨模式")
            } footer: {
                Text("開啟後只看前景視窗：選取文字停 0.6 秒就翻譯；在可編輯欄位停止輸入 1.5 秒自動處理，中文翻成第二語言、其他語言校正；終端機出現新輸出且安靜 2 秒後翻譯新增的部分。後兩者預設只亮選單列圖示，面板開著時才直接更新。密碼欄位一律排除；以逗號分隔 bundle ID 排除其他 App。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("完成後自動複製結果", isOn: $settings.autoCopy)
            } header: {
                Text("行為")
            } footer: {
                Text("自動複製會覆蓋剪貼簿現有內容。").foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("請求期限") {
                    HStack(spacing: 4) {
                        TextField("請求期限", value: $settings.requestTimeout, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("秒").foregroundStyle(.secondary)
                    }
                }
                Picker("JSON schema", selection: $settings.jsonMode) {
                    Text("自動（僅本機 11434）").tag(JSONMode.automatic)
                    Text("啟用（服務需支援）").tag(JSONMode.enabled)
                    Text("關閉（僅提示詞）").tag(JSONMode.disabled)
                }
            } header: {
                Text("請求")
            } footer: {
                if timeoutValid {
                    Text("期限可設 10–1800 秒；輸出上限 4096 token。逾時或截斷皆不套用，長文請縮小範圍。")
                        .foregroundStyle(.secondary)
                } else {
                    Label("期限必須介於 10 與 1800 秒，否則請求會被拒絕。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("執行檔路徑", text: $settings.herdr, prompt: Text("/opt/homebrew/bin/herdr"))
                    .accessibilityLabel("執行檔路徑")
                TextField("固定 pane ID", text: $settings.pane, prompt: Text("必填"))
                    .accessibilityLabel("固定 pane ID")
            } header: {
                Text("Herdr")
            } footer: {
                Text("在終端機執行 herdr pane list 取得 ID。原型不猜測或跟隨焦點窗格。").foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("輔助使用") {
                    if controller.trusted {
                        Label("已授權", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("授予…") { Capture.grant() }
                            Button("開啟系統設定") { Capture.openSettings(.accessibility) }
                        }
                    }
                }
                LabeledContent("螢幕錄製（OCR）") {
                    if controller.canRecordScreen {
                        Label("已授權", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("授予…") { CGRequestScreenCaptureAccess() }
                            Button("開啟系統設定") { Capture.openSettings(.screenRecording) }
                        }
                    }
                }
            } header: {
                Text("權限")
            } footer: {
                Text("系統設定顯示已開啟、這裡卻未授權，代表那筆授權屬於舊版本：移除該項目後重新加入。螢幕錄製授權後需結束並重新開啟 App。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .tint(Theme.accent)
        .onChange(of: settings.key) { keySaved = false }
    }
}
