import Foundation

public enum PromptBuilder {
    /// Basic chat template similar to Harmony-style
    public static func conversation(system: String, messages: [(role: String, content: String)]) -> String {
        var lines: [String] = []
        lines.append("<|system|>\n" + system.trimmingCharacters(in: .whitespacesAndNewlines))
        for (role, content) in messages {
            lines.append("<|\(role)|>\n" + content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.append("<|assistant|>\n")
        return lines.joined(separator: "\n")
    }
}
