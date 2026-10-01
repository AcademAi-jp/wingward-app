import Foundation
import XCTest
@testable import Wingward

@MainActor
final class QuizTests: XCTestCase {
  private let ownerID = "11111111-1111-4111-8111-111111111111"

  func testQuestionsDecodeToTheClosedCurrentCatalog() throws {
    let payload = try APIResponseDecoder.decode(
      questionMetadataEnvelope(),
      as: QuizQuestionsPayload.self
    )

    XCTAssertEqual(payload.questions.count, 10)
    XCTAssertEqual(payload.questions.map(\.id), (1...10).map { "q\($0)" })
    XCTAssertEqual(payload.questions.first?.questionText, "What feels most like a \"fulfilling day off\" to you?")
    XCTAssertEqual(payload.questions.last?.category, "lifestyle_zone")
    XCTAssertEqual(payload.questions.first?.options.count, 4)
  }

  func testQuestionsRejectLegacyIDsMissingQuestionsAndWrongMetadata() throws {
    var unknownID = try questionMetadataItems()
    unknownID[0]["id"] = "q1_weekend"
    assertInvalidResponse(try envelope(unknownID), as: QuizQuestionsPayload.self)

    var missingQuestion = try questionMetadataItems()
    missingQuestion.removeLast()
    assertInvalidResponse(try envelope(missingQuestion), as: QuizQuestionsPayload.self)

    var wrongCategory = try questionMetadataItems()
    wrongCategory[0]["category"] = "communication"
    assertInvalidResponse(try envelope(wrongCategory), as: QuizQuestionsPayload.self)

    var wrongMode = try questionMetadataItems()
    wrongMode[0]["allow_multiple"] = true
    assertInvalidResponse(try envelope(wrongMode), as: QuizQuestionsPayload.self)
  }

  func testAnswersRejectUnknownDuplicateAndMultipleSelections() throws {
    let empty = try APIResponseDecoder.decode(
      try envelope([]),
      as: QuizAnswersPayload.self
    )
    XCTAssertTrue(empty.answers.isEmpty)

    assertInvalidResponse(
      try envelope([
        ["question_id": "q1", "selected": ["a"]],
        ["question_id": "q1", "selected": ["b"]]
      ]),
      as: QuizAnswersPayload.self
    )
    assertInvalidResponse(
      try envelope([["question_id": "q1", "selected": ["z"]]]),
      as: QuizAnswersPayload.self
    )
    assertInvalidResponse(
      try envelope([["question_id": "q1", "selected": ["a", "b"]]]),
      as: QuizAnswersPayload.self
    )
  }

  func testLiveAPIUsesQuizRoutesAndEncodesQuestionIDsAsStrings() async throws {
    let client = FakeAuthenticatedAPIClient()
    let questionsRequest = APIRequest(method: .get, path: LiveQuizAPI.questionsPath)
    let answersRequest = APIRequest(method: .get, path: LiveQuizAPI.answersPath)
    let saveRequest = APIRequest(method: .post, path: LiveQuizAPI.answersPath)
    await client.setResponseData(try questionMetadataEnvelope(), for: questionsRequest)
    await client.setResponseData(try envelope([]), for: answersRequest)
    await client.setResponseData(
      try envelope(["message": "Answers saved", "count": 1]),
      for: saveRequest
    )

    let api = LiveQuizAPI(client: client)
    let questions = try await api.fetchQuestions()
    let answers = try await api.fetchAnswers()
    let submitted = [QuizAnswer(questionID: "q1", selected: ["a"])]
    let response = try await api.saveAnswers(submitted)
    let requests = await client.recordedRequests()

    XCTAssertEqual(questions.count, 10)
    XCTAssertTrue(answers.isEmpty)
    XCTAssertEqual(response.count, 1)
    XCTAssertEqual(requests.map { "\($0.method.rawValue) \($0.path)" }, [
      "GET \(LiveQuizAPI.questionsPath)",
      "GET \(LiveQuizAPI.answersPath)",
      "POST \(LiveQuizAPI.answersPath)"
    ])
    let body = try XCTUnwrap(requests.last?.body)
    let request = try JSONDecoder().decode(QuizAnswersRequest.self, from: body)
    XCTAssertEqual(request.answers, submitted)
  }

