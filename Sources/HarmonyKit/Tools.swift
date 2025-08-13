import Foundation

/// A Harmony tool is a deterministic, offline-safe capability that can be invoked by the
/// orchestration layer to augment a model turn.
///
/// Expectations:
/// - Implementations MUST be deterministic for given inputs.
/// - Implementations SHOULD be offline-safe by default (no network and App-Store compliant).
/// - Keep side-effects minimal and predictable.
public protocol HarmonyTool: Sendable {
    /// Stable, unique tool identifier. Used as the registry key.
    var name: String { get }
    /// Human-readable description shown to the model/UI when advertising tools.
    var description: String { get }
    /// JSON Schema for the tool arguments. Keep it small and self-contained.
    /// This is advertised to the model and UI when exposing tools for function-calling.
    var parametersJSONSchema: String { get }
    /// Invoke the tool with simple key/value arguments.
    /// Tools must be deterministic, side-effect-free by default, and offline-safe.
    func invoke(args: [String: Any]) throws -> ToolResult
}

public enum HarmonyToolboxError: Error, Equatable {
    case duplicateToolName(String)
}

/// Registry of Harmony tools keyed by name.
///
/// Thread-safety: simple serial queue to guard the map; lightweight for local use.
public final class HarmonyToolbox: @unchecked Sendable {
    private var toolsByName: [String: any HarmonyTool] = [:]
    private let queue = DispatchQueue(label: "harmony.toolbox")

    public init() {}

    /// Register a tool. Duplicate names are rejected.
    public func register(tool: any HarmonyTool) throws {
        try queue.sync {
            if toolsByName[tool.name] != nil {
                throw HarmonyToolboxError.duplicateToolName(tool.name)
            }
            toolsByName[tool.name] = tool
        }
    }

    /// Retrieve a tool by name.
    public func tool(named name: String) -> (any HarmonyTool)? {
        queue.sync { toolsByName[name] }
    }

    /// Snapshot of all registered tools.
    public func allTools() -> [any HarmonyTool] {
        queue.sync { Array(toolsByName.values) }
    }

    /// Schema metadata for all registered tools suitable for "function declaration" exposure.
    /// Returns tuples of (name, description, parametersJSONSchema).
    public func toolSchemas() -> [(name: String, description: String, parametersJSONSchema: String)] {
        queue.sync {
            toolsByName.values.map { tool in
                (name: tool.name, description: tool.description, parametersJSONSchema: tool.parametersJSONSchema)
            }
        }
    }
}


