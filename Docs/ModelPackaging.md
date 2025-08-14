## Auto fallback on engine init failure

When using auto selection, the loader will attempt to initialize the requested bundled model. If runtime initialization fails (e.g., OOM or unsupported), it will automatically retry once with the next best bundled variant based on your device caps.

Smoke test with the runtime stub:

```arduino
CAUSE_INIT_FAIL=1 swift run HarmonyCLI --harmony --model auto --spec gpt-oss-20b:q4_K_M --input Examples/HarmonyCLI/Samples/sample.json
```

Expected:
- A `[MODEL FALLBACK]` line such as: `reason=oom from=gpt-oss-20b:q4_K_M to=gpt-oss-7b:q4_K_M`
- Streaming tokens continue after selection.

### Packaging models with your app

This project supports bundling GGUF models directly in your app bundle and discovering them automatically.

### Where to place models

- Put GGUF files under `Models/` at the repository root:
  - Nested: `Models/<name>/<name>-<quant>.gguf`
  - Flat: `Models/<name>-<quant>.gguf`

The filename must follow `<name>-<quant>.gguf` (e.g., `gpt-oss-20b-q4_K_M.gguf`).

### Bundled index format

The index is written to `BundledModels/index.json` and follows this schema:

```json
{
  "embedded": true,
  "models": [
    {
      "name": "gpt-oss-20b",
      "quant": "q4_K_M",
      "path": "Models/gpt-oss-20b/gpt-oss-20b-q4_K_M.gguf",
      "minRamGB": 16,
      "arch": ["arm64"]
    }
  ]
}
```

- `name`: Logical model name.
- `quant`: Quantization string.
- `path`: Path relative to bundle resources.
- `minRamGB` (optional): Minimum RAM required to select this entry.
- `arch` (optional): Allowed architectures (e.g., `arm64`).

### Generating or updating the index

Use the tiny Swift tool `ModelIndexGen`:

```bash
swift build -c release --product ModelIndexGen
.build/release/ModelIndexGen --models Models --out BundledModels/index.json
```

It scans `Models/` and produces a pretty-printed, stable `index.json` sorted by name then quant rank.

### One-liner: add a model and refresh index

```bash
make bundle-model NAME=gpt-oss-20b QUANT=q4_K_M PATH=/absolute/path/to/model.gguf
```

This copies your file into `Models/gpt-oss-20b/gpt-oss-20b-q4_K_M.gguf` and regenerates the index.

### Editing caps (minRamGB / arch)

After generating, you may edit `BundledModels/index.json` to set `minRamGB` or `arch` for entries. These fields are used during `--model auto` selection to ensure only suitable models are chosen for the current device.

### Using with `--model auto`

When running the CLI with `--model auto`, the app:
- Loads `BundledModels/index.json` if present.
- Attempts exact match of your requested `name` + `quant` (subject to caps).
- Otherwise, chooses the best available fallback based on quant rank and device caps.


