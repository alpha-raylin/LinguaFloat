import Foundation

public struct ProtectedText {
    public let text: String
    private let tokens: [(String, String)]
    /// Placeholder → original text, in replacement order.
    var placeholders: [(String, String)] { tokens }
    public init(_ input: String) {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let pattern = #"(?s)```.*?```|`[^`\n]+`|https?://[^\s<>]+|(?m)^[ \t]*(?:\$ |% ).*$|(?:\./|~/|/)[A-Za-z0-9_./-]+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = input as NSString
        var output = input
        var pairs: [(String, String)] = []
        for (index, match) in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)).enumerated().reversed() {
            let key = "⟦LF_\(nonce)_\(index)⟧"
            let original = ns.substring(with: match.range)
            pairs.append((key, original))
            output = (output as NSString).replacingCharacters(in: match.range, with: key)
        }
        text = output
        tokens = pairs
    }
    public func restore(_ output: String) throws -> String {
        var restored = output
        for (key, original) in tokens {
            guard restored.components(separatedBy: key).count == 2 else { throw PolicyError.modifiedToken }
            restored = restored.replacingOccurrences(of: key, with: original)
        }
        return restored
    }
}
public enum PolicyError: LocalizedError {
    case modifiedToken
    public var errorDescription: String? { "模型改動了受保護文字，已停止套用。請重試。" }
}
public enum TextPolicy {
    public static func canReplace(original: String, current: String, pid: Int32, currentPID: Int32) -> Bool {
        !original.isEmpty && original == current && pid == currentPID
    }
}
