import Foundation
import CryptoKit

/// Settings needed to launch the Python pipeline process.
struct PipelineSettings {
    var pythonPath: String
    var scriptPath: URL
    var model: WhisperModel
    var keepAudio: Bool
    var hfToken: String?
    /// Extra CLI arguments appended after the standard contract arguments.
    /// Used by tests to drive the fake fixture (e.g. `--slow`); the real
    /// script contract (§3.1) never requires this in production.
    var extraArguments: [String]

    init(
        pythonPath: String,
        scriptPath: URL,
        model: WhisperModel,
        keepAudio: Bool = false,
        hfToken: String? = nil,
        extraArguments: [String] = []
    ) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.model = model
        self.keepAudio = keepAudio
        self.hfToken = hfToken
        self.extraArguments = extraArguments
    }
}

/// Error surfaced by the pipeline, carrying the short `@@ERROR:` message plus
/// the accumulated stderr buffer for the error screen.
struct PipelineError: Error, Equatable {
    let message: String
    let stderrTail: [String]
}

/// Thread-safe circular buffer of the last ~200 stderr lines, for the error
/// screen. Actor-isolated so it can be safely appended to from the detached
/// stderr-reading task and read from the main pipeline task concurrently.
private actor StderrBuffer {
    private let limit: Int
    private var lines: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func snapshot() -> [String] {
        lines
    }
}

/// Turns a pipe's readable side into an `AsyncStream` of lines, delivered
/// incrementally as data arrives.
///
/// `FileHandle.bytes.lines` (the AsyncSequence-based reader) was tried first
/// but, empirically, batches everything until the pipe hits EOF instead of
/// yielding lines as they're written — unacceptable both for live progress
/// (CU-03) and for the §7 deadlock risk on a full stderr buffer with real
/// pyannote/whisper output. `FileHandle.readabilityHandler` fires as soon as
/// bytes are available and reads them off the pipe immediately, which is
/// what §4.1 actually requires.
private func lineStream(_ handle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
        var buffer = Data()
        handle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                // EOF: flush any trailing partial line without a newline.
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    continuation.yield(line)
                }
                fileHandle.readabilityHandler = nil
                continuation.finish()
                return
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                continuation.yield(String(decoding: lineData, as: UTF8.self))
            }
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
    }
}

/// Wraps the external Python transcription pipeline (`Process`) and exposes
/// its `@@`-prefixed stdout protocol as an `AsyncStream<Event>`.
///
/// See docs/02-diseno-tecnico.md §3 (contract) and §4.1 (this service).
@Observable
final class PythonPipelineService {
    enum Event: Equatable {
        case phase(PipelinePhase)
        case progress(Int)
        case downloadingModels
        case done(URL)
        case failed(PipelineError)
    }

    private static let stderrTailLimit = 200

    private var process: Process?
    private var workDir: URL?
    private var watchdogTask: Task<Void, Never>?
    private var isCancelling = false

    /// PID of the most recently launched child process. Exposed for tests
    /// that need to verify the process actually died after cancellation.
    private(set) var lastProcessIdentifier: Int32?

    // MARK: - Public API

    func run(input: URL, settings: PipelineSettings) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await self.runPipeline(input: input, settings: settings, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        isCancelling = true
        process.terminate()

        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Removes any `work/<UUID>` directories left behind by a previous run
    /// that never got the chance to clean up (e.g. the app was force-quit
    /// mid-transcription). Safe to call at app launch.
    static func purgeOrphanedWorkDirs() {
        let fm = FileManager.default
        let workRoot = applicationSupportDirectory().appendingPathComponent("work", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Pipeline execution

    private func runPipeline(
        input: URL,
        settings: PipelineSettings,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        let fm = FileManager.default

        let workDir = Self.applicationSupportDirectory()
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.workDir = workDir

        let cleanupWorkDir: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: workDir)
        }

        let scriptURL: URL
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            scriptURL = try Self.ensureScriptInstalled(from: settings.scriptPath)
        } catch {
            cleanupWorkDir()
            continuation.yield(.failed(PipelineError(message: "No se pudo preparar el entorno de ejecución: \(error.localizedDescription)", stderrTail: [])))
            continuation.finish()
            self.workDir = nil
            return
        }

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: settings.pythonPath)

