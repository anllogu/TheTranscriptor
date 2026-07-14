import Foundation

/// Registro persistido de una transcripción completada — ver
/// `HistoryStore` para el almacenamiento (un fichero JSON por entrada en
/// `Application Support/TheTranscriptor/history/`).
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let sourceFileName: String
    /// Ruta del audio original en el momento de transcribir; puede haber
    /// dejado de existir (se borró o se movió) — no se copia el audio al
    /// historial, así que su presencia se comprueba en tiempo real.
    let sourceAudioPath: String?
    let whisperModel: String
    var transcript: Transcript

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceFileName: String,
        sourceAudioPath: String?,
        whisperModel: String,
        transcript: Transcript
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.sourceAudioPath = sourceAudioPath
        self.whisperModel = whisperModel
        self.transcript = transcript
    }
}
