import Foundation

/// Aprovisiona un entorno Python gestionado por la app (venv propio en
/// Application Support) cuando el usuario no tiene faster-whisper/pyannote
/// instalados en ningún intérprete detectado. Solo necesita *algún* python3
/// del sistema como bootstrap; no requiere que ya tenga los paquetes.
final class PythonSetupService {
    enum Event: Equatable {
        case log(String)
        case done(pythonPath: String)
        case failed(String)
    }

    struct SetupError: Error {
        let message: String
    }

    func setup() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let pythonPath = try await self.run(continuation: continuation)
                    continuation.yield(.done(pythonPath: pythonPath))
                } catch let error as SetupError {
                    continuation.yield(.failed(error.message))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(continuation: AsyncStream<Event>.Continuation) async throws -> String {
        guard let bootstrapPython = PythonEnvironmentDetector().detectPythonPath() else {
            throw SetupError(message: "No se encontró ningún intérprete Python 3 en este Mac. Instala Python 3.8+ antes de continuar.")
        }
        continuation.yield(.log("Usando \(bootstrapPython) para crear el entorno…"))

        let venvDir = Self.venvDirectory()
        try? FileManager.default.removeItem(at: venvDir)

        continuation.yield(.log("Creando entorno virtual en \(venvDir.path)…"))
        try await runProcess(executable: bootstrapPython, arguments: ["-m", "venv", venvDir.path], continuation: continuation)

        let venvPython = venvDir.appendingPathComponent("bin/python3").path

        guard let requirementsURL = Bundle.main.url(forResource: "requirements", withExtension: "txt") else {
            throw SetupError(message: "No se encontró requirements.txt embebido en la app.")
        }

        continuation.yield(.log("Actualizando pip…"))
        try await runProcess(
            executable: venvPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            continuation: continuation
        )

        continuation.yield(.log("Instalando faster-whisper y pyannote.audio (puede tardar varios minutos)…"))
        try await runProcess(
            executable: venvPython,
            arguments: ["-m", "pip", "install", "-r", requirementsURL.path],
            continuation: continuation
        )

        continuation.yield(.log("Entorno listo."))
        return venvPython
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        continuation: AsyncStream<Event>.Continuation
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            process.environment = env

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                continuation.yield(.log(trimmed))
            }

            process.terminationHandler = { finishedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                if finishedProcess.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: SetupError(message: (message?.isEmpty == false ? message! : "Fallo ejecutando \(executable) \(arguments.joined(separator: " "))")))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    static func venvDirectory() -> URL {
        PythonPipelineService.applicationSupportDirectory().appendingPathComponent("venv", isDirectory: true)
    }
}
