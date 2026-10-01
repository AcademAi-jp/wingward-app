import XCTest

final class PrivacyManifestTests: XCTestCase {
  private let manifestFileName = "PrivacyInfo.xcprivacy"

  func testManifestMatchesCurrentAppDataInventory() throws {
    let manifest = try loadSourceManifest()

    XCTAssertEqual(Set(manifest.keys), Set([
      "NSPrivacyTracking",
      "NSPrivacyTrackingDomains",
      "NSPrivacyCollectedDataTypes",
      "NSPrivacyAccessedAPITypes",
    ]))
    XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
    let accessedAPITypes = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [Any])
    XCTAssertTrue(accessedAPITypes.isEmpty)

    let declarations = try XCTUnwrap(
      manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
    )
    XCTAssertEqual(declarations.count, 3)

    let actual = try declarations.map { declaration in
      try CollectedDataDeclaration(
        type: XCTUnwrap(declaration["NSPrivacyCollectedDataType"] as? String),
        linked: XCTUnwrap(declaration["NSPrivacyCollectedDataTypeLinked"] as? Bool),
        tracking: XCTUnwrap(declaration["NSPrivacyCollectedDataTypeTracking"] as? Bool),
        purposes: XCTUnwrap(
          declaration["NSPrivacyCollectedDataTypePurposes"] as? [String]
        )
      )
    }

    let expected = [
      CollectedDataDeclaration(
        type: "NSPrivacyCollectedDataTypeEmailAddress",
        linked: true,
        tracking: false,
        purposes: ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
      ),
      CollectedDataDeclaration(
        type: "NSPrivacyCollectedDataTypeUserID",
        linked: true,
        tracking: false,
        purposes: ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
      ),
      CollectedDataDeclaration(
        type: "NSPrivacyCollectedDataTypeOtherDataTypes",
        linked: true,
        tracking: false,
        purposes: ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
      ),
    ]

    XCTAssertEqual(actual, expected)
    for declaration in declarations {
      XCTAssertEqual(
        Set(declaration.keys),
        Set([
          "NSPrivacyCollectedDataType",
          "NSPrivacyCollectedDataTypeLinked",
          "NSPrivacyCollectedDataTypeTracking",
          "NSPrivacyCollectedDataTypePurposes",
        ])
      )
    }
  }

  func testManifestIsWiredOnlyToWingwardAppResources() throws {
    let project = try String(contentsOf: projectURL())
    let fileReference = "A20000000000000000000018 /* PrivacyInfo.xcprivacy */"
    let buildFile = "A10000000000000000000013 /* PrivacyInfo.xcprivacy in Resources */"

    XCTAssertEqual(project.components(separatedBy: fileReference).count - 1, 3)
    XCTAssertEqual(project.components(separatedBy: buildFile).count - 1, 2)
    XCTAssertTrue(project.contains(
      "A20000000000000000000018 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = PrivacyInfo.xcprivacy; sourceTree = \"<group>\"; };"
    ))

    let appResources = try XCTUnwrap(
      resourcesPhase(named: "A30000000000000000000005", in: project)
    )
    XCTAssertTrue(appResources.contains(buildFile))

    for testResourcesPhase in ["A30000000000000000000007", "A30000000000000000000009"] {
      let resources = try XCTUnwrap(resourcesPhase(named: testResourcesPhase, in: project))
      XCTAssertFalse(resources.contains(buildFile), testResourcesPhase)
    }
  }

  func testReleaseBeforeSubmitReconciliationReminderIsExplicit() throws {
    let manifestSource = try String(contentsOf: sourceManifestURL())
    XCTAssertTrue(manifestSource.contains("TODO(release-before-submit)"))
    XCTAssertTrue(manifestSource.contains("final app and SDK data collection"))
    XCTAssertTrue(manifestSource.contains("not a claim about future behavior"))
  }

  private func loadSourceManifest() throws -> [String: Any] {
    let data = try Data(contentsOf: sourceManifestURL())
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(propertyList as? [String: Any])
  }

  private func sourceManifestURL() -> URL {
    iosDirectory().appendingPathComponent("Wingward").appendingPathComponent(manifestFileName)
  }

  private func projectURL() -> URL {
    iosDirectory().appendingPathComponent("Wingward.xcodeproj/project.pbxproj")
  }

  private func iosDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func resourcesPhase(named identifier: String, in project: String) -> String? {
    guard let start = project.range(of: "\(identifier) /* Resources */ = {") else {
      return nil
    }
    guard let end = project.range(of: "};", range: start.upperBound..<project.endIndex) else {
      return nil
    }
    return String(project[start.upperBound..<end.lowerBound])
  }
}

private struct CollectedDataDeclaration: Equatable {
  let type: String
  let linked: Bool
  let tracking: Bool
  let purposes: [String]
}
