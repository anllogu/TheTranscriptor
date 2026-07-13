import XCTest
@testable import TheTranscriptor

final class PythonPipelineServiceTests: XCTestCase {
    var service: PythonPipelineService!
    var tempDir: URL!
    var inputFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = PythonPipelineService()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonPipelineServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        inputFile = tempDir.appendingPathComponent("input.wav")
        try Data("fake audio bytes".utf8).write(to: inputFile)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func systemPython3() -> String {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/python3"
    }

    private func fixtureScriptURL() -> URL {
        // #filePath points at .../TheTranscriptorTests/PythonPipelineServiceTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // TheTranscriptorTests/
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("Tests/Fixtures/fake_pipeline.py")
    }

    private func makeSettings(slow: Bool = false, keepAudio: Bool = false) -> PipelineSettings {
        PipelineSettings(
            pythonPath: systemPython3(),
            scriptPath: fixtureScriptURL(),
            model: .small,
            keepAudio: keepAudio,
            hfToken: nil,
            extraArguments: slow ? ["--slow"] : []
        )
    }

    // MARK: - Tests

    func testFullEventSequenceAndResultDecoding() async throws {
        let settings = makeSettings()
        var events: [PythonPipelineService.Event] = []

        for await event in service.run(input: inputFile, settings: settings) {
            events.append(event)
        }

        guard case .done(let resultURL) = events.last else {
            return XCTFail("Expected last event to be .done, got: \(events)")
        }

        XCTAssertEqual(Array(events.dropLast()), [
            .phase(.converting),
            .phase(.transcribing),
            .progress(50),
            .downloadingModels,
            .phase(.diarizing),
            .phase(.merging)
        ])

        XCTAssertEqual(resultURL.lastPathComponent, "result.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))

        let data = try Data(contentsOf: resultURL)
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)

        XCTAssertEqual(transcript.language, "es")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments.first?.speaker, "SPEAKER_00")
    }

    func testUnprefixedStdoutLineIsIgnored() async throws {
        // The fixture prints "ruido de libreria" (no @@ prefix) between
        // PROGRESS and INFO:downloading_models. It must not produce an
        // event nor break parsing of the following lines.
        let settings = makeSettings()
        var events: [PythonPipelineService.Event] = []

        for await event in service.run(input: inputFile, settings: settings) {
            events.append(event)
        }

        // downloadingModels must still be observed right after progress,
        // proving the noisy line was skipped rather than breaking the parser.
        XCTAssertTrue(events.contains(.downloadingModels))
        XCTAssertTrue(events.contains(.progress(50)))

        if let progressIndex = events.firstIndex(of: .progress(50)),
           let downloadIndex = events.firstIndex(of: .downloadingModels) {
            XCTAssertLessThan(progressIndex, downloadIndex)
        } else {
            XCTFail("Expected both .progress(50) and .downloadingModels events")
        }

        // No unexpected/failed events should have been produced.
        for event in events {
            if case .failed = event {
                XCTFail("Unexpected .failed event from noisy stdout line: \(event)")
            }
        }
    }

    func testCancelTerminatesProcessAndCleansWorkDir() async throws {
        let settings = makeSettings(slow: true)
        let stream = service.run(input: inputFile, settings: settings)

        var iterator = stream.makeAsyncIterator()

        // Drain events until we've seen TRANSCRIBING + PROGRESS(50), which is
        // when the fixture sleeps for several seconds (--slow), giving us a
        // window to cancel mid-flight.
        var sawTranscribing = false
        while let event = await iterator.next() {
            if case .progress(50) = event {
                sawTranscribing = true
                break
            }
        }
        XCTAssertTrue(sawTranscribing, "Expected to observe progress(50) before cancelling")

        guard let pid = service.lastProcessIdentifier else {
            return XCTFail("Expected service to expose the child PID")
        }
        // kill(pid, 0) only checks for existence/permission, it does not
        // actually signal the process. ESRCH means "no such process".
        XCTAssertEqual(kill(pid, 0), 0, "Fixture process should still be alive before cancelling")

        // Locate the live workdir created for this run before cancelling.
        let workRoot = PythonPipelineService.applicationSupportDirectory()
            .appendingPathComponent("work", isDirectory: true)
        let workDirsBeforeCancel = (try? FileManager.default.contentsOfDirectory(
            at: workRoot, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(workDirsBeforeCancel.isEmpty, "Expected a workdir to exist while the pipeline is running")
        let runWorkDir = workDirsBeforeCancel.first

        service.cancel()

        // Drain the rest of the stream; it should finish promptly without
        // ever reaching @@DONE.
        var receivedDoneAfterCancel = false
        while let event = await iterator.next() {
            if case .done = event {
                receivedDoneAfterCancel = true
            }
        }
        XCTAssertFalse(receivedDoneAfterCancel, "Stream should not report .done after cancellation")

        // Verify the OS process is actually gone (not just that our stream
        // stopped emitting events).
        let pidDeadline = Date().addingTimeInterval(6)
        var pidAlive = kill(pid, 0) == 0
        while pidAlive && Date() < pidDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            pidAlive = kill(pid, 0) == 0
        }
        XCTAssertFalse(pidAlive, "Fixture process (pid \(pid)) should have been terminated by cancel()")

        // Give the OS a brief moment to finalize process teardown, then
        // verify the workdir was cleaned up.
        if let runWorkDir {
            let deadline = Date().addingTimeInterval(3)
            var exists = FileManager.default.fileExists(atPath: runWorkDir.path)
            while exists && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                exists = FileManager.default.fileExists(atPath: runWorkDir.path)
            }
            XCTAssertFalse(exists, "Workdir should be removed after cancellation: \(runWorkDir.path)")
        }
    }

    func testKeepAudioPreservesInputFile() async throws {
        let settings = makeSettings(keepAudio: true)

        for await _ in service.run(input: inputFile, settings: settings) {
            // Drain the stream fully.
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: inputFile.path), "Input file should be preserved with --keep-audio")
    }

    func testWithoutKeepAudioDeletesInputFile() async throws {
        let settings = makeSettings(keepAudio: false)

        for await _ in service.run(input: inputFile, settings: settings) {
            // Drain the stream fully.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: inputFile.path), "Input file should be deleted without --keep-audio")
    }
}
