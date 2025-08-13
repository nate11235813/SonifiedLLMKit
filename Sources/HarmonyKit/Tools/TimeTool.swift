import Foundation

public struct TimeTool: HarmonyTool {
    public let name: String = "time"
    public let description: String = "Return the current UTC time in ISO-8601 format with a Unix timestamp."
    public let parametersJSONSchema: String = "{" +
    "\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false" +
    "}"

    public init() {}

    public func invoke(args: [String : Any]) throws -> ToolResult {
        // Deterministic ISO-8601 in UTC with internet date time (no fractional seconds)
        let now = Date()
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.formatOptions = [.withInternetDateTime]
        let iso = fmt.string(from: now)
        let timestamp = Int(now.timeIntervalSince1970)
        return ToolResult(name: name, content: iso, metadata: ["timestamp": timestamp])
    }
}


