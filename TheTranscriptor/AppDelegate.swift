import AppKit

/// App solo de bandeja (CU-10 / §4.8): al lanzar dejamos la app en
/// `.accessory` para que **no** aparezca en el Dock ni tenga barra de menús de
/// aplicación; solo vive en la barra de estado (el `MenuBarExtra`). Cuando se
/// abre una ventana de contenido (principal, historial, registro o ajustes) se
/// pasa a `.regular` para que tenga icono en el Dock y pueda recibir foco, y se
/// vuelve a `.accessory` al cerrarse todas.
///
/// `LSUIElement=true` en el Info.plist arranca ya sin Dock; este delegate
/// gestiona el vaivén posterior según haya o no ventanas visibles.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowStateChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowStateChanged(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowStateChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(excluding: nil)
        }
    }

    @objc private func windowWillClose(_ note: Notification) {
        // La ventana que se cierra sigue en `NSApp.windows` (y `isVisible`) en
        // el instante de la notificación; hay que excluirla del recuento.
        let closing = note.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(excluding: closing)
        }
    }

    private func updateActivationPolicy(excluding excluded: NSWindow?) {
        let hasContentWindow = NSApp.windows.contains { window in
            window !== excluded
                && window.isVisible
                && window.canBecomeMain
                && !(window is NSPanel)
        }
        let target: NSApplication.ActivationPolicy = hasContentWindow ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }
}
