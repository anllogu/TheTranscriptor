# Plan — Fase 5 (Ajustes, requisitos y privacidad) + Fase 6 (Exportación y pulido final)

> Documento autosuficiente: se puede ejecutar leyendo solo esto más
> `01-funcional.md`, `02-diseno-tecnico.md`, `03-faseado.md` y
> `docs/plans/02-plan-fase-4.md` (contexto de la implementación adelantada).

## 1. Punto de partida real (auditoría previa a este plan)

La Fase 4 se ejecutó "adelantada": además de grabación, construyó **toda** la
interfaz de un tirón, incluyendo buena parte de lo que Fases 5 y 6 pedían.
Auditoría del código actual, tarea por tarea del faseado:

| Tarea | Estado encontrado | Qué falta realmente |
|---|---|---|
| 5.1 Ajustes | `SettingsView.swift` ya tiene modelo Whisper, `SecureField`→Keychain, interruptor de borrado, ruta Python con Autodetectar/Examinar | Falta **verificar** (no implementar): token ausente de UserDefaults/logs, persistencia real entre reinicios |
| 5.2 Requisitos | `RequirementsView.swift` ya bloquea con checklist ✓/✗, botón "Reintentar", "Configurar automáticamente" (`PythonSetupService`), instrucciones copiables por check | Falta **verificar** con un caso real (ffmpeg renombrado/oculto del PATH) |
| 5.3 Privacidad | `PrivacyBadge` ya existe y está conectado a `downloading` en `ProcessingView` (vía `AppState.phase` → `@@INFO:downloading_models`); en `DropZoneView`/`ResultView` se pasa `isDownloading: false` fijo (correcto, ahí nunca se descarga) | Falta **verificar** visualmente con una descarga real de modelos (primera ejecución con modelo nuevo) |
| 5.4 Limpieza | `PythonPipelineService.purgeOrphanedWorkDirs()` (arranque), `cleanupWorkDir` en éxito/error/cancelación, `keepAudio` respeta el interruptor, `AudioRecorderService.cancelAndDelete()` borra WAV cancelado | Falta **auditoría en disco** de los 4 caminos con casos reales, documentada |
| 6.1 Renombrado | `Transcript.setSpeakerName` ya propaga a `ResultView` (UI), y como usa `TxtExporter`/`SrtExporter` sobre el mismo `transcript` con nombres aplicados, ya se propaga a exportaciones | Falta **verificar** que exportar tras renombrar usa el nombre nuevo, no `SPEAKER_00` |
| 6.2 Copiar/exportar | `ResultView` ya tiene botones Copiar/.txt/.srt con `NSSavePanel` funcionando | Falta **verificar** que los archivos abren bien en TextEdit/VLC |
| 6.3 Pulido | Solo existe ⌘N (`DropZoneView.swift:57`). No hay ⌘, explícito (macOS lo da gratis en `Settings` scene, pero falta confirmar), no hay ⌘C en `ResultView`, no hay estados vacíos cuidados, no hay revisión de modo oscuro, tamaños de ventana solo tienen `minWidth`/`minHeight` en `MainView` (480×420), sin `defaultSize` ni `windowResizability` | **Todo esto es trabajo real pendiente** |
| 6.4 Regresión E2E | No existe checklist documentada | **Todo esto es trabajo real pendiente** |

**Conclusión:** Fase 5 es, en un ~90%, trabajo de verificación con fixtures y
casos reales (poco código nuevo, si acaso arreglos puntuales que la
verificación destape). Fase 6 tiene una parte de verificación (6.1, 6.2) y
una parte de implementación real y acotada (6.3 pulido, 6.4 checklist).

## 2. Alcance de este plan

- No se reabren 5.1–5.4 como si no existieran: se ejecutan como **sesiones de
  verificación dirigida** contra la app ya construida, con corrección
  puntual si la verificación encuentra un defecto real (no refactor
  preventivo).
- 6.1 y 6.2 igual: verificación, no reimplementación.
- 6.3 es la única tarea con diseño de UI nuevo (atajos, estados vacíos,
  modo oscuro, tamaños de ventana) — se detalla en la sección 4.
- 6.4 produce un documento de checklist ejecutado y firmado en verde.

## 3. Orden de ejecución

1. **Verificación 5.1–5.4** (build ya en verde de la Fase 4; no se toca
   código salvo bugs encontrados).
2. **Verificación 6.1–6.2** (mismo criterio).
3. **Implementación 6.3** (único bloque con cambios de código planificados
   de antemano).
4. **6.4**: checklist de regresión E2E ejecutada tras 6.3, con los 3
   fixtures de audio de la Fase 1 + grabación en vivo + cancelaciones (drop,
   grabación, pipeline).

Cada bloque termina con `xcodebuild -scheme TheTranscriptor build` (y `test`
si el bloque tocó código) en verde antes de pasar al siguiente.

