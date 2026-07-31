import XCTest
@testable import TheTranscriptor

/// Cubre la lógica pura de relleno de silencio que mantiene fiel la línea de
/// tiempo del WAV del sistema (ver `SystemAudioRecorderService`), sin necesidad
/// de Core Audio: el *process tap* del sistema no entrega buffers durante el
/// silencio, así que se rellena el hueco entre la posición esperada (tiempo
/// transcurrido) y la realmente escrita.
final class SystemAudioRecorderServiceTests: XCTestCase {
    // A 16 kHz, 0.25 s de umbral = 4000 frames.
    private let threshold: Int64 = 4_000

    func testNoGapWhenWrittenMatchesExpected() {
        // Sonido continuo: lo escrito va al ritmo de lo esperado → sin relleno.
        let gap = SystemAudioRecorderService.silenceGapFrames(
            expectedStartFrames: 16_000,
            writtenFrames: 16_000,
            thresholdFrames: threshold
        )
        XCTAssertEqual(gap, 0)
    }

    func testSmallGapBelowThresholdIsIgnored() {
        // Jitter normal de callback (< 0.25 s) no debe generar relleno.
        let gap = SystemAudioRecorderService.silenceGapFrames(
            expectedStartFrames: 16_000 + 1_000,
            writtenFrames: 16_000,
            thresholdFrames: threshold
        )
        XCTAssertEqual(gap, 0)
    }

    func testLeadingSilenceIsFilled() {
        // Primer buffer llega en el segundo 30: nada escrito aún → 30 s de relleno.
        let expected: Int64 = 30 * 16_000
        let gap = SystemAudioRecorderService.silenceGapFrames(
            expectedStartFrames: expected,
            writtenFrames: 0,
            thresholdFrames: threshold
        )
        XCTAssertEqual(gap, expected)
    }

    func testIntermediateGapIsFilled() {
        // Hueco intermedio: esperado 10 s, escrito 5 s → 5 s de relleno.
        let gap = SystemAudioRecorderService.silenceGapFrames(
            expectedStartFrames: 10 * 16_000,
            writtenFrames: 5 * 16_000,
            thresholdFrames: threshold
        )
        XCTAssertEqual(gap, 5 * 16_000)
    }

    func testNegativeGapIsClampedToZero() {
        // Si lo escrito supera lo esperado (buffer que llega antes de tiempo),
        // nunca se recorta ni se escribe silencio negativo.
        let gap = SystemAudioRecorderService.silenceGapFrames(
            expectedStartFrames: -800,
            writtenFrames: 0,
            thresholdFrames: threshold
        )
        XCTAssertEqual(gap, 0)
    }

    func testGapExactlyAtThresholdIsFilled() {
        let gap = SystemAudioRecorderService.silenceGapFrames(
            expectedStartFrames: threshold,
            writtenFrames: 0,
            thresholdFrames: threshold
        )
        XCTAssertEqual(gap, threshold)
    }
}
