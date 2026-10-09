import Foundation
import CoreGraphics

/// Reads a string field out of an incomplete JSON object so streamed text can be shown while the model is still writing.
/// Returns nil until the opening quote of the value has arrived. Escape sequences that are cut off at the end are dropped, never shown raw.
public enum PartialJSON {
    public static func stringField(_ key: String, in buffer: String) -> String? {
        guard let keyRange = buffer.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        func skipWhitespace() { while index < buffer.endIndex, buffer[index].isWhitespace { index = buffer.index(after: index) } }
        skipWhitespace()
        guard index < buffer.endIndex, buffer[index] == ":" else { return nil }
        index = buffer.index(after: index)
        skipWhitespace()
        guard index < buffer.endIndex, buffer[index] == "\"" else { return nil }
        index = buffer.index(after: index)
        var output = ""
        var pendingHighSurrogate: UInt16?
        while index < buffer.endIndex {
            let character = buffer[index]
            if character == "\"" { return output }
            guard character == "\\" else { output.append(character); index = buffer.index(after: index); continue }
            let escapeIndex = buffer.index(after: index)
            guard escapeIndex < buffer.endIndex else { return output }
            let escape = buffer[escapeIndex]
            index = buffer.index(after: escapeIndex)
            switch escape {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "b": output.append("\u{8}")
            case "f": output.append("\u{C}")
            case "\"", "\\", "/": output.append(escape)
            case "u":
                guard let end = buffer.index(index, offsetBy: 4, limitedBy: buffer.endIndex),
                      let unit = UInt16(buffer[index..<end], radix: 16) else { return output }
                index = end
                if let high = pendingHighSurrogate {
                    pendingHighSurrogate = nil
                    if (0xDC00...0xDFFF).contains(unit), let scalar = UnicodeScalar(0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)) {
                        output.unicodeScalars.append(scalar)
                    }
                } else if (0xD800...0xDBFF).contains(unit) {
                    pendingHighSurrogate = unit
                } else if let scalar = UnicodeScalar(unit) {
                    output.unicodeScalars.append(scalar)
                }
            default: output.append(escape)
            }
        }
        return output
    }
}

public extension ProtectedText {
    /// Best-effort restore for streamed text: complete placeholders are swapped back, a placeholder still being written is hidden.
    func restorePartial(_ output: String) -> String {
        var restored = output
        if let open = restored.lastIndex(of: "⟦"), restored[open...].contains("⟧") == false {
            restored = String(restored[..<open])
        }
        for (key, original) in placeholders { restored = restored.replacingOccurrences(of: key, with: original) }
        return restored
    }
}

/// Where a quick panel goes, in Cocoa screen coordinates (origin bottom-left). Pure geometry so it can be unit-tested.
public struct Placement: Equatable {
    public enum Edge { case below, above, free }
    public let frame: CGRect
    public let edge: Edge
    public init(frame: CGRect, edge: Edge) { self.frame = frame; self.edge = edge }

    /// Prefers directly under the text the user is looking at, flips above it when there is no room, otherwise hangs off the pointer.
    public static func place(size: CGSize, anchor: CGRect?, pointer: CGPoint?, screen: CGRect, gap: CGFloat = 8) -> Placement {
        let width = min(size.width, screen.width - 2 * gap)
        let height = min(size.height, screen.height - 2 * gap)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, screen.minX + gap), screen.maxX - gap - width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, screen.minY + gap), screen.maxY - gap - height) }
        // A whole-window "anchor" (no selection, no field) says nothing about where the user is looking; use the pointer instead.
        if let anchor, !anchor.isEmpty, screen.intersects(anchor), anchor.height < screen.height / 2 {
            let x = clampX(anchor.minX)
            let below = anchor.minY - gap - height
            if below >= screen.minY + gap { return Placement(frame: CGRect(x: x, y: below, width: width, height: height), edge: .below) }
            let above = anchor.maxY + gap
            if above + height <= screen.maxY - gap { return Placement(frame: CGRect(x: x, y: above, width: width, height: height), edge: .above) }
            return Placement(frame: CGRect(x: x, y: clampY(below), width: width, height: height), edge: .free)
        }
        if let pointer, screen.contains(pointer) {
            return Placement(frame: CGRect(x: clampX(pointer.x - 24), y: clampY(pointer.y - 16 - height), width: width, height: height), edge: .free)
        }
        return Placement(frame: CGRect(x: clampX(screen.midX - width / 2), y: clampY(screen.maxY - 96 - height), width: width, height: height), edge: .free)
    }

    /// Resizes a shown panel without moving the edge the user is looking from: top stays put below the text, bottom stays put above it.
    public static func resize(_ frame: CGRect, to height: CGFloat, edge: Edge, screen: CGRect, gap: CGFloat = 8) -> CGRect {
        let height = min(height, screen.height - 2 * gap)
        var next = frame
        next.size.height = height
        next.origin.y = edge == .above ? frame.minY : frame.maxY - height
        next.origin.y = min(max(next.origin.y, screen.minY + gap), screen.maxY - gap - height)
        return next
    }
}
