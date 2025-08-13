import Foundation

enum DetectedEvent { // internal for testing via @testable import
    case text(String)
    case toolCall(name: String, args: [String: Any])
}

/// Detects tool-call JSON objects embedded in a token stream.
///
/// Detection rule ("function calling v0"):
/// - Start when seeing the substring `{\"tool\":`
/// - Balance braces `{` and `}` while respecting JSON strings and escapes
/// - When a balanced object is found, attempt to parse as JSON and match shape
///   `{ "tool": { "name": String, "arguments": { ... } } }`
/// - If valid, emit `.toolCall`; otherwise treat as text
/// - Text outside objects is forwarded via `.text`
/// - If a capture exceeds `maxCaptureBytes` without closing, abandon as text
struct ToolCallDetector {
    private let startMarker = "{\"tool\":"
    private let maxCaptureBytes: Int = 32 * 1024

    private var isCapturing = false
    private var captureBuffer = String()
    private var pendingPrefixText = String()
    private var objectStart: String.Index?

    init() {}

    mutating func ingest(_ token: String) -> [DetectedEvent] {
        var results: [DetectedEvent] = []
        var remaining = token[...]

        while !remaining.isEmpty {
            if !isCapturing {
                if let range = remaining.range(of: startMarker) {
                    // Begin capturing from the start marker including any prefix so we can coalesce
                    let prefix = String(remaining[..<range.lowerBound])
                    isCapturing = true
                    pendingPrefixText = prefix
                    captureBuffer = prefix + String(remaining[range.lowerBound...])
                    objectStart = captureBuffer.index(captureBuffer.startIndex, offsetBy: prefix.count)

                    // Try to complete capture immediately if possible
                    if let start = objectStart, let (endIdx, slice) = balancedJSONObjectSlice(in: captureBuffer, startingAt: start) {
                        // Found a balanced slice; decide parse outcome
                        let str = String(slice)
                        if let ev = parseToolCall(fromJSONString: str) {
                            if !pendingPrefixText.isEmpty { results.append(.text(pendingPrefixText)) }
                            results.append(ev)
                        } else {
                            // Not a valid tool call; emit one combined text chunk
                            results.append(.text(pendingPrefixText + str))
                        }
                        // Reset and continue with trailing part
                        let trailing = captureBuffer[endIdx...]
                        resetCapture()
                        remaining = Substring(trailing)
                        continue
                    } else {
                        // No closure yet; enforce cap and move on
                        if captureBuffer.utf8.count > maxCaptureBytes {
                            results.append(.text(captureBuffer))
                            resetCapture()
                        }
                        remaining = Substring("")
                        continue
                    }
                } else {
                    // No start marker in remaining; emit as text and finish
                    let text = String(remaining)
                    if !text.isEmpty { results.append(.text(text)) }
                    remaining = Substring("")
                    continue
                }
            } else {
                // Currently capturing; append and try to complete
                captureBuffer.append(contentsOf: remaining)
                remaining = Substring("")

                // Size cap safety
                if captureBuffer.utf8.count > maxCaptureBytes {
                    // Abandon capture and emit as text
                    results.append(.text(captureBuffer))
                    resetCapture()
                    continue
                }

                if let start = objectStart, let (endIdx, slice) = balancedJSONObjectSlice(in: captureBuffer, startingAt: start) {
                    let str = String(slice)
                    if let ev = parseToolCall(fromJSONString: str) {
                        if !pendingPrefixText.isEmpty { results.append(.text(pendingPrefixText)) }
                        results.append(ev)
                    } else {
                        results.append(.text(pendingPrefixText + str))
                    }
                    let trailing = captureBuffer[endIdx...]
                    resetCapture()
                    remaining = Substring(trailing)
                    continue
                }
            }
        }

        return results
    }

    /// Flushes any buffered content as text.
    mutating func finish() -> [DetectedEvent] {
        if isCapturing && !captureBuffer.isEmpty {
            let text = captureBuffer
            resetCapture()
            return [.text(text)]
        }
        return []
    }

    private func parseToolCall(fromJSONString str: String) -> DetectedEvent? {
        guard let data = str.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let tool = root["tool"] as? [String: Any],
              let name = tool["name"] as? String,
              let arguments = tool["arguments"] as? [String: Any] else { return nil }
        return .toolCall(name: name, args: arguments)
    }

    /// Returns the end index (exclusive) and the balanced slice if a full JSON object
    /// is found starting at the first character of `buffer`.
    private func balancedJSONObjectSlice(in buffer: String, startingAt: String.Index) -> (endExclusive: String.Index, slice: Substring)? {
        guard startingAt < buffer.endIndex, buffer[startingAt] == "{" else { return nil }

        var depth = 0
        var inString = false
        var prevWasBackslash = false

        var idx = startingAt
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            if inString {
                if prevWasBackslash {
                    prevWasBackslash = false
                } else if ch == "\\" {
                    prevWasBackslash = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                    prevWasBackslash = false
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = buffer.index(after: idx)
                        let slice = buffer[startingAt..<end]
                        return (end, slice)
                    }
                }
            }
            idx = buffer.index(after: idx)
        }
        return nil
    }

    private mutating func resetCapture() {
        captureBuffer.removeAll(keepingCapacity: false)
        pendingPrefixText.removeAll(keepingCapacity: false)
        objectStart = nil
        isCapturing = false
    }
}


