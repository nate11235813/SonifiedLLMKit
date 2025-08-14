import Foundation
import SonifiedLLMDownloader
import SonifiedLLMCore

// Simple CLI: ModelIndexGen [--models <dir>] [--out <file>] [--embedded true|false]

struct Args {
    var models: URL
    var out: URL
    var embedded: Bool
}

func parseArgs() -> Args {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var models = cwd.appendingPathComponent("Models", isDirectory: true)
    var out = cwd.appendingPathComponent("BundledModels/index.json")
    var embedded = true

    var it = CommandLine.arguments.makeIterator()
    _ = it.next() // skip executable name
    while let a = it.next() {
        switch a {
        case "--models":
            if let p = it.next() { models = URL(fileURLWithPath: p, isDirectory: true) }
        case "--out":
            if let p = it.next() { out = URL(fileURLWithPath: p) }
        case "--embedded":
            if let v = it.next() { embedded = (v as NSString).boolValue }
        default:
            break
        }
    }
    return Args(models: models, out: out, embedded: embedded)
}

let args = parseArgs()
do {
    try ModelIndexGenerator.generate(modelsRoot: args.models, outputURL: args.out, embedded: args.embedded)
    print("Wrote \(args.out.path)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}


