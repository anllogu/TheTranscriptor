import Foundation

enum WhisperModel: String, Codable, CaseIterable {
    case tiny
    case base
    case small
    case medium
    case largeV3 = "large-v3"

    var displayName: String {
        switch self {
        case .tiny:
            return "tiny: mínimo tamaño, ~40 MB, muy rápido"
        case .base:
            return "base: básico, ~140 MB, rápido"
        case .small:
            return "small: estándar, ~466 MB, equilibrado"
        case .medium:
            return "medium: alta calidad, ~1.5 GB, lento"
        case .largeV3:
            return "large-v3: máxima calidad, ~3 GB, muy lento sin GPU"
        }
    }

    var rawValue: String {
        switch self {
        case .tiny:
            return "tiny"
        case .base:
            return "base"
        case .small:
            return "small"
        case .medium:
            return "medium"
        case .largeV3:
            return "large-v3"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "tiny":
            self = .tiny
        case "base":
            self = .base
        case "small":
            self = .small
        case "medium":
            self = .medium
        case "large-v3":
            self = .largeV3
        default:
            return nil
        }
    }
}
