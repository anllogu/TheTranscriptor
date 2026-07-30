import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppState.self) private var appState

    private let allowedTypes: [UTType] = [.mpeg4Audio, .mpeg4Movie, .quickTimeMovie, .wav]
    private let allowedExtensions: Set<String> = ["m4a", "mp4", "mov", "wav"]

    @State private var isTargeted = false
    @State private var rejectedMessage: String?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Suelta un archivo de audio o vídeo")
                    .font(.title2.bold())

                Text("Formatos admitidos: .m4a, .mp4, .mov, .wav")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let rejectedMessage {
                    Text(rejectedMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return handle(url: url)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .padding(.horizontal, 40)

            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button("Elegir archivo…") {
                        showImporter = true
                    }
                    Button("Grabar con micrófono") {
                        appState.beginRecording(mode: .microphone)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.beginRecording(mode: .meeting)
                } label: {
                    Label("Grabar reunión (micro + sistema)", systemImage: "person.wave.2.fill")
                }
                .buttonStyle(.bordered)

                Text("Consejo: en reunión, usa cascos para evitar que el audio del sistema se cuele por el micrófono.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Spacer()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = handle(url: url)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                PrivacyBadge(isDownloading: false)
            }
        }
    }

    private func handle(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            rejectedMessage = "Formato \".\(ext)\" no admitido."
            return false
        }
        rejectedMessage = nil
        appState.runPipeline(input: url)
        return true
    }
}
