import Foundation
import AppKit

/// Installs pets from petdex.dev so the in-app gallery can add pets without
/// making the user pop out to a terminal. Installs use the petdex.dev install
/// script (`curl -sSf https://petdex.dev/install/<slug> | sh`) directly, which
/// bypasses the npm registry — `npx petdex` currently 403s, so the script is
/// the reliable path.
final class PetInstaller {
    enum InstallerError: LocalizedError {
        case missingNpx
        case invalidSlug(String)
        case nonZeroExit(code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .missingNpx:
                return "npx not found — install Node.js from https://nodejs.org and try again"
            case .invalidSlug(let slug):
                return "Invalid pet name \"\(slug)\""
            case .nonZeroExit(let code, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
                return "petdex exited with code \(code)\(tail.isEmpty ? "" : ": \(tail)")"
            }
        }
    }

    /// Stream of stdout/stderr lines, plus a terminal result, for an install.
    struct Progress {
        let line: String
        let isError: Bool
    }

    static let shared = PetInstaller()
    private init() {}

    /// Install a pet by running petdex.dev's install script:
    ///   curl -sSf https://petdex.dev/install/<slug> | sh
    /// Streams output via `onOutput` and calls `onComplete` on the main thread.
    func install(slug: String,
                 onOutput: @escaping (Progress) -> Void,
                 onComplete: @escaping (Result<Void, Error>) -> Void) {
        // The slug is interpolated into a shell pipeline, so restrict it to the
        // characters petdex slugs actually use (letters, digits, - _ .) to rule
        // out any shell metacharacters.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !slug.isEmpty, slug.unicodeScalars.allSatisfy(allowed.contains) else {
            onComplete(.failure(InstallerError.invalidSlug(slug)))
            return
        }

        runInstallScript(slug: slug, onOutput: onOutput) { result in
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

    /// Run `curl -sSf https://petdex.dev/install/<slug> | sh`, streaming output.
    /// Fetches the install script from petdex.dev and pipes it to `sh`, mirroring
    /// the working terminal command and avoiding the npm registry entirely.
    private func runInstallScript(slug: String,
                                  onOutput: @escaping (Progress) -> Void,
                                  onComplete: @escaping (Result<Void, Error>) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        // -f makes curl fail (non-zero exit) on an HTTP error instead of piping
        // an error page into sh; the leading `set -o pipefail` propagates a curl
        // failure through the pipe so we surface it instead of a silent success.
        proc.arguments = [
            "-c",
            "set -o pipefail; curl -fsSL 'https://petdex.dev/install/\(slug)' | sh"
        ]
        proc.environment = ShellEnvironment.processEnvironment()
        // Closed stdin: the piped script is sh's input, so nothing should be
        // read from the app's own stdin, and a prompt here would hang install.
        proc.standardInput = FileHandle.nullDevice

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
            // --yes auto-approves "Need to install petdex? (y)" so the gallery
            // install flow doesn't stall waiting for stdin input.
            proc.arguments = ["--yes", "petdex"] + args
            proc.environment = ShellEnvironment.processEnvironment()
            // Belt and braces with --yes: a closed stdin turns any prompt we
            // didn't anticipate into EOF instead of an indefinite hang.
            proc.standardInput = FileHandle.nullDevice

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
