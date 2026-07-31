import Foundation

/// Evita el aviso ObjC "Class AVFFrameReceiver is implemented in both …" (y los
/// posibles cuelgues que advierte) que aparece cuando dos copias de las dylibs
/// de ffmpeg se cargan en el mismo proceso Python:
///
/// - `faster-whisper` importa **PyAV**, que incrusta su propio ffmpeg en
///   `av/.dylibs/` (p.ej. `libavdevice.62.3.102.dylib`).
/// - `pyannote.audio` arrastra `torchaudio` → **`torchcodec`**, cuyas
///   `libtorchcodec_core*.dylib` enlazan ffmpeg por `@rpath` apuntando a
///   `/opt/homebrew/opt/ffmpeg/lib` → carga una **segunda** copia de las mismas
///   dylibs → el runtime de ObjC detecta clases (`AVFFrameReceiver`, …)
///   registradas dos veces.
///
/// Estrategia: generar un directorio "shim" con symlinks de *soname* mayor
/// (`libavdevice.62.dylib` → el fichero versionado de `av/.dylibs`) y exportar
/// `DYLD_LIBRARY_PATH=<shim>` al lanzar Python. `DYLD_LIBRARY_PATH` se consulta
/// por nombre de fichero antes que el `@rpath`, así torchcodec resuelve las
/// mismas dylibs que ya cargó PyAV (una sola copia → sin duplicados ObjC).
///
/// Requiere Hardened Runtime desactivado (lo está en este proyecto); con
/// hardened runtime dyld ignoraría `DYLD_LIBRARY_PATH`.
final class FFmpegDylibShimService {
    static let shared = FFmpegDylibShimService()

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.allosa.TheTranscriptor.ffmpegShim")
    private var cachedDylibsDir: [String: String?] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Directorio del shim listo para inyectar en `DYLD_LIBRARY_PATH`, o `nil`
    /// si el intérprete no tiene PyAV (no hay ffmpeg incrustado que deduplicar)
    /// o si la generación falla.
    func shimDirectory(forPython pythonPath: String) -> URL? {
        guard let dylibsPath = pyavDylibsDirectory(forPython: pythonPath) else {
            return nil
        }
        let shimDir = Self.shimDirectoryURL()
        return queue.sync {
            do {
                try rebuildShim(fromDylibs: URL(fileURLWithPath: dylibsPath), into: shimDir)
                return shimDir
            } catch {
                return nil
            }
        }
    }

    static func shimDirectoryURL() -> URL {
        PythonPipelineService.applicationSupportDirectory()
            .appendingPathComponent("ffmpeg-shim", isDirectory: true)
    }

    /// Regenera (idempotente, desde cero) los symlinks de soname en `shimDir`
    /// apuntando a las dylibs versionadas de ffmpeg de `dylibsDir`.
    func rebuildShim(fromDylibs dylibsDir: URL, into shimDir: URL) throws {
        if fileManager.fileExists(atPath: shimDir.path) {
            try fileManager.removeItem(at: shimDir)
        }
        try fileManager.createDirectory(at: shimDir, withIntermediateDirectories: true)

        let entries = try fileManager.contentsOfDirectory(atPath: dylibsDir.path)
        for name in entries {
            guard let soname = Self.majorSoname(for: name) else { continue }
            let link = shimDir.appendingPathComponent(soname)
            guard !fileManager.fileExists(atPath: link.path) else { continue }
            let target = dylibsDir.appendingPathComponent(name)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    /// Dado `libavdevice.62.3.102.dylib` devuelve `libavdevice.62.dylib`. Solo
    /// aplica a las librerías de ffmpeg (`libav*` / `libsw*`); devuelve `nil`
    /// para cualquier otro fichero (p.ej. `libSvtAv1Enc.4.1.0.dylib`, `libx264…`).
    static func majorSoname(for filename: String) -> String? {
        guard filename.hasSuffix(".dylib"),
              filename.hasPrefix("libav") || filename.hasPrefix("libsw") else {
            return nil
        }
        let stem = String(filename.dropLast(".dylib".count))
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let major = parts.dropFirst().first,
              Int(major) != nil else {
            return nil
        }
        return "\(parts[0]).\(major).dylib"
    }

    private func pyavDylibsDirectory(forPython pythonPath: String) -> String? {
        if let cached = queue.sync(execute: { cachedDylibsDir[pythonPath] }) {
            return cached
        }
        let resolved = probePyavDylibs(pythonPath)
        queue.sync { cachedDylibsDir[pythonPath] = resolved }
        return resolved
    }

    private func probePyavDylibs(_ pythonPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            "-c",
            "import os, av; d = os.path.join(os.path.dirname(av.__file__), '.dylibs'); print(d if os.path.isdir(d) else '')"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(10.0)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return out.isEmpty ? nil : out
        } catch {
            return nil
        }
    }
}
