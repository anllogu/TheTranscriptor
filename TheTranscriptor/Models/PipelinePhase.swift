import Foundation

enum PipelinePhase: String, Codable, Equatable {
    case converting = "CONVERTING"
    case transcribing = "TRANSCRIBING"
    case diarizing = "DIARIZING"
    case merging = "MERGING"

    var displayName: String {
        switch self {
        case .converting:
            return "Convirtiendo audio…"
        case .transcribing:
            return "Transcribiendo…"
        case .diarizing:
            return "Diarizando…"
        case .merging:
            return "Uniendo resultados…"
        }
    }
}
