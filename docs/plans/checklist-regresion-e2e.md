# Checklist de regresión E2E — Fase 5 + 6

> Generada al ejecutar `docs/plans/03-plan-fase-5-6.md`. Requiere interacción
> real con hardware (micrófono), Ajustes del Sistema (permisos), apps
> externas (TextEdit, VLC) y descargas de modelos desde Hugging Face — nada
> de esto es accionable por un agente sin control del Mac del usuario (ver
> §7 del plan). El agente dejó el documento redactado y las verificaciones
> estáticas hechas; el usuario debe marcar el resto tras probar en su
> máquina.

## Verificaciones estáticas ya realizadas por el agente

- [x] `xcodebuild -scheme TheTranscriptor build` en verde
- [x] `xcodebuild -scheme TheTranscriptor test` en verde (49 tests)
- [x] Token HF: no aparece en `SettingsStore`/`UserDefaults`, solo en
      `KeychainService` (`Keychain` con `kSecAttrAccessibleWhenUnlocked`);
      no se pasa como argumento CLI, solo vía `HF_TOKEN` env var
      (`PythonPipelineService.runPipeline`)
- [x] `RequirementsView` bloquea con checklist ✓/✗, "Reintentar" y
      "Configurar automáticamente" ya implementados
- [x] `PrivacyBadge` conectado a `downloading` solo en `ProcessingView`;
      `DropZoneView`/`ResultView` pasan `isDownloading: false` fijo (correcto)
- [x] Limpieza: `purgeOrphanedWorkDirs()` en arranque (`TheTranscriptorApp.swift`),
      `cleanupWorkDir` en `process.terminationHandler` (cubre éxito, error,
      cancelación y crash: se ejecuta siempre que el proceso termina),
      `keepAudio = !settings.deleteAudioAfter` respeta el interruptor,
      `AudioRecorderService.cancelAndDelete()` borra el WAV cancelado
- [x] `Transcript.setSpeakerName` muta el mismo `transcript` que consumen
      `TxtExporter`/`SrtExporter`/`copyToClipboard` en `ResultView` → el
      renombrado se propaga a las tres salidas
- [x] Grep de colores hardcodeados en `Views/`: sin coincidencias
- [x] Atajos ⌘N (`ResultView` "Nueva transcripción", `ErrorView`
      "Reintentar", ya existía en `DropZoneView` "Grabar con micrófono") y
      ⌘C (`ResultView` "Copiar") añadidos; ⌘, lo provee gratis la escena
      `Settings { }` de SwiftUI
- [x] Estado vacío en `ResultView` cuando `transcript.segments.isEmpty`
- [x] `TheTranscriptorApp.swift`: `.defaultSize(width: 560, height: 480)`
      añadido a la `WindowGroup`
- [x] Contraste del bloque de instrucciones en `RequirementsView` subido de
      `Color.secondary.opacity(0.1)` a `0.2` para modo oscuro
- [x] `WindowGroup` añade automáticamente "Nueva ventana" (⌘N) al menú
      Archivo, lo que competía con el ⌘N de las vistas; se ha suprimido con
      `.commands { CommandGroup(replacing: .newItem) { } }` en
      `TheTranscriptorApp.swift`

## Pendiente de ejecución manual por el usuario

- [ ] Fixture `.m4a` (nota de voz) → transcripción correcta con ≥2 hablantes
- [ ] Fixture `.mp4` (Zoom) → transcripción correcta
- [ ] Fixture `.wav` → transcripción correcta
- [ ] Grabación en vivo (≥30s, 2 personas si es posible) → transcripción correcta
- [ ] Cancelar un `DropZoneView` a medio drag (soltar fuera) → no rompe estado
- [ ] Cancelar grabación a medio grabar → WAV borrado en disco (verificado con `ls`)
- [ ] Cancelar pipeline a medio procesar (botón cancelar en `ProcessingView`) → proceso hijo muere (verificado con `ps`), `work/<UUID>/` limpiado
- [ ] Renombrar hablante en `ResultView` → se refleja en Copiar, .txt y .srt
- [ ] Exportar .txt → abre correctamente en TextEdit
- [ ] Exportar .srt → abre correctamente en VLC con subtítulos sincronizados
- [ ] Revocar permiso de micrófono en Ajustes del Sistema → la app lo detecta y ofrece enlace
- [ ] Renombrar/ocultar `ffmpeg` del PATH → `RequirementsView` bloquea y muestra instrucción copiable
- [ ] Interruptor "Borrar audio original" activado → el archivo original desaparece tras éxito; desactivado → sobrevive
- [ ] Purga de huérfanos: dejar un `work/<UUID>/` a mano, reiniciar la app → desaparece al arrancar
- [ ] Descarga real de modelos (primera ejecución con modelo nuevo) → `PrivacyBadge` visible durante la descarga en `ProcessingView`
- [ ] Modo oscuro: recorrido visual completo de las 6 vistas principales (`DropZoneView`, `RecordingView`, `RequirementsView`, `ProcessingView`, `ResultView`, `ErrorView`)
- [ ] ⌘N funciona en `DropZoneView` (empieza grabación — no vuelve a `.idle`
      porque ya está ahí; es la única vista donde ⌘N no significa "nueva
      transcripción" sino "grabar", discrepancia heredada de la Fase 4 que
      se mantiene deliberadamente), `ResultView` y `ErrorView` (vuelven a
      `.idle`); ⌘, abre Ajustes; ⌘C copia la transcripción **sin** abrir una
      ventana nueva (era el comportamiento por defecto de `WindowGroup`,
      corregido con `CommandGroup(replacing: .newItem)` — si aun así se ve
      "Nueva ventana" en el menú Archivo o ⌘N no dispara el botón, es la
      señal de que la colisión no quedó resuelta) y sin interferir con la
      selección nativa de texto en la `List` (si seleccionas texto en un
      segmento y ⌘C copia toda la transcripción en vez de la selección, es
      el conflicto que anticipa §4.1 del plan — solución: limitar el
      `.keyboardShortcut` al botón enfocado o quitarlo y depender solo del
      menú Edit)
