import XCTest
import Foundation
@testable import Wingward

#if DEBUG
@MainActor
final class ReferenceJourneyTests: XCTestCase {
  func testRouteOrderContainsExactlyTheSevenReferenceScreens() {
    XCTAssertEqual(
      ReferenceJourneyScreen.allCases,
      [.login, .setupProfile, .setupQuiz, .wardIntro, .insight, .home, .chat]
    )
  }

  func testSharedModelUsesNeutralDefaultsOutsideTheFixture() {
    let model = ReferenceJourneyModel(data: ReferenceJourneyFixtures.data)

    XCTAssertEqual(model.profileDraft, .empty)
    XCTAssertEqual(model.profileDraft.gender, .preferNotToSay)
  }

  func testFixtureCarriesExplicitPreferencesAndConsistentStationArea() {
    let draft = ReferenceJourneyFixtures.profileDraft
    XCTAssertEqual(draft.preferenceMode, .selected)
    XCTAssertFalse(draft.preferredGenders.contains(.preferNotToSay))
    XCTAssertEqual(draft.locationMode, .station)
    let station = ReferenceJourneyFixtures.stationOptions.first(where: { $0.id == draft.stationID })
    XCTAssertEqual(station?.areaID, draft.broadAreaID)
  }

  func testPreferenceNoAnswerClearsSelectedGenders() {
    var draft = ReferenceProfileDraft.empty

    draft.setPreferenceMode(.selected)
    draft.togglePreferredGender(.woman)
    draft.togglePreferredGender(.preferNotToSay)
    XCTAssertEqual(draft.preferredGenders, [.woman])

    draft.setPreferenceMode(.noAnswer)
    XCTAssertEqual(draft.preferenceMode, .noAnswer)
    XCTAssertEqual(draft.preferredGenders, [])
  }

  func testStationSelectionDerivesAreaAndNotSetClearsLocation() {
    var draft = ReferenceProfileDraft.empty
    let station = ReferenceJourneyFixtures.stationOptions[0]

    draft.setPreferenceMode(.noAnswer)
    draft.setLocationMode(.station)
    XCTAssertFalse(draft.isReadyForContinue)
    draft.selectStation(station)

    XCTAssertEqual(draft.stationID, "jp-tokyo-shimokitazawa")
    XCTAssertEqual(draft.broadAreaID, "jp-tokyo-setagaya")
    XCTAssertTrue(draft.isReadyForContinue)

    draft.setLocationMode(.notSet)
    XCTAssertNil(draft.stationID)
    XCTAssertNil(draft.broadAreaID)
    XCTAssertTrue(draft.isReadyForContinue)
  }

  func testResetRestoresSessionDraftIncludingReferenceSettings() {
    let initial = ReferenceJourneyFixtures.profileDraft
    let model = ReferenceJourneyModel(
      data: ReferenceJourneyFixtures.data,
      initialProfileDraft: initial
    )
    var edited = initial
    edited.name = "Edited"
    edited.preferenceMode = .noAnswer
    edited.preferredGenders = []
    edited.locationMode = .notSet
    edited.stationID = nil
    edited.broadAreaID = nil
    model.setProfile(edited)

    model.reset()

    XCTAssertEqual(model.profileDraft, initial)
  }

  func testLoginAdvanceIsAnExplicitPreviewAction() {
    let recorder = ReferenceActionRecorder()
    let model = ReferenceJourneyModel(
      data: ReferenceJourneyFixtures.data,
      actions: ReferenceJourneyActions { recorder.append($0) }
    )

    model.continueFromLogin()

    XCTAssertEqual(model.screen, .setupProfile)
    XCTAssertEqual(recorder.actions, [.openedPreview])
  }

  func testNonbinaryAndPreferNotToSayRemainDistinct() {
    XCTAssertNotEqual(ReferenceProfileGender.nonbinary, .preferNotToSay)
    XCTAssertEqual(ReferenceProfileGender.allCases.count, 4)
  }

  func testMicrophoneAttemptDoesNotClaimPermissionOrSuccess() {
    let recorder = ReferenceActionRecorder()
    let model = ReferenceJourneyModel(
      data: ReferenceJourneyFixtures.data,
      actions: ReferenceJourneyActions { recorder.append($0) }
    )
    let initialPhase = model.voicePhase

    model.requestMicrophone()

    XCTAssertEqual(model.surfaceState, .unavailable(message: "マイク機能はまだ接続されていません。このプレビューはマイクを起動しません。"))
    XCTAssertEqual(model.voicePhase, initialPhase)
    XCTAssertEqual(recorder.actions, [.attemptedVoice])
  }

  func testSendAttemptRetainsDraftAndDoesNotAppendMessages() {
    let recorder = ReferenceActionRecorder()
    let model = ReferenceJourneyModel(
      data: ReferenceJourneyFixtures.data,
      actions: ReferenceJourneyActions { recorder.append($0) }
    )
    let candidate = ReferenceJourneyFixtures.data.candidates[0]
    model.openChat(with: candidate)
    model.setChatMode(.person)
    model.setDraft("  送信前の下書き  ")
    let messageCountBefore = model.data.personMessages(for: candidate.id).count

    model.attemptSend()

    XCTAssertEqual(model.draft, "  送信前の下書き  ")
    XCTAssertEqual(model.data.personMessages(for: candidate.id).count, messageCountBefore)
    XCTAssertEqual(model.surfaceState, .unavailable(message: "送信機能はまだ接続されていません。下書きは保持されています。"))
    XCTAssertEqual(recorder.actions, [.attemptedMessage(candidateID: candidate.id, text: "送信前の下書き")])
  }

  func testDraftsStayWithTheirCandidateWhenSwitchingThreads() {
    let model = ReferenceJourneyModel(data: ReferenceJourneyFixtures.data)
    let aoi = ReferenceJourneyFixtures.data.candidates[0]
    let ren = ReferenceJourneyFixtures.data.candidates[1]

    model.openChat(with: aoi)
    model.setChatMode(.person)
    model.setDraft("Aoiへの下書き")
    model.navigate(to: .home)
    model.selectCandidate(ren)
    model.openChat(with: ren)

    XCTAssertEqual(model.draft, "")
    model.setChatMode(.person)
    model.setDraft("Renへの下書き")
    model.openChat(with: aoi)

    XCTAssertEqual(model.draft, "Aoiへの下書き")
  }

  func testEveryPreviewStateHasAnAccessibleTitle() {
    XCTAssertTrue(ReferencePreviewStateOption.allCases.allSatisfy { !$0.title.isEmpty })
    XCTAssertEqual(
      Set(ReferencePreviewStateOption.allCases.map(\.id)).count,
      ReferencePreviewStateOption.allCases.count
    )
  }
}

private final class ReferenceActionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ReferenceJourneyAction] = []

  func append(_ action: ReferenceJourneyAction) {
    lock.lock()
    values.append(action)
    lock.unlock()
  }

  var actions: [ReferenceJourneyAction] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
#endif
