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
    case missingTool(String)
    case invalidArguments(String)
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

    // MARK: - Lookups and validation

    /// Retrieve a tool by name or throw a friendly error if missing.
    public func getToolOrThrow(named name: String) throws -> any HarmonyTool {
        guard let t = tool(named: name) else { throw HarmonyToolboxError.missingTool(name) }
        return t
    }

    /// Lightweight strict validation of args against a minimal JSON Schema subset.
    /// Supports: type=object, properties{key:{type}}, required[...]. Rejects extra keys and non-JSON-safe values.
    public func validateArgsStrict(args: [String: Any], schemaJSON: String) throws -> [String: Any] {
        guard let data = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw HarmonyToolboxError.invalidArguments("invalid schema JSON")
        }
        let type = (schema["type"] as? String) ?? "object"
        guard type == "object" else { throw HarmonyToolboxError.invalidArguments("schema type must be object") }
        let properties = (schema["properties"] as? [String: Any]) ?? [:]
        let requiredKeys = (schema["required"] as? [String]) ?? []
        let additionalPropsAllowed = (schema["additionalProperties"] as? Bool) ?? false

        // Ensure required keys exist
        for key in requiredKeys {
            if args[key] == nil { throw HarmonyToolboxError.invalidArguments("missing required key: \(key)") }
        }

        // Reject extra keys not in properties when additionalProperties is false
        let allowedKeys = Set(properties.keys)
        for key in args.keys {
            if !allowedKeys.contains(key) {
                if additionalPropsAllowed {
                    continue
                } else {
                    throw HarmonyToolboxError.invalidArguments("unexpected key: \(key)")
                }
            }
        }

        // Type-check and JSON-serializable enforcement
        var validated: [String: Any] = [:]
        for (key, value) in args {
            guard let prop = properties[key] as? [String: Any], let t = prop["type"] as? String else {
                // If no properties specified, still ensure JSON-safe
                guard JSONSerialization.isValidJSONObject([key: value]) else {
                    throw HarmonyToolboxError.invalidArguments("value for key \(key) is not JSON-serializable")
                }
                validated[key] = value
                continue
            }
            // Basic types: string, number, integer, boolean, object, array, null
            if !isValue(value, compatibleWithType: t) {
                throw HarmonyToolboxError.invalidArguments("key \(key) expected type \(t)")
            }
            validated[key] = value
        }

        // Final JSON-safe check
        guard JSONSerialization.isValidJSONObject(validated) else {
            throw HarmonyToolboxError.invalidArguments("arguments not JSON-serializable")
        }

        return validated
    }

    private func isValue(_ value: Any, compatibleWithType type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "number": return value is NSNumber && CFNumberGetType(value as! CFNumber) != .charType // exclude bool masquerading
        case "integer":
            if let n = value as? NSNumber {
                let ct = CFNumberGetType(n as CFNumber)
                switch ct {
                case .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type, .charType, .shortType, .intType, .longType, .longLongType:
                    return true
                default:
                    return false
                }
            }
            return false
        case "boolean": return (value as? NSNumber)?.isBool ?? (value is Bool)
        case "object": return value is [String: Any] && JSONSerialization.isValidJSONObject(value)
        case "array":
            if let arr = value as? [Any] {
                return JSONSerialization.isValidJSONObject(arr)
            }
            return false
        case "null": return value is NSNull
        default:
            // Unknown types fail safe
            return false
        }
    }
}

private extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

// MARK: - Convenience factory

public extension HarmonyToolbox {
    /// Convenience factory that registers first-party demo tools that are deterministic and offline-safe.
    static func demoTools(allowedRoot: URL) -> HarmonyToolbox {
        let box = HarmonyToolbox()
        // Best-effort registration; duplicate names would only occur if caller double-registers.
        do { try box.register(tool: TimeTool()) } catch {}
        do { try box.register(tool: MathTool()) } catch {}
        do { try box.register(tool: FileInfoTool(allowedRoot: allowedRoot)) } catch {}
        return box
    }
}


