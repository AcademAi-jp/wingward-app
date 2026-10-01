import Foundation

enum QuizDTOValidationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case unknownQuestion
  case invalidCategory
  case invalidQuestionMetadata
  case invalidQuestionOrder
  case missingRequiredQuestions
  case duplicateQuestion
  case duplicateAnswer
  case invalidSelection
  case duplicateSelection
  case invalidValue
}

struct QuizOption: Codable, Equatable, Sendable {
  let value: String
  let label: String

  init(value: String, label: String) {
    self.value = value
    self.label = label
  }
}

struct QuizCatalogDefinition: Equatable, Sendable {
  let id: String
  let category: String
  let questionText: String
  let options: [QuizOption]
  let allowMultiple: Bool
  let sortOrder: Int
}

enum QuizCatalog {
  static let definitions: [QuizCatalogDefinition] = [
    QuizCatalogDefinition(
      id: "q1",
      category: "lifestyle",
      questionText: #"What feels most like a "fulfilling day off" to you?"#,
      options: [
        QuizOption(value: "a", label: "Going out with friends and hopping around different places"),
        QuizOption(value: "b", label: "Relaxing at home and doing only what you enjoy"),
        QuizOption(value: "c", label: "Focusing on hobbies or lessons to improve yourself"),
        QuizOption(value: "d", label: "Going with the flow and deciding on the spot")
      ],
      allowMultiple: false,
      sortOrder: 1
    ),
    QuizCatalogDefinition(
      id: "q2",
      category: "communication",
      questionText: #"When do you feel "at ease" in a conversation?"#,
      options: [
        QuizOption(value: "a", label: "When the conversation flows with a good rhythm and lots of laughter"),
        QuizOption(value: "b", label: "When you can have a slow, deep talk and silences feel fine"),
        QuizOption(value: "c", label: #"When you resonate with each other and "I get it!" keeps coming up"#),
        QuizOption(value: "d", label: "When each other's stories spark something and you discover something new")
      ],
      allowMultiple: false,
      sortOrder: 2
    ),
    QuizCatalogDefinition(
      id: "q3",
      category: "humor",
      questionText: "What kind of moment makes you laugh out loud?",
      options: [
        QuizOption(value: "a", label: #"When everyday "relatable" stuff is said in a funny way"#),
        QuizOption(value: "b", label: "When the conversation suddenly goes in an unexpected direction"),
        QuizOption(value: "c", label: "When something surreal and nonsensical somehow hits the spot"),
        QuizOption(value: "d", label: "When you hear a sharp, slightly biting remark")
      ],
      allowMultiple: false,
      sortOrder: 3
    ),
    QuizCatalogDefinition(
      id: "q4",
      category: "expression",
      questionText: "When sharing your feelings with someone, which is closer to you?",
      options: [
        QuizOption(value: "a", label: "Putting what you feel into words right away"),
        QuizOption(value: "b", label: "Taking time to think, then choosing your words"),
        QuizOption(value: "c", label: "Showing through actions and attitude rather than words"),
        QuizOption(value: "d", label: "Hoping they get it from the vibe")
      ],
      allowMultiple: false,
      sortOrder: 4
    ),
    QuizCatalogDefinition(
      id: "q5",
      category: "values",
      questionText: "If you're going to spend money, which fits you best?",
      options: [
        QuizOption(value: "a", label: "Spending on travel and experiences (memories last)"),
        QuizOption(value: "b", label: "Collecting things you love (you like having stuff)"),
        QuizOption(value: "c", label: "Saving as much as possible (peace of mind matters)"),
        QuizOption(value: "d", label: "Whatever has the best cost-performance (rational is best)")
      ],
      allowMultiple: false,
      sortOrder: 5
    ),
    QuizCatalogDefinition(
      id: "q6",
      category: "planning",
      questionText: "How do you usually plan your schedule?",
      options: [
        QuizOption(value: "a", label: "Decide in detail in advance and stick to the plan"),
        QuizOption(value: "b", label: "Set a rough direction and decide the rest on the spot"),
        QuizOption(value: "c", label: "Often decide at the last minute (you like going with the flow)"),
        QuizOption(value: "d", label: "You make plans but are fine changing them (flexible)")
      ],
      allowMultiple: false,
      sortOrder: 6
    ),
    QuizCatalogDefinition(
      id: "q7",
      category: "relationship",
      questionText: "In relationships with friends and acquaintances, which is closer to you?",
      options: [
        QuizOption(value: "a", label: "Valuing a few deep relationships"),
        QuizOption(value: "b", label: "Wanting to stay connected with many people, even if loosely"),
        QuizOption(value: "c", label: "Valuing time alone just as much"),
        QuizOption(value: "d", label: "It depends on the situation")
      ],
      allowMultiple: false,
      sortOrder: 7
    ),
    QuizCatalogDefinition(
      id: "q8",
      category: "recovery",
      questionText: "When you're tired, what helps you recover most?",
      options: [
        QuizOption(value: "a", label: "Talking to someone and venting"),
        QuizOption(value: "b", label: "Having quiet time alone to recharge"),
        QuizOption(value: "c", label: "Moving your body to refresh"),
        QuizOption(value: "d", label: "Getting absorbed in something you enjoy to switch mood")
      ],
      allowMultiple: false,
      sortOrder: 8
    ),
    QuizCatalogDefinition(
      id: "q9",
      category: "daily_rhythm",
      questionText: "Which is closer to your daily rhythm?",
      options: [
        QuizOption(value: "a", label: "Early riser who focuses in the morning (morning type)"),
        QuizOption(value: "b", label: "More active at night, often up late (night owl)"),
        QuizOption(value: "c", label: "No fixed pattern, varies by day"),
        QuizOption(value: "d", label: "As regular as possible: fixed wake and sleep times")
      ],
      allowMultiple: false,
      sortOrder: 9
    ),
    QuizCatalogDefinition(
      id: "q10",
      category: "lifestyle_zone",
      questionText: "Which area do you often go to or like best?",
      options: [
        QuizOption(value: "a", label: "City center (shopping, food, entertainment)"),
        QuizOption(value: "b", label: "Residential / downtown (calm atmosphere)"),
        QuizOption(value: "c", label: "Nature / suburbs (parks, mountains, rivers)"),
        QuizOption(value: "d", label: "No strong preference, depends on the day")
      ],
      allowMultiple: false,
      sortOrder: 10
    )
  ]

  static let definitionsByID: [String: QuizCatalogDefinition] = Dictionary(
    uniqueKeysWithValues: definitions.map { ($0.id, $0) }
  )

  static let requiredIDs = Set(definitions.map(\.id))

  static var currentQuestions: [QuizQuestion] {
    definitions.map {
      QuizQuestion(
        id: $0.id,
        category: $0.category,
        questionText: $0.questionText,
        options: $0.options,
        allowMultiple: $0.allowMultiple,
        sortOrder: $0.sortOrder
      )
    }
  }

  static func definition(for id: String) -> QuizCatalogDefinition? {
    definitionsByID[id]
  }
}

struct QuizQuestion: Decodable, Equatable, Identifiable, Sendable {
  let id: String
  let category: String
  let questionText: String
  let options: [QuizOption]
  let allowMultiple: Bool
  let sortOrder: Int

  init(
    id: String,
    category: String,
    questionText: String,
    options: [QuizOption],
    allowMultiple: Bool,
    sortOrder: Int
  ) {
    self.id = id
    self.category = category
    self.questionText = questionText
    self.options = options
    self.allowMultiple = allowMultiple
    self.sortOrder = sortOrder
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case category
    case allowMultiple = "allow_multiple"
    case sortOrder = "sort_order"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    guard let definition = QuizCatalog.definition(for: id) else {
      throw QuizDTOValidationError.unknownQuestion
    }
    let category = try container.decode(String.self, forKey: .category)
    let allowMultiple = try container.decode(Bool.self, forKey: .allowMultiple)
    let sortOrder = try container.decode(Int.self, forKey: .sortOrder)
    guard category == definition.category else {
      throw QuizDTOValidationError.invalidCategory
    }
    guard allowMultiple == definition.allowMultiple, sortOrder == definition.sortOrder else {
      throw QuizDTOValidationError.invalidQuestionMetadata
    }

    self.init(
      id: definition.id,
      category: definition.category,
      questionText: definition.questionText,
      options: definition.options,
      allowMultiple: definition.allowMultiple,
      sortOrder: definition.sortOrder
    )
  }

  static func validate(_ value: QuizQuestion) throws {
    guard let definition = QuizCatalog.definition(for: value.id) else {
      throw QuizDTOValidationError.unknownQuestion
    }
    guard value.category == definition.category else {
      throw QuizDTOValidationError.invalidCategory
    }
    guard value.questionText == definition.questionText, value.options == definition.options else {
      throw QuizDTOValidationError.invalidQuestionMetadata
    }
    guard value.allowMultiple == definition.allowMultiple else {
      throw QuizDTOValidationError.invalidQuestionMetadata
    }
    guard value.sortOrder == definition.sortOrder else {
      throw QuizDTOValidationError.invalidQuestionOrder
    }
  }
}

struct QuizQuestionsPayload: Decodable, Equatable, Sendable, APIValidatable {
  let questions: [QuizQuestion]

  init(questions: [QuizQuestion]) {
    self.questions = questions
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.questions = try container.decode([QuizQuestion].self)
  }

  static func validate(_ value: QuizQuestionsPayload) throws {
    guard value.questions.count == QuizCatalog.requiredIDs.count else {
      throw QuizDTOValidationError.missingRequiredQuestions
    }
    var questionIDs = Set<String>()
    var sortOrders = Set<Int>()
    for question in value.questions {
      guard questionIDs.insert(question.id).inserted else {
        throw QuizDTOValidationError.duplicateQuestion
      }
      guard sortOrders.insert(question.sortOrder).inserted else {
        throw QuizDTOValidationError.invalidQuestionOrder
      }
      try QuizQuestion.validate(question)
    }
    guard questionIDs == QuizCatalog.requiredIDs,
      sortOrders == Set(1...QuizCatalog.requiredIDs.count)
    else {
      throw QuizDTOValidationError.missingRequiredQuestions
    }
  }
}

struct QuizAnswer: Codable, Equatable, Sendable {
  let questionID: String
  let selected: [String]

  init(questionID: String, selected: [String]) {
    self.questionID = questionID
    self.selected = selected
  }

  enum CodingKeys: String, CodingKey {
    case questionID = "question_id"
    case selected
  }

  static func validate(_ value: QuizAnswer) throws {
    guard let definition = QuizCatalog.definition(for: value.questionID) else {
      throw QuizDTOValidationError.unknownQuestion
    }
    guard value.selected.count <= definition.options.count else {
      throw QuizDTOValidationError.invalidSelection
    }
    var selectedValues = Set<String>()
    let optionValues = Set(definition.options.map(\.value))
    for selection in value.selected {
      guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        selection.count <= 120,
        optionValues.contains(selection)
      else {
        throw QuizDTOValidationError.invalidSelection
      }
      guard selectedValues.insert(selection).inserted else {
        throw QuizDTOValidationError.duplicateSelection
      }
    }
    guard definition.allowMultiple || value.selected.count <= 1 else {
      throw QuizDTOValidationError.invalidSelection
    }
  }
}

struct QuizAnswersPayload: Decodable, Equatable, Sendable, APIValidatable {
  let answers: [QuizAnswer]

  init(answers: [QuizAnswer]) {
    self.answers = answers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.answers = try container.decode([QuizAnswer].self)
  }

  static func validate(_ value: QuizAnswersPayload) throws {
    var questionIDs = Set<String>()
    for answer in value.answers {
      guard questionIDs.insert(answer.questionID).inserted else {
        throw QuizDTOValidationError.duplicateAnswer
      }
      try QuizAnswer.validate(answer)
    }
  }
}

struct QuizAnswersRequest: Codable, Equatable, Sendable {
  let answers: [QuizAnswer]
}

struct QuizSaveResponse: Decodable, Equatable, Sendable, APIValidatable {
  let message: String
  let count: Int

  enum CodingKeys: String, CodingKey {
    case message
    case count
  }

  static func validate(_ value: QuizSaveResponse) throws {
    try APIDTOValidation.requireNonEmpty(value.message)
    guard value.message.count <= 120, (0...QuizCatalog.requiredIDs.count).contains(value.count) else {
      throw QuizDTOValidationError.invalidValue
    }
  }
}

protocol QuizAPI: Sendable {
  func fetchQuestions() async throws -> [QuizQuestion]
  func fetchAnswers() async throws -> [QuizAnswer]
  func saveAnswers(_ answers: [QuizAnswer]) async throws -> QuizSaveResponse
}

struct LiveQuizAPI: QuizAPI, Sendable {
  static let questionsPath = "/api/quiz/questions"
  static let answersPath = "/api/quiz/answers"

  let client: any AuthenticatedAPIClientProtocol

  init(client: any AuthenticatedAPIClientProtocol) {
    self.client = client
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider,
      transport: transport
    )
    self.init(client: client)
  }

  func fetchQuestions() async throws -> [QuizQuestion] {
    try await client.get(Self.questionsPath, as: QuizQuestionsPayload.self).questions
  }

  func fetchAnswers() async throws -> [QuizAnswer] {
    try await client.get(Self.answersPath, as: QuizAnswersPayload.self).answers
  }

  func saveAnswers(_ answers: [QuizAnswer]) async throws -> QuizSaveResponse {
    try QuizAnswersPayload.validate(QuizAnswersPayload(answers: answers))
    let body = try JSONEncoder().encode(QuizAnswersRequest(answers: answers))
    return try await client.post(Self.answersPath, body: body, as: QuizSaveResponse.self)
  }
}

protocol QuizAPIFactory: Sendable {
  func make(ownerID: String) -> (any QuizAPI)?
}

struct LiveQuizAPIFactory: QuizAPIFactory, Sendable {
  let baseURL: URL
  let authService: any AuthService
  let profileAPI: any ProfileAPI
  let transport: any APIHTTPTransport

