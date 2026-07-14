import Darwin
import Foundation

enum IdentityExporterCommandLine: Equatable {
    case output(String)
    case integrate(selection: String, lock: String, assetCatalog: String)
    case check(lock: String, assetCatalog: String)

    static func parse(_ arguments: [String]) throws -> IdentityExporterCommandLine {
        if arguments.count == 2, arguments[0] == "--output", !arguments[1].isEmpty {
            return .output(arguments[1])
        }
        guard let mode = arguments.first, mode == "--integrate" || mode == "--check" else {
            throw usageError()
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw usageError() }
            let flag = arguments[index]
            let value = arguments[index + 1]
            guard ["--selection", "--lock", "--asset-catalog"].contains(flag),
                  values[flag] == nil, isStrictRelativePath(value) else {
                throw usageError()
            }
            values[flag] = value
            index += 2
        }
        guard let lock = values["--lock"], let catalog = values["--asset-catalog"] else {
            throw usageError()
        }
        if mode == "--integrate" {
            guard values.count == 3, let selection = values["--selection"] else {
                throw usageError()
            }
            return .integrate(selection: selection, lock: lock, assetCatalog: catalog)
        }
        guard values.count == 2 else { throw usageError() }
        return .check(lock: lock, assetCatalog: catalog)
    }

    private static func isStrictRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.hasPrefix("~")
            && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func usageError() -> IdentityExporterError {
        .invalidInput(
            "usage: UtterInkIdentityExporter --output <directory> | "
                + "--integrate --selection <file> --lock <file> --asset-catalog <directory> | "
                + "--check --lock <file> --asset-catalog <directory>"
        )
    }
}

@main
struct UtterInkIdentityExporterCommand {
    static func main() {
        do {
            let command = try IdentityExporterCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
            let root = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).standardizedFileURL
            switch command {
            case let .output(path):
                let inputs = IdentityInputPaths(
                    sourceDirectory: root.appendingPathComponent("Brand/Source", isDirectory: true),
                    paletteFile: root.appendingPathComponent("Brand/palettes.json")
                )
                let output = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
                _ = try IdentityExporter.export(inputs: inputs, outputDirectory: output)
                print("UtterInk identity candidate exported.")
            case let .integrate(selection, lock, catalog):
                let request = IdentityProductionRequest(
                    repositoryRoot: root,
                    selectionFile: root.appendingPathComponent(selection).standardizedFileURL,
                    lockFile: root.appendingPathComponent(lock).standardizedFileURL,
                    assetCatalog: root.appendingPathComponent(catalog).standardizedFileURL
                )
                _ = try IdentityExporter.integrateProductionIdentity(request: request)
                print("UtterInk identity assets integrated and locked.")
            case let .check(lock, catalog):
                let request = IdentityProductionRequest(
                    repositoryRoot: root,
                    selectionFile: root.appendingPathComponent("Brand/identity-selection.json"),
                    lockFile: root.appendingPathComponent(lock).standardizedFileURL,
                    assetCatalog: root.appendingPathComponent(catalog).standardizedFileURL
                )
                try IdentityExporter.checkProductionIdentity(request: request)
                print("UtterInk identity lock verified.")
            }
        } catch {
            fputs("UtterInkIdentityExporter: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
