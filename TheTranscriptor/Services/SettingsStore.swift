import Foundation
import SwiftUI

class SettingsStore: ObservableObject {
    @AppStorage("whisperModel") var whisperModel: String = WhisperModel.small.rawValue
    @AppStorage("deleteAudioAfter") var deleteAudioAfter: Bool = true
    @AppStorage("pythonPath") var pythonPath: String = ""

    func getWhisperModel() -> WhisperModel {
        WhisperModel(rawValue: whisperModel) ?? .small
    }

    func setWhisperModel(_ model: WhisperModel) {
        whisperModel = model.rawValue
    }
}
