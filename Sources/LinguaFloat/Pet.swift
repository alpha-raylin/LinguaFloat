import AppKit
import SwiftUI

/// A hosting view whose controls respond to the first click even though its window never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Small always-on-top avatar. Drag to move, click to open the full panel. It never takes keyboard focus.
final class PetWindow: NSPanel {
    var onClick: (() -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    private var dragStart: CGPoint?
    private var originStart = CGPoint.zero
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation; originStart = frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let now = NSEvent.mouseLocation
        setFrameOrigin(CGPoint(x: originStart.x + now.x - dragStart.x, y: originStart.y + now.y - dragStart.y))
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let dragStart else { return }
        let now = NSEvent.mouseLocation
        if hypot(now.x - dragStart.x, now.y - dragStart.y) < 3 { onClick?() } else { onMoved?(frame.origin) }
    }
}

/// Speech bubble next to the pet. Shows what the assistant said; buttons work without the window ever becoming key.
final class BubbleWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum PetLayout {
    static let size: CGFloat = 60
    static let bubbleWidth: CGFloat = 320
    static let bubbleMaxHeight: CGFloat = 280
    static let gap: CGFloat = 10

    static func defaultOrigin(in screen: CGRect) -> CGPoint {
        CGPoint(x: screen.maxX - size - 24, y: screen.minY + 24)
    }
    /// The bubble sits beside the pet on whichever side has room, bottom-aligned with it, and never off screen.
    static func bubbleFrame(pet: CGRect, height: CGFloat, screen: CGRect) -> CGRect {
        let h = min(max(height, 60), bubbleMaxHeight)
        let left = pet.midX > screen.midX
        var x = left ? pet.minX - gap - bubbleWidth : pet.maxX + gap
        x = min(max(x, screen.minX + 8), screen.maxX - 8 - bubbleWidth)
        var y = pet.minY
        y = min(max(y, screen.minY + 8), screen.maxY - 8 - h)
        return CGRect(x: x, y: y, width: bubbleWidth, height: h)
    }
}

// MARK: - Views

struct PetView: View {
    @ObservedObject var controller: Controller
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.accent)
                .scaleEffect(controller.busy && pulse ? 1.12 : 1)
                .animation(controller.busy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
            if controller.hasSuggestion {
                Circle().fill(Color.orange).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .offset(x: 20, y: -20)
            }
        }
        .frame(width: PetLayout.size, height: PetLayout.size)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .onAppear { pulse = true }
        .onChange(of: controller.busy) { pulse = controller.busy }
        .help(controller.busy ? "處理中…" : "點一下打開面板，拖曳移動")
        .accessibilityLabel("LinguaFloat 小幫手")
        .accessibilityAddTraits(.isButton)
    }
    private var symbol: String {
        if controller.busy { return "ellipsis.bubble.fill" }
        if controller.captureFailure != nil || controller.tone == .error { return "exclamationmark.bubble.fill" }
        if controller.pendingWindowCapture { return "questionmark.bubble.fill" }
        return "character.bubble.fill"
    }
}

struct BubbleView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let source = controller.source, let icon = source.icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "character.bubble.fill").foregroundStyle(Theme.accent).font(.caption)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if controller.busy { ProgressView().controlSize(.mini) }
                Button { controller.hideBubble() } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("關閉泡泡")
            }
            Text(body_)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(controller.pendingWindowCapture || controller.captureFailure != nil ? 4 : 8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !controller.busy, !controller.explanation.isEmpty {
                Text(controller.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !controller.output.isEmpty, !controller.busy {
                    Button { controller.copy(); controller.hideBubble() } label: { Label("複製", systemImage: "doc.on.doc") }
                    if controller.canApply {
                        Button { controller.apply() } label: { Label(controller.source?.kind == .selection ? "取代" : "套用", systemImage: "arrow.uturn.backward") }
                    }
                }
                Button { controller.openFromPet() } label: { Label(controller.pendingWindowCapture ? "確認" : "打開", systemImage: "rectangle.expand.vertical") }
                Spacer()
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: PetLayout.bubbleWidth, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.fitBubble(height: $0) }
    }
    private var title: String {
        let what: String
        switch controller.mode {
        case .correct: what = "校正"
        case .translateSecond: what = "翻譯為 \(settings.secondLanguage)"
        case .translate: what = "翻譯"
        }
        if let source = controller.source { return "\(what) · \(source.title)" }
        return what
    }
    private var body_: String {
        if controller.pendingWindowCapture { return "沒有選取或焦點文字。要讀取整個視窗（\(controller.source?.count.formatted() ?? "0") 字）嗎？按「確認」在面板裡送出。" }
        if let failure = controller.captureFailure { return failure.localizedDescription + " 打開面板可改用剪貼簿或 OCR。" }
        if controller.busy { return controller.partial.isEmpty ? controller.status : controller.partial }
        if !controller.output.isEmpty { return controller.output }
        return controller.status
    }
}
