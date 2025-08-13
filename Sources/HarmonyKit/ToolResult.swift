import Foundation

/// Canonical return type for any Harmony tool invocation.
///
/// - name: Stable tool name that produced this result
/// - content: Primary textual payload returned by the tool
/// - metadata: Optional small, structured extras for downstream consumers
public struct ToolResult: @unchecked Sendable, Equatable {
    public let name: String
    public let content: String
    public let metadata: [String: Any]?

    public init(name: String, content: String, metadata: [String: Any]? = nil) {
        self.name = name
        self.content = content
        self.metadata = metadata
    }

    public static func == (lhs: ToolResult, rhs: ToolResult) -> Bool {
        guard lhs.name == rhs.name, lhs.content == rhs.content else { return false }
        return areJSONLikeEqual(lhs.metadata, rhs.metadata)
    }
}

// MARK: - Lightweight deep equality for JSON-like dictionaries

@inline(__always)
private func areJSONLikeEqual(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
    switch (a, b) {
    case (nil, nil):
        return true
    case (nil, _), (_, nil):
        return false
    case let (a?, b?):
        // Try stable JSON encoding with sorted keys for deep equality
        if JSONSerialization.isValidJSONObject(a), JSONSerialization.isValidJSONObject(b) {
            let opts: JSONSerialization.WritingOptions = [.sortedKeys]
            guard let da = try? JSONSerialization.data(withJSONObject: a, options: opts),
                  let db = try? JSONSerialization.data(withJSONObject: b, options: opts) else {
                return NSDictionary(dictionary: a).isEqual(to: b)
            }
            return da == db
        }
        // Fallback: NSDictionary deep-equality for Foundation types
        return NSDictionary(dictionary: a).isEqual(to: b)
    }
}


