import Foundation

class PythonEnvironmentDetector {
    func detectPythonPath(savedPath: String? = nil, venvPath: String? = nil) -> String? {
        // 1. Try user's saved path first
        if let saved = savedPath, !saved.isEmpty, isPythonValid(saved) {
            return saved
        }

        // 2. Try .venv or venv directories relative to a base path
        if let basePath = venvPath {
            let venvPaths = [
                "\(basePath)/.venv/bin/python3",
                "\(basePath)/venv/bin/python3"
            ]
            for path in venvPaths {
                if isPythonValid(path) {
                    return path
                }
            }
        }

        // 3. Try common installation paths
        let commonPaths = [
            "~/.pyenv/shims/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for path in commonPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if isPythonValid(expandedPath) {
                return expandedPath
            }
        }

        // 4. Try system's which command via login shell
        if let whichPath = getPythonFromShell() {
            if isPythonValid(whichPath) {
                return whichPath
            }
        }

        return nil
    }

    private func isPythonValid(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import sys; print(sys.version)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            // Set a timeout
            let deadline = Date().addingTimeInterval(10.0)
            while process.isRunning && Date() < deadline {
                usleep(100_000) // 100ms
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

    private func getPythonFromShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which -a python3"]

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

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.split(separator: "\n").first.map(String.init)
            }
        } catch {
            return nil
        }

        return nil
    }
}
