import Foundation
import SonifiedLLMCore

public extension PromptBuilder {
    enum Harmony {
        // MARK: - Chat template provider

        /// Supplies a model's chat template and special tokens when available.
        /// Tests can stub this to inject a template string without depending on runtime internals.
        public protocol ChatTemplateProvider {
            /// Template string used to wrap the rendered conversation when available.
            /// The following placeholders are supported:
            /// - `{{content}}` – will be replaced with the rendered conversation body
            /// - `{{bos}}` – will be replaced with `bosToken`
            /// - `{{eos}}` – will be replaced with `eosToken`
            var template: String? { get }
            var bosToken: String { get }
            var eosToken: String { get }
        }

        /// Provider that fetches the template from an injected closure.
        /// Keeps HarmonyKit decoupled from runtime internals.
        public struct GGUFChatTemplateProvider: ChatTemplateProvider {
            private let fetch: () -> String?
            public let bosToken: String
            public let eosToken: String
            public init(fetchTemplate: @escaping () -> String?, bosToken: String = "<s>", eosToken: String = "</s>") {
                self.fetch = fetchTemplate
                self.bosToken = bosToken
                self.eosToken = eosToken
            }
            public var template: String? { fetch() }
        }

        /// Default chat template for Harmony orchestration.
        /// Preserves the base SDK's role tags and formatting.
        /// If a model chat template is available via `provider`, the conversation is wrapped using it.
        /// Otherwise, a deterministic fallback local-model-friendly template is used.
        ///
        /// The fallback format uses role tags and trims trailing/leading whitespace per line:
        ///   <|system|>\nSYSTEM\n<|user|>\n...\n<|assistant|>\n
        public static func render(system: String?, messages: [HarmonyMessage], provider: ChatTemplateProvider? = nil) -> String {
            // Build the deterministic conversation body first (without BOS/EOS).
            let body = renderFallbackBody(system: system, messages: messages)

            // If a provider supplies a template, wrap the body using supported placeholders.
            if let provider, let t = provider.template {
                return renderWithTemplate(template: t, body: body, bos: provider.bosToken, eos: provider.eosToken)
            }

            return body
        }

        // MARK: - Private helpers

        /// Renders the deterministic fallback conversation body.
        /// - Preserves role tags used by local models.
        /// - For tool role, preserves the message name on the header line when present.
        private static func renderFallbackBody(system: String?, messages: [HarmonyMessage]) -> String {
            var lines: [String] = []
            let sys = (system ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("<|system|>\n" + sys)
            for m in messages {
                let role = m.role.rawValue
                let header: String
                if m.role == .tool, let name = m.name, !name.isEmpty {
                    // Keep classic tag present while preserving tool name for inspection.
                    header = "<|\(role)|> " + name
                } else {
                    header = "<|\(role)|>"
                }
                let content = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(header + "\n" + content)
            }
            lines.append("<|assistant|>\n")
            return lines.joined(separator: "\n")
        }

        /// Performs a minimal placeholder replacement suitable for simple model templates.
        /// Supported placeholders: `{{content}}`, `{{bos}}`, `{{eos}}`.
        private static func renderWithTemplate(template: String, body: String, bos: String, eos: String) -> String {
            var out = template
            out = out.replacingOccurrences(of: "{{content}}", with: body)
            out = out.replacingOccurrences(of: "{{bos}}", with: bos)
            out = out.replacingOccurrences(of: "{{eos}}", with: eos)
            return out
        }
    }
}


