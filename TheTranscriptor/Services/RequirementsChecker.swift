import Foundation

class RequirementsChecker {
    private let detector = PythonEnvironmentDetector()
    private let timeout: TimeInterval = 10.0
    // `import faster_whisper, pyannote.audio` pulls in torch/torchaudio; en
    // frío (sin __pycache__, p.ej. justo tras una instalación nueva) puede
    // tardar >10s. Un timeout corto aquí produce falsos negativos que llevan
    // al usuario a reinstalar un entorno que en realidad ya funciona.
    private let packagesTimeout: TimeInterval = 45.0

    func checkRequirements(
        pythonPath: String? = nil,
        huggingFaceToken: String? = nil
    ) -> [RequirementCheck] {
        var checks: [RequirementCheck] = []

        // 1. Check Python
        if let pythonPath = detector.detectPythonPath(savedPath: pythonPath) {
            if let version = getPythonVersion(pythonPath) {
                checks.append(RequirementCheck.python(version: version))
            } else {
                checks.append(.pythonMissing())
            }

            // 2. Check packages (only if Python is found)
            let packageCheck = checkPackages(pythonPath: pythonPath)
            checks.append(packageCheck)
        } else {
            checks.append(.pythonMissing())
            checks.append(.packagesMissing(["faster-whisper", "pyannote.audio"]))
        }

        // 3. Check ffmpeg
        checks.append(checkFFmpeg())

        // 4. Check Hugging Face token (warning only)
        if let token = huggingFaceToken, !token.isEmpty {
            checks.append(.huggingFaceToken())
        } else {
            checks.append(.huggingFaceTokenMissing())
        }

        return checks
    }

    private func getPythonVersion(_ pythonPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }

            if process.isRunning {
                process.terminate()
                return nil
            }

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }

        return nil
    }

    private func checkPackages(pythonPath: String) -> RequirementCheck {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import faster_whisper, pyannote.audio"]

        if let shim = FFmpegDylibShimService.shared.shimDirectory(forPython: pythonPath) {
            var env = ProcessInfo.processInfo.environment
            let existing = env["DYLD_LIBRARY_PATH"]
            if let existing, !existing.isEmpty {
                env["DYLD_LIBRARY_PATH"] = "\(shim.path):\(existing)"
            } else {
                env["DYLD_LIBRARY_PATH"] = shim.path
            }
            process.environment = env
        }

        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(packagesTimeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }

            if process.isRunning {
                process.terminate()
                return .packagesMissing(["faster-whisper", "pyannote.audio"])
            }

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                var missing: [String] = []
                if errorOutput.contains("faster_whisper") {
                    missing.append("faster-whisper")
                }
                if errorOutput.contains("pyannote") {
                    missing.append("pyannote.audio")
                }

                if missing.isEmpty {
                    missing = ["faster-whisper", "pyannote.audio"]
                }

                return .packagesMissing(missing)
            }

            return .packages()
        } catch {
            return .packagesMissing(["faster-whisper", "pyannote.audio"])
        }
    }

    private func checkFFmpeg() -> RequirementCheck {
        // Check common paths first
        let commonPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]

        for path in commonPaths {
            if isFFmpegValid(path) {
                return .ffmpeg()
            }
        }

        // Try which via login shell
        if let ffmpegPath = getFFmpegFromShell() {
            if isFFmpegValid(ffmpegPath) {
                return .ffmpeg()
            }
        }

        return .ffmpegMissing()
    }

    private func isFFmpegValid(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }

            if process.isRunning {
                process.terminate()
                return false
            }

            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func getFFmpegFromShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which ffmpeg"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }

            if process.isRunning {
                process.terminate()
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        } catch {
            return nil
        }

        return nil
    }
}
