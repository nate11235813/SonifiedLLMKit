### Resilient auto model selection

When running with `--model auto`, the CLI resolves a bundled model per your device caps. If the runtime fails to initialize the chosen model (e.g., OOM or unsupported), it will retry once with the next best bundled variant and continue streaming.

Smoke test with the stub runtime:

```arduino
CAUSE_INIT_FAIL=1 swift run HarmonyCLI --harmony --model auto --spec gpt-oss-20b:q4_K_M --input Examples/HarmonyCLI/Samples/sample.json
```

You should see a `[MODEL SELECTION]` line and, when a fallback occurs, an additional `[MODEL FALLBACK] reason=... from=... to=...` line before tokens stream.

## Harmony layer

### CLI auto model selection

Run the Harmony CLI with automatic bundled model selection (no downloads):

```bash
swift run HarmonyCLI --harmony --model auto --spec gpt-oss-20b:q4_K_M --input Examples/HarmonyCLI/Samples/sample.json
```

Notes:
- `auto` uses bundled models only; downloads are disabled in this phase.
- Pass `--spec <name>:<quant>` to declare the desired target; the selector will choose the closest bundled fallback if the exact one is unavailable for your device caps.
- The CLI prints a single selection line before generation, e.g.

```text
[MODEL SELECTION] requested=gpt-oss-20b:q4_K_M caps=arm64/16GB chosen=gpt-oss-20b:q4_K_M source=bundled path=/.../gpt-oss-20b-q4_K_M.gguf
```

HarmonyKit is a thin orchestration layer on top of `SonifiedLLMCore` that:

- streams tokens with early metrics and a final summary
- optionally detects and executes one tool call per turn
- stays offline-first and deterministic by default

You provide a list of `HarmonyMessage` values (system, user, assistant, tool) and get back a stream of `HarmonyEvent` values: `.metrics`, `.token`, `.toolCall`, `.toolResult`, and `.done`.

### Messages

Roles: `system`, `user`, `assistant`, `tool` (with optional `name`). These map directly into the model prompt using the preferred model chat template when available, otherwise a deterministic fallback.

```swift
let messages: [HarmonyMessage] = [
  HarmonyMessage(role: .user, content: "What is 2^8? Please use the math tool."),
]
```

Tool responses are represented as a `tool` role message with `name` set to the tool’s name.

```swift
let toolMsg = HarmonyMessage(role: .tool, content: "256", name: "math")
```

### Prompt templates

Harmony prefers a model’s embedded GGUF chat template automatically when available via `PromptBuilder.Harmony.GGUFChatTemplateProvider`. If none exists, it falls back to a local-model-friendly format with explicit role tags. Begin-of-sequence and end-of-sequence tokens are supplied by the provider when templating.

```swift
let provider = PromptBuilder.Harmony.GGUFChatTemplateProvider(fetchTemplate: { engineChatTemplate(engine) })
let prompt = PromptBuilder.Harmony.render(system: "You are a helpful assistant.", messages: messages, provider: provider)
```

### Streaming contract

The event stream yields:

- An early `.metrics` event is emitted at time-to-first-token (TTFB).

- `.metrics` early: first emission indicates TTFB in ms
- `.token` for each token chunk
- `.toolCall(name:args:)` when a tool call is detected
- `.toolResult(ToolResult)` immediately after local invocation
- `.metrics` final with totals (tok/s, duration, token counts, success flag)
- `.done` terminal event

```swift
let turn = HarmonyTurn(engine: engine, systemPrompt: system, messages: messages, options: .init(maxTokens: 128), toolbox: toolbox, chatTemplateProvider: provider)
for try await ev in turn.stream() {
  switch ev {
  case .metrics(let m): print("TTFB: \(m.ttfbMs) ms")
  case .token(let t):   print(t, terminator: "")
  case .toolCall(let name, let args): print("\n[TOOL CALL] \(name) args=\(args)")
  case .toolResult(let r): print("\n[TOOL RESULT] \(r.name) content=\(r.content) meta=\(r.metadata ?? [:])")
  case .done: print("\nDONE")
  }
}
```

### Sample app

```arduino
swift run HarmonyChatApp
# (Optional) with stub + forced fallback:
SONIFIED_USE_STUB=1 CAUSE_INIT_FAIL=1 swift run HarmonyChatApp
```

Note: models are bundled only (no download).

Toggle Enable tools to allow offline tool use (time, math, file info).
Tool events appear inline as [TOOL CALL] … and [TOOL RESULT] ….

### Tools

A tool is a deterministic, offline-safe capability:

- schema: `parametersJSONSchema` (minimal JSON Schema: type/object/properties/required)
- invoke: `invoke(args:) -> ToolResult`
- validation: strict by default via `HarmonyToolbox.validateArgsStrict` (rejects extra keys, enforces types)

By default, validation is strict: extra keys are rejected unless your schema explicitly allows them (JSON Schema’s default for `additionalProperties` is `true`, but Harmony treats it as `false` unless you set it otherwise).

```swift
public struct MathTool: HarmonyTool {
  public let name = "math"
  public let description = "Evaluate a simple arithmetic expression"
  public let parametersJSONSchema = "{" +
    "\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"],\"additionalProperties\":false" +
    "}"
  public func invoke(args: [String: Any]) throws -> ToolResult {
    let expr = (args["expression"] as? String) ?? ""
    return ToolResult(name: name, content: expr) // simplified for docs
  }
}

let toolbox = HarmonyToolbox()
try toolbox.register(tool: MathTool())
// or: HarmonyToolbox.demoTools(allowedRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
```

### Single tool round-trip

Harmony performs at most one tool round-trip per turn:

1) Detect tool call in the first stream leg
2) Validate args and invoke locally
3) Emit `.toolResult`
4) Resume generation with an appended `tool` message

### Cancellation and errors

Calling `HarmonyTurn.cancel()` cancels the underlying engine promptly. You will still receive a final `.metrics` with `success=false`, followed by `.done`. Invalid or unknown tools produce a `.toolResult` with an error payload; the turn then continues as normal.

### Limits / next

- Single tool call per turn by design (v0)
- Deterministic, offline-first tools only
- Extend by registering more tools and customizing prompts/templates per model

### Try it

With the CLI example:

```bash
swift run HarmonyCLI --harmony --model stub --input Examples/HarmonyCLI/Samples/sample.json
swift run HarmonyCLI --harmony --input Examples/HarmonyCLI/Samples/sample.json
swift run HarmonyCLI --harmony --input Examples/HarmonyCLI/Samples/sample.md
# Force the stub to emit a demo tool call without editing prompts:
SONIFIED_DEMO_TOOLCALL=1 swift run HarmonyCLI --harmony --model stub --input Examples/HarmonyCLI/Samples/sample.json
```


If you don’t have the native runtime available, append `--model stub` to run entirely with the mock/stub engine.


