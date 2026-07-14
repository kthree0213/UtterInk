import Darwin
import Foundation

@main
struct UtterInkIdentityExporterCommand {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2, arguments[0] == "--output", !arguments[1].isEmpty else {
                throw IdentityExporterError.invalidInput(
                    "usage: UtterInkIdentityExporter --output <directory>"
                )
            }

            let repositoryRoot = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).standardizedFileURL
            let inputs = IdentityInputPaths(
                sourceDirectory: repositoryRoot.appendingPathComponent("Brand/Source", isDirectory: true),
                paletteFile: repositoryRoot.appendingPathComponent("Brand/palettes.json")
            )
            let output = URL(fileURLWithPath: arguments[1], relativeTo: repositoryRoot).standardizedFileURL
            _ = try IdentityExporter.export(inputs: inputs, outputDirectory: output)
            print("UtterInk identity candidate exported.")
        } catch {
            fputs("UtterInkIdentityExporter: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