        var arguments = [
            scriptURL.path,
            "--input", input.path,
            "--output-dir", workDir.path,
            "--model", settings.model.rawValue,
            "--json"
        ]
        if settings.keepAudio {
            arguments.append("--keep-audio")
        }
        arguments.append(contentsOf: settings.extraArguments)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin"
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(extraPath):\(existingPath)"
        } else {
            environment["PATH"] = extraPath
        }
        if let hfToken = settings.hfToken, !hfToken.isEmpty {
            environment["HF_TOKEN"] = hfToken
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrBuffer = StderrBuffer(limit: Self.stderrTailLimit)

        let terminationBox = TerminationBox()

        process.terminationHandler = { [weak self] _ in
            terminationBox.signal()
            self?.watchdogTask?.cancel()
            self?.watchdogTask = nil
            cleanupWorkDir()
            self?.workDir = nil
            self?.process = nil
        }

        do {
            try process.run()
            lastProcessIdentifier = process.processIdentifier
        } catch {
            cleanupWorkDir()
            self.workDir = nil
            self.process = nil
            continuation.yield(.failed(PipelineError(message: "No se pudo lanzar el proceso Python: \(error.localizedDescription)", stderrTail: [])))
            continuation.finish()
            return
        }

        // Read stderr continuously so its pipe buffer never fills up and
        // deadlocks the child process.
        let stderrTask = Task.detached {
            for await line in lineStream(stderrPipe.fileHandleForReading) {
                await stderrBuffer.append(line)
            }
        }

        // Read stdout continuously and parse the `@@` protocol.
        let stdoutTask = Task.detached {
            for await line in lineStream(stdoutPipe.fileHandleForReading) {
                guard line.hasPrefix("@@") else { continue }
                let payload = line.dropFirst(2)

                if payload.hasPrefix("PHASE:") {
                    let value = String(payload.dropFirst("PHASE:".count))
                    if let phase = PipelinePhase(rawValue: value) {
                        continuation.yield(.phase(phase))
                    }
                } else if payload.hasPrefix("PROGRESS:") {
                    let value = String(payload.dropFirst("PROGRESS:".count))
                    if let progress = Int(value) {
                        continuation.yield(.progress(progress))
                    }
                } else if payload.hasPrefix("INFO:downloading_models") {
                    continuation.yield(.downloadingModels)
                } else if payload.hasPrefix("DONE:") {
                    let path = String(payload.dropFirst("DONE:".count))
                    continuation.yield(.done(URL(fileURLWithPath: path)))
                    continuation.finish()
                } else if payload.hasPrefix("ERROR:") {
                    let message = String(payload.dropFirst("ERROR:".count))
                    let tail = await stderrBuffer.snapshot()
                    continuation.yield(.failed(PipelineError(message: message, stderrTail: tail)))
                    continuation.finish()
                }
            }
        }

        // Wait for the process to actually terminate before finishing the
        // stream (covers cancellation and unexpected exits without an
        // @@ERROR/@@DONE line).
        await terminationBox.wait()
        await stdoutTask.value
        await stderrTask.value

        if process.terminationStatus != 0 && !isCancelling {
            let tail = await stderrBuffer.snapshot()
            continuation.yield(.failed(PipelineError(message: "El proceso terminó inesperadamente (código \(process.terminationStatus)).", stderrTail: tail)))
        }
        isCancelling = false
        continuation.finish()
    }

    // MARK: - Script installation

    private static func ensureScriptInstalled(from bundledScript: URL) throws -> URL {
        let fm = FileManager.default
        let destination = applicationSupportDirectory().appendingPathComponent("transcriptor_local.py")

        try fm.createDirectory(at: applicationSupportDirectory(), withIntermediateDirectories: true)

        let bundledData = try Data(contentsOf: bundledScript)
        let bundledHash = SHA256.hash(data: bundledData)

        if fm.fileExists(atPath: destination.path),
           let existingData = try? Data(contentsOf: destination) {
            let existingHash = SHA256.hash(data: existingData)
            if existingHash == bundledHash {
                return destination
            }
        }

        try bundledData.write(to: destination, options: .atomic)
        return destination
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TheTranscriptor", isDirectory: true)
    }
}

/// Small actor-free helper to await Process.terminationHandler from async code.
private final class TerminationBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var signaled = false
    private let lock = NSLock()

    func signal() {
        lock.lock()
        if !signaled {
            signaled = true
            semaphore.signal()
        }
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [semaphore] in
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}
