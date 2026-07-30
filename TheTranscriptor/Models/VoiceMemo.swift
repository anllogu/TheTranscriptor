import Foundation

/// Una nota de voz descubierta en la biblioteca local de la app Notas de voz
/// de macOS (`~/Library/Group Containers/group.com.apple.VoiceMemos.shared/`).
/// La produce `VoiceMemosService`, ya sea leyendo `CloudRecordings.db` (título,
/// fecha y duración reales) o, como red de seguridad, enumerando los `.m4a` de
/// la carpeta `Recordings/` (nombre de fichero y fecha de creación).
struct VoiceMemo: Identifiable, Hashable {
    /// Estado de disponibilidad del fichero. Con iCloud activo, los `.m4a`
    /// pueden estar evacuados (placeholders de 0 bytes) y hay que forzar su
    /// descarga antes de transcribir.
    enum DownloadState: Hashable {
        /// El fichero está materializado en disco y listo para usarse.
        case downloaded
        /// El fichero está evacuado a iCloud; hay que descargarlo primero.
        case notDownloaded
        /// La descarga está en curso.
        case downloading
    }

    let id: String
    let title: String
    let date: Date?
    /// Duración en segundos, si se conoce (de la BD). `nil` en el fallback.
    let duration: TimeInterval?
    /// Ruta del `.m4a` en la biblioteca de Notas de voz. Nunca se transcribe
    /// directamente: `VoiceMemosService.copyForTranscription` hace una copia
    /// temporal para no arriesgar la biblioteca del usuario.
    let url: URL
    var downloadState: DownloadState
}
