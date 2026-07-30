import Foundation

/// Idioma de entrada para la transcripción. `auto` deja que faster-whisper
/// autodetecte el idioma (comportamiento histórico); el resto lo fuerza vía el
/// argumento `--language` del script (contrato §3), lo que mejora la exactitud
/// cuando la autodetección se equivoca (p. ej. audio en español detectado como
/// euskera). Ampliar la lista es trivial: añadir casos aquí.
enum TranscriptionLanguage: String, Codable, CaseIterable {
    case auto
    case spanish = "es"
    case english = "en"

    var displayName: String {
        switch self {
        case .auto:
            return "Automático (detectar)"
        case .spanish:
            return "Español"
        case .english:
            return "Inglés"
        }
    }
}
