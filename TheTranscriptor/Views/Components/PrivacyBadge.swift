import SwiftUI

struct PrivacyBadge: View {
    let isDownloading: Bool

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: isDownloading ? "exclamationmark.triangle.fill" : "lock.fill")
                .foregroundStyle(isDownloading ? .orange : .green)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isDownloading ? "Descargando modelos" : "Todo procesado localmente")
                    .font(.headline)
                Text(isDownloading
                     ? "Se está descargando un modelo desde Hugging Face. Es la única conexión de red que hace esta app, y solo ocurre la primera vez que usas un modelo."
                     : "El audio y la transcripción nunca salen de este Mac. La app no hace peticiones de red propias.")
                    .font(.callout)
                    .frame(maxWidth: 260)
            }
            .padding()
        }
        .help(isDownloading ? "Descargando modelos desde Hugging Face" : "Procesamiento 100% local")
    }
}
