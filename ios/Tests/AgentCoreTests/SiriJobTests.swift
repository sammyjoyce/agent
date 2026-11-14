import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

struct SiriJobTests {
  @Test(arguments: ["nightly-deps", "work:nightly:deps", "a"])
  func aScopedIDSurvivesItsStringForm(item: String) throws {
    let id = ScopedEntityID(profile: ProfileID(), item: item)
    let parsed = try #require(ScopedEntityID.entityIdentifier(for: id.entityIdentifierString))
    #expect(parsed == id)
    #expect(parsed.item == item)
  }

  @Test(arguments: [
    "",
    "nightly-deps",
    ":nightly-deps",
    "not-a-uuid:nightly-deps",
    "\(ProfileID())",
    "\(ProfileID()):",
    "nightly:\(ProfileID())",
  ])
  func aMalformedScopedIDFailsToParse(string: String) {
    #expect(ScopedEntityID.entityIdentifier(for: string) == nil)
  }
}