  func testStoreLoadsPartialAnswersButRequiresEveryQuestionToSave() async {
    let api = QuizScenarioAPI(initialAnswers: [QuizAnswer(questionID: "q1", selected: ["a"])])
    let store = QuizStore(ownerID: ownerID, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.draftAnswers, ["q1": ["a"]])
    XCTAssertFalse(store.canSave)
    await store.save().value
    XCTAssertEqual(store.saveError, .incompleteAnswers)
    let saveCalls = await api.saveCallCount()
    XCTAssertEqual(saveCalls, 0)
  }

  func testStoreReadbackMismatchFailsClosedAndPreservesDraft() async {
    let api = QuizScenarioAPI(readback: .dropLast)
    let store = QuizStore(ownerID: ownerID, api: api)
    await store.load().value
    fillAllAnswers(in: store)
    let expectedDraft = store.draftAnswers

    await store.save().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.saveError, .readbackMismatch)
    XCTAssertEqual(store.draftAnswers, expectedDraft)
    XCTAssertTrue(store.savedAnswers.isEmpty)
    XCTAssertFalse(store.didSave)
    XCTAssertEqual(store.successRevision, 0)
  }

  func testStoreRejectsSameShapeReadbackWithChangedSelection() async {
    let api = QuizScenarioAPI(readback: .alterFirst)
    let store = QuizStore(ownerID: ownerID, api: api)
    await store.load().value
    fillAllAnswers(in: store)

    await store.save().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.saveError, .readbackMismatch)
    XCTAssertFalse(store.didSave)
    XCTAssertEqual(store.successRevision, 0)
  }

  func testStorePublishesSuccessOnlyAfterExactReadback() async {
    let api = QuizScenarioAPI(readback: .exact)
    let store = QuizStore(ownerID: ownerID, api: api)
    await store.load().value
    fillAllAnswers(in: store)

    await store.save().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.saveError)
    XCTAssertEqual(store.savedAnswers, store.draftAnswers)
    XCTAssertTrue(store.didSave)
    XCTAssertEqual(store.successRevision, 1)
  }

  func testStoreSaveFailurePreservesDraftAndClearsSuccessSignal() async {
    let api = QuizScenarioAPI(readback: .failure(.temporarilyUnavailable))
    let store = QuizStore(ownerID: ownerID, api: api)
    await store.load().value
    fillAllAnswers(in: store)
    let expectedDraft = store.draftAnswers

    await store.save().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.saveError, .temporarilyUnavailable)
    XCTAssertEqual(store.draftAnswers, expectedDraft)
    XCTAssertFalse(store.didSave)
    XCTAssertEqual(store.successRevision, 0)
  }

  func testStoreCancelDuringSaveNeverReportsSuccess() async {
    let api = BlockingQuizAPI()
    let store = QuizStore(ownerID: ownerID, api: api)
    await store.load().value
    fillAllAnswers(in: store)
    let saveTask = store.save()
    await api.waitForSaveStart()

    store.cancel()
    await api.releaseSave()
    await saveTask.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertFalse(store.isSaving)
    XCTAssertFalse(store.didSave)
    XCTAssertEqual(store.successRevision, 0)
    XCTAssertTrue(store.draftAnswers.isEmpty)
  }

  func testStoreDoesNotStartDuplicateSaveWhileFirstSaveIsPending() async {
    let api = BlockingQuizAPI()
    let store = QuizStore(ownerID: ownerID, api: api)
    await store.load().value
    fillAllAnswers(in: store)
    let firstSave = store.save()
    await api.waitForSaveStart()

    await store.save().value
    let saveCalls = await api.saveCallCount()
    XCTAssertEqual(saveCalls, 1)

    store.cancel()
    await api.releaseSave()
    await firstSave.value
  }

  func testStoreRejectsOwnerRebindingBeforeCallingTheOriginalAPI() async {
    let api = QuizScenarioAPI()
    let store = QuizStore(ownerID: ownerID, api: api)
    store.updateOwner("22222222-2222-4222-8222-222222222222")

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.ownerMismatch))
    XCTAssertEqual(store.loadError, .ownerMismatch)
    let questionCalls = await api.questionCallCount()
    XCTAssertEqual(questionCalls, 0)
  }

  private func fillAllAnswers(in store: QuizStore) {
    for question in QuizCatalog.currentQuestions {
      store.setAnswer(questionID: question.id, selected: ["a"])
    }
  }

  private func questionMetadataItems() throws -> [[String: Any]] {
    QuizCatalog.currentQuestions.map { question in
      [
        "id": question.id,
        "category": question.category,
        "allow_multiple": question.allowMultiple,
        "sort_order": question.sortOrder
      ]
    }
  }

  private func questionMetadataEnvelope() throws -> Data {
    try envelope(questionMetadataItems())
  }

  private func envelope(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["data": value], options: [])
  }

  private func assertInvalidResponse<Value: APIValidatable>(
    _ data: Data,
    as type: Value.Type,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      _ = try APIResponseDecoder.decode(data, as: type)
      XCTFail("Malformed quiz response must fail closed", file: file, line: line)
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse, file: file, line: line)
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

