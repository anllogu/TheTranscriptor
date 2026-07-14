import Foundation
import SwiftUI

class SettingsStore: ObservableObject {
    @AppStorage("whisperModel") var whisperModel: String = WhisperModel.small.rawValue
    @AppStorage("deleteAudioAfter") var deleteAudioAfter: Bool = false
    @AppStorage("pythonPath") var pythonPath: String = ""
    /// Días de retención del historial de transcripciones; `0` = sin límite.
    @AppStorage("historyRetentionDays") var historyRetentionDays: Int = 0

    func getWhisperModel() -> WhisperModel {
        WhisperModel(rawValue: whisperModel) ?? .small
    }

    func setWhisperModel(_ model: WhisperModel) {
        whisperModel = model.rawValue
    }
}
