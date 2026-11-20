import XCTest
@testable import Muesli

/// Drives `KeyboardController`'s in-keyboard dictation path with a fake engine,
/// so WebKit capture and Apple Speech are out of the loop.
@MainActor
final class InKeyboardDictationTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var controller: KeyboardController!
    private var engine: FakeInKeyboardDictation!
    private var insertedText: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("in-keyboard-dictation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bus = SilentEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        engine = FakeInKeyboardDictation()
        controller.inKeyboardDictation = engine
        controller.currentFullAccess = { true }
        insertedText = []
        controller.textInserter = { [weak self] text in self?.insertedText.append(text) }
        controller.prepareInitialPresentationState()
    }

    override func tearDown() async throws {
        controller = nil
        engine = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testUnavailableEngineFallsBackToMuesliHandoff() throws {
        engine.availability = .needsSpeechPermission
        controller.refreshInKeyboardAvailability()
        XCTAssertTrue(controller.opensMuesliFromPrimaryButton)

        controller.startDictation()

        XCTAssertEqual(engine.startCount, 0)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.dictationPhase, .requested)
        XCTAssertNotNil(try store.keyboardHandoffState().requestID, "handoff claimed a request")
    }

    func testAvailableEngineRecordsInKeyboardWithoutOpeningMuesli() throws {
        controller.refreshInKeyboardAvailability()
        XCTAssertFalse(controller.opensMuesliFromPrimaryButton, "Record must not be a Link to Muesli")

        controller.startDictation()

        XCTAssertEqual(engine.startCount, 1)
        XCTAssertTrue(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.primaryButtonRole, .stop)
        XCTAssertNil(try store.keyboardHandoffState().requestID, "no handoff request is claimed")
    }

    func testPartialThenFinalInsertsTranscriptAndSavesHistoryOnly() throws {
        controller.startDictation()
        engine.handlers?.onListening()
        engine.handlers?.onPartial("Hello")
        XCTAssertEqual(controller.liveTranscript, "Hello")
        XCTAssertTrue(controller.showsLiveTranscript)
        XCTAssertTrue(insertedText.isEmpty, "partials are shown, not typed")

        controller.primaryAction()
        XCTAssertEqual(engine.finishCount, 1)
        XCTAssertEqual(controller.dictationPhase, .transcribing)

        engine.handlers?.onCompleted("  Hello world  ")

        XCTAssertEqual(insertedText, ["Hello world"])
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.statusText, "Inserted")
        let saved = try XCTUnwrap(store.resultsHistory().first)
        XCTAssertEqual(saved.text, "Hello world")
        XCTAssertEqual(saved.engineIdentifier, InKeyboardDictationSession.engineIdentifier)
        XCTAssertTrue(try store.pendingKeyboardDeliveries().isEmpty)
        XCTAssertNil(try store.status().requestID, "app dictation status is untouched")

        controller.prepareInitialPresentationState()
        XCTAssertEqual(insertedText, ["Hello world"], "a refresh never re-inserts")
    }

    func testEmptyFinalInsertsNothing() throws {
        controller.startDictation()
        controller.primaryAction()
        engine.handlers?.onCompleted("   ")

        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertEqual(controller.statusText, "No speech heard")
        XCTAssertTrue(try store.resultsHistory().isEmpty)
    }

    func testCancelDiscardsWithoutInserting() throws {
        controller.startDictation()
        engine.handlers?.onPartial("Never mind")

        controller.cancelActiveDictation()

        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertTrue(try store.resultsHistory().isEmpty)
    }

    func testFailureSettlesToFailedAndAllowsRetry() throws {
        controller.startDictation()
        engine.handlers?.onFailed("Speech unavailable")

        XCTAssertEqual(controller.dictationPhase, .failed)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)

        controller.primaryAction()
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertTrue(controller.isInKeyboardCaptureActive)
    }

    func testDismissingKeyboardReleasesMicAndKeepsSpeechInHistory() throws {
        controller.startDictation()
        engine.handlers?.onPartial("Half a thought")

        controller.stopObservingSharedState()

        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertFalse(controller.isInKeyboardCaptureActive)
        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertEqual(try store.resultsHistory().first?.text, "Half a thought")
    }

    func testRefreshDuringCaptureDoesNotAdoptAnAppRequest() throws {
        controller.startDictation()
        XCTAssertTrue(controller.isInKeyboardCaptureActive)

        // A recent finished status for an unrelated request would otherwise be
        // adopted by apply(status:) and flip the keyboard to .finished.
        try store.saveResult(.init(requestID: UUID(), text: "Elsewhere", engineIdentifier: "test"))
        controller.prepareInitialPresentationState()

        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertTrue(controller.isInKeyboardCaptureActive)
        XCTAssertTrue(insertedText.isEmpty)
    }

    func testLateCallbacksFromAnEndedCaptureAreIgnored() throws {
        controller.startDictation()
        let staleHandlers = engine.handlers
        controller.cancelActiveDictation()

        staleHandlers?.onCompleted("Late text")

        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertEqual(controller.dictationPhase, .idle)
    }

    func testPostProcessingRespectsMirroredFlagsAndTrims() throws {
        let suite = "in-keyboard-dictation-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let word = CustomWord(word: "Muesli")

        InKeyboardDictationPreferences.mirrorPostProcessing(
            fillerWordRemoval: false,
            customDictionary: false,
            in: defaults
        )
        XCTAssertEqual(
            InKeyboardDictationPreferences.postProcess(" museli rocks ", customWords: [word], defaults: defaults),
            "museli rocks"
        )
        XCTAssertFalse(InKeyboardDictationPreferences.isEnabled(in: defaults), "opt-in defaults to off")
    }
}

@MainActor
private final class FakeInKeyboardDictation: InKeyboardDictating {
    var availability: InKeyboardDictationAvailability = .available
    var handlers: InKeyboardDictationHandlers?
    var startCount = 0
    var finishCount = 0
    var cancelCount = 0

    func availability(hasFullAccess: Bool) -> InKeyboardDictationAvailability {
        hasFullAccess ? availability : .needsFullAccess
    }

    func start(handlers: InKeyboardDictationHandlers) -> Bool {
        startCount += 1
        self.handlers = handlers
        return true
    }

    func finish() {
        finishCount += 1
    }

    func cancel() {
        cancelCount += 1
        handlers = nil
    }
}

private final class SilentEventBus: CrossProcessEventStreaming, @unchecked Sendable {
    func post(_ event: CrossProcessEvent) {}

    func events() -> AsyncStream<CrossProcessEvent> {
        AsyncStream { _ in }
    }
}
