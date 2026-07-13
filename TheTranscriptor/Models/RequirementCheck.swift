import Foundation

struct RequirementCheck: Identifiable {
    let id = UUID()
    let name: String
    let status: Status

    enum Status: Equatable {
        case ok
        case missing(instruction: String)

        var isOk: Bool {
            switch self {
            case .ok:
                return true
            case .missing:
                return false
            }
        }
    }

    init(name: String, status: Status) {
        self.name = name
        self.status = status
    }

    static func ffmpeg() -> RequirementCheck {
        RequirementCheck(name: "ffmpeg", status: .ok)
    }

    static func ffmpegMissing() -> RequirementCheck {
        RequirementCheck(
            name: "ffmpeg",
            status: .missing(instruction: "brew install ffmpeg")
        )
    }

    static func python(version: String) -> RequirementCheck {
        RequirementCheck(name: "Python \(version)", status: .ok)
    }

    static func pythonMissing() -> RequirementCheck {
        RequirementCheck(
            name: "Python",
            status: .missing(instruction: "Instala Python 3.8+: https://www.python.org/downloads/")
        )
    }

    static func packages() -> RequirementCheck {
        RequirementCheck(name: "Paquetes (faster-whisper, pyannote.audio)", status: .ok)
    }

    static func packagesMissing(_ missing: [String]) -> RequirementCheck {
        let packages = missing.joined(separator: " ")
        return RequirementCheck(
            name: "Paquetes (faster-whisper, pyannote.audio)",
            status: .missing(instruction: "pip install \(packages)")
        )
    }

    static func huggingFaceToken() -> RequirementCheck {
        RequirementCheck(name: "Token Hugging Face", status: .ok)
    }

    static func huggingFaceTokenMissing() -> RequirementCheck {
        RequirementCheck(
            name: "Token Hugging Face",
            status: .missing(instruction: "Crea un token en https://huggingface.co/settings/tokens y configúralo en Ajustes (opcional para la primera descarga de modelos)")
        )
    }
}