  init(
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) {
    self.baseURL = baseURL
    self.authService = authService
    self.profileAPI = profileAPI
    self.transport = transport
  }

  func make(ownerID: String) -> (any QuizAPI)? {
    try? LiveQuizAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}

#if DEBUG
enum DebugQuizScenario: String, Sendable {
  case success
  case completed
  case empty
  case retry
  case loading
  case readbackMismatch
}

struct DebugQuizAPIFactory: QuizAPIFactory, Sendable {
  private let scenario: DebugQuizScenario

  init(scenario: DebugQuizScenario = .success) {
    self.scenario = scenario
  }

  func make(ownerID: String) -> (any QuizAPI)? {
    guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return DebugQuizAPI(scenario: scenario)
  }
}

private actor DebugQuizAPI: QuizAPI {
  private let scenario: DebugQuizScenario
  private var questionRequestCount = 0
  private var savedAnswers: [QuizAnswer] = []

  init(scenario: DebugQuizScenario) {
    self.scenario = scenario
  }

  func fetchQuestions() async throws -> [QuizQuestion] {
    questionRequestCount += 1
    if scenario == .retry, questionRequestCount == 1 {
      throw APIClientError.temporarilyUnavailable
    }
    if scenario == .loading {
      try await Task.sleep(nanoseconds: 600_000_000_000)
    }
    return QuizCatalog.currentQuestions
  }

  func fetchAnswers() async throws -> [QuizAnswer] {
    switch scenario {
    case .completed:
      return Self.completeAnswers
    case .readbackMismatch:
      guard savedAnswers.isEmpty else {
        return Array(savedAnswers.dropLast())
      }
      return []
    default:
      return savedAnswers
    }
  }

  func saveAnswers(_ answers: [QuizAnswer]) async throws -> QuizSaveResponse {
    savedAnswers = answers
    return QuizSaveResponse(message: "Answers saved", count: answers.count)
  }

  private static var completeAnswers: [QuizAnswer] {
    QuizCatalog.currentQuestions.map {
      QuizAnswer(questionID: $0.id, selected: ["a"])
    }
  }
}
#endif