private enum QuizReadback: Sendable {
  case exact
  case dropLast
  case alterFirst
  case failure(APIClientError)
}

private actor QuizScenarioAPI: QuizAPI {
  private let readback: QuizReadback
  private let initialAnswers: [QuizAnswer]
  private var saved: [QuizAnswer]?
  private var questionCalls = 0
  private var saveCalls = 0

  init(
    initialAnswers: [QuizAnswer] = [],
    readback: QuizReadback = .exact
  ) {
    self.initialAnswers = initialAnswers
    self.readback = readback
  }

  func fetchQuestions() async throws -> [QuizQuestion] {
    questionCalls += 1
    return QuizCatalog.currentQuestions
  }

  func fetchAnswers() async throws -> [QuizAnswer] {
    guard let saved else { return initialAnswers }
    switch readback {
    case .exact:
      return saved
    case .dropLast:
      return Array(saved.dropLast())
    case .alterFirst:
      guard !saved.isEmpty else { return saved }
      return [QuizAnswer(questionID: saved[0].questionID, selected: ["b"])]
        + Array(saved.dropFirst())
    case .failure:
      return saved
    }
  }

  func saveAnswers(_ answers: [QuizAnswer]) async throws -> QuizSaveResponse {
    saveCalls += 1
    if case let .failure(error) = readback {
      throw error
    }
    saved = answers
    return QuizSaveResponse(message: "Answers saved", count: answers.count)
  }

  func questionCallCount() -> Int { questionCalls }
  func saveCallCount() -> Int { saveCalls }
}

private actor BlockingQuizAPI: QuizAPI {
  private var saveContinuation: CheckedContinuation<QuizSaveResponse, Error>?
  private var saveStartedContinuation: CheckedContinuation<Void, Never>?
  private var saveStarted = false
  private var saveCalls = 0

  func fetchQuestions() async throws -> [QuizQuestion] {
    QuizCatalog.currentQuestions
  }

  func fetchAnswers() async throws -> [QuizAnswer] {
    []
  }

  func saveAnswers(_ answers: [QuizAnswer]) async throws -> QuizSaveResponse {
    saveCalls += 1
    saveStarted = true
    saveStartedContinuation?.resume()
    saveStartedContinuation = nil
    return try await withCheckedThrowingContinuation { continuation in
      saveContinuation = continuation
    }
  }

  func waitForSaveStart() async {
    if saveStarted { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      saveStartedContinuation = continuation
    }
  }

  func releaseSave() {
    saveContinuation?.resume(returning: QuizSaveResponse(message: "Answers saved", count: 10))
    saveContinuation = nil
  }

  func saveCallCount() -> Int { saveCalls }
}
