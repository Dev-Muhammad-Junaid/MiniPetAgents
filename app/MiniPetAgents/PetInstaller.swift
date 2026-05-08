import Foundation
import AppKit

/// Wraps `npx petdex install/list` so the in-app gallery can install pets
/// without making the user pop out to a terminal.
final class PetInstaller {
    enum InstallerError: Error {
        case missingNpx
        case nonZeroExit(code: Int32, output: String)
    }

    /// Stream of stdout/stderr lines, plus a terminal result, for an install.
    struct Progress {
        let line: String
        let isError: Bool
    }

    static let shared = PetInstaller()
    private init() {}

    /// Run `npx petdex install <slug>`. Streams output via `onOutput`
    /// and calls `onComplete` on the main thread when finished.
    func install(slug: String,
                 onOutput: @escaping (Progress) -> Void,
                 onComplete: @escaping (Result<Void, Error>) -> Void) {
        runPetdex(args: ["install", slug], onOutput: onOutput) { result in
            switch result {
            case .success:
                PetLibrary.shared.rescan()
                onComplete(.success(()))
            case .failure(let err):
                onComplete(.failure(err))
            }
        }
    }

    /// Run `npx petdex list` and return parsed slug + author lines.
    /// We don't try to parse a pretty-printed table strictly — we just
    /// collect non-empty lines and let the gallery treat each as a pet.
    func list(onComplete: @escaping (Result<[String], Error>) -> Void) {
        var collected: [String] = []
        runPetdex(args: ["list"], onOutput: { progress in
            if !progress.isError {
                let trimmed = progress.line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { collected.append(trimmed) }
            }
        }, onComplete: { result in
            switch result {
            case .success: onComplete(.success(collected))
            case .failure(let err): onComplete(.failure(err))
            }
        })
    }

    // MARK: - Internal

    private func runPetdex(args: [String],
                           onOutput: @escaping (Progress) -> Void,
                           onComplete: @escaping (Result<Void, Error>) -> Void) {
        ShellEnvironment.findBinary(name: "npx",
                                    fallbackPaths: ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]) { npxPath in
            guard let npxPath = npxPath else {
                onComplete(.failure(InstallerError.missingNpx))
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: npxPath)
            proc.arguments = ["petdex"] + args
            proc.environment = ShellEnvironment.processEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            var collectedOutput = ""

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                collectedOutput += line
                DispatchQueue.main.async { onOutput(Progress(line: line, isError: false)) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                collectedOutput += line
                DispatchQueue.main.async { onOutput(Progress(line: line, isError: true)) }
            }

            proc.terminationHandler = { p in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    if p.terminationStatus == 0 {
                        onComplete(.success(()))
                    } else {
                        onComplete(.failure(InstallerError.nonZeroExit(
                            code: p.terminationStatus,
                            output: collectedOutput
                        )))
                    }
                }
            }

            do {
                try proc.run()
            } catch {
                onComplete(.failure(error))
            }
        }
    }
}
