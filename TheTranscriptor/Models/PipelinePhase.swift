import Foundation

enum PipelinePhase: String, Codable, CaseIterable, Equatable {
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

    var checklistTitle: String {
        switch self {
        case .converting:
            return "Convertir audio"
        case .transcribing:
            return "Transcribir"
        case .diarizing:
            return "Diarizar"
        case .merging:
            return "Unir resultados"
        }
    }
}