## 4. Diseño detallado — 6.3 Pulido

### 4.1 Atajos de teclado

| Atajo | Acción | Dónde | Cómo |
|---|---|---|---|
| ⌘N | Nueva transcripción / volver a `.idle` | Global (menú + vista) | Ya existe en `DropZoneView` para "elegir archivo"; añadir también `.keyboardShortcut("n", modifiers: .command)` al botón "Nueva transcripción" de `ResultView` y de `ErrorView` (ambos deben poder reiniciar con ⌘N) |
| ⌘, | Abrir Ajustes | Automático | Ya lo provee `Settings { }` scene de SwiftUI sin código adicional — **solo verificar**, no implementar |
| ⌘C | Copiar transcripción | `ResultView` | Añadir `.keyboardShortcut("c", modifiers: .command)` al botón "Copiar". **Ojo:** si el usuario tiene texto seleccionado en la `List` (selección nativa de texto vía `.textSelection`), ⌘C del sistema para copiar selección debe seguir funcionando — el atajo del botón solo debe disparar cuando el botón tiene foco/no hay selección de texto activa. Verificar que no haya conflicto; si lo hay, limitar el atajo a cuando el botón está enfocado (comportamiento por defecto de `keyboardShortcut` en SwiftUI, que no captura sobre `NSTextView` con selección activa) |

### 4.2 Estados vacíos

- `ResultView` cuando `transcript.segments.isEmpty` (caso límite: audio sin
  voz detectada): mostrar mensaje central "No se detectó ningún segmento de
  voz en este audio" en vez de una `List` vacía sin contexto.
- `RequirementsView` cuando `checks.isEmpty` ya tiene `ProgressView` — está
  bien, no es un estado vacío real sino de carga.

### 4.3 Modo oscuro

- Revisión visual manual (no hay lógica condicional que romper: todas las
  vistas usan `Color.secondary`, `.foregroundStyle`, colores del sistema —
  no hay colores hardcodeados tipo `Color.white`/`Color.black` a
  auditar). Grep de confirmación: `grep -rn "Color\.\(white\|black\)\|#[0-9a-fA-F]\{6\}"`
  sobre `Views/` antes de dar por bueno.
- Único punto de atención conocido: `RequirementsView` usa
  `Color.secondary.opacity(0.1)` como fondo de bloque de instrucción — en
  modo oscuro puede quedar con poco contraste sobre el texto monospaced;
  verificar visualmente y subir opacidad si hace falta.

### 4.4 Tamaños de ventana

- `MainView` tiene `.frame(minWidth: 480, minHeight: 420)` pero la `WindowGroup`
  no fija `defaultSize` — en la primera apertura macOS puede escoger un
  tamaño arbitrario. Añadir `.windowResizability(.contentSize)` o un
  `defaultSize` explícito en `TheTranscriptorApp.swift` para que la ventana
  abra en un tamaño cómodo (p. ej. 560×480) y respete el mínimo ya fijado.
- `SettingsView` ya tiene `.frame(width: 420)` fijo — está bien para una
  ventana de ajustes, no requiere cambio.

## 5. Diseño detallado — 6.4 Checklist de regresión E2E

Documento nuevo `docs/plans/checklist-regresion-e2e.md` (o sección al final
de este plan tras ejecutarlo) con, como mínimo:

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
- [ ] Modo oscuro: recorrido visual completo de las 6 vistas principales
- [ ] ⌘N, ⌘,, ⌘C funcionan en sus contextos esperados

## 6. Criterios de aceptación

- Fase 5: las 4 tareas de la tabla de `03-faseado.md` demostradas contra la
  app real (no simulada), con cualquier defecto encontrado corregido y
  re-verificado.
- Fase 6: 6.1–6.2 verificadas; 6.3 implementada y visible en un recorrido
  manual; 6.4 checklist completa en verde, documentada en
  `docs/plans/checklist-regresion-e2e.md`.
- `xcodebuild -scheme TheTranscriptor build` y `test` en verde al cierre de
  cada bloque de la sección 3.

## 7. Límite de verificación de esta sesión

Como en la Fase 4, gran parte de 5.1–5.4, 6.1–6.2 y toda la 6.4 requieren
interacción real con hardware (micrófono), Ajustes del Sistema (permisos),
apps externas (TextEdit, VLC) y descargas reales de modelos desde Hugging
Face — nada de esto es accionable por un agente sin control del Mac del
usuario. El agente puede: implementar 6.3 y demostrar build/test en verde,
dejar la checklist de 6.4 redactada y lista para ejecutar, y hacer las
verificaciones de código estático que no requieren el Mac (greps de
colores hardcodeados, lectura de UserDefaults/Keychain en el código, lógica
de limpieza). El resto de las casillas de la checklist las debe marcar el
usuario tras probar en su máquina.
