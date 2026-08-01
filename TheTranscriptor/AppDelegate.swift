import AppKit

/// Bandeja al cerrar la ventana (CU-10 / §4.8): la app arranca como una app
/// normal, con la ventana principal visible y el icono en el Dock
/// (activation policy `.regular`, la que trae el sistema por defecto). Este
/// delegate solo gestiona el vaivén posterior: cuando se cierran todas las
/// ventanas de contenido (principal, historial, registro o ajustes) pasa a
/// `.accessory` para que la app siga viva únicamente en la barra de estado
/// (el `MenuBarExtra`), sin Dock; en cuanto vuelve a haber una ventana visible
/// se recupera `.regular`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
