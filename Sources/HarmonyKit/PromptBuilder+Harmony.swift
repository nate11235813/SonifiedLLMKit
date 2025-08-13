import Foundation
import SonifiedLLMCore

public extension PromptBuilder {
    enum Harmony {
        /// Default chat template for Harmony orchestration.
        /// Preserves the base SDK's role tags and formatting.
        public static func render(system: String?, messages: [HarmonyMessage]) -> String {
            var lines: [(role: String, content: String)] = []
            if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append((role: "system", content: system))
            }
            for m in messages {
                lines.append((role: m.role.rawValue, content: m.content))
            }
            // Ensure we always pass a system string; PromptBuilder.conversation expects it
            let sys = lines.first?.content ?? ""
            return PromptBuilder.conversation(system: sys, messages: Array(lines.dropFirst()))
        }
    }
}


