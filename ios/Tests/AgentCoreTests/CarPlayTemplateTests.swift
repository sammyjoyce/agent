#if AGENT_APP_HOST
  import CarPlay
  import Foundation
  import Testing

  @testable import AgentCore
  @testable import AgentUI

  @available(iOS 26.4, *)
  @MainActor @Test func theCarListOffersEachPairedCoordinatorAndARowStartsWithIt() throws {
    let work = CarCoordinator(id: ProfileID(), name: "Work")
    let personal = CarCoordinator(id: ProfileID(), name: "Personal")
    var chosen: [CarCoordinator] = []
    let sections = CarScreen.sections([work, personal]) { chosen.append($0) }
    let rows = sections.flatMap(\.items).compactMap { $0 as? CPListItem }
    #expect(sections.count == 1)
    #expect(rows.map(\.text) == ["Talk to Work", "Talk to Personal"])
    #expect(rows.map(\.isEnabled) == [true, true])
    var completions = 0
    rows[1].handler?(rows[1]) { completions += 1 }
    #expect(chosen == [personal])
    #expect(completions == 1)

    let none = CarScreen.sections([]) { _ in Issue.record("A row chose a coordinator") }
    let only = none.flatMap(\.items).compactMap { $0 as? CPListItem }
    #expect(only.map(\.text) == ["No coordinator is paired"])
    #expect(only.map(\.isEnabled) == [false])
  }

  @available(iOS 26.4, *)
  @MainActor @Test func eachVoiceStateShowsFixedWordsTheNameAndItsOwnButtons() {
    let template = CarScreen.voiceTemplate(for: "Work") { _, _ in }
    let states = template.voiceControlStates
    #expect(states.map(\.identifier) == ["working", "listening", "confirming", "speaking"])
    #expect(
      Set(states.map(\.identifier))
        == Set(CarPhase.allCases.filter { $0 != .idle }.map(\.rawValue)))
    #expect(
      states.map { $0.titleVariants ?? [] } == [
        ["Waiting for Work", "Waiting"], ["Talking to Work", "Listening"],
        ["Send to Work?", "Send?"], ["Speaking"],
      ])
    #expect(
      states.map { $0.actionButtons.map(\.title) } == [
        ["Cancel"], ["Done", "Cancel"], ["Send", "Cancel"], ["Stop"],
      ])
    for state in states {
      #expect(state.actionButtons.count <= CPVoiceControlState.maximumActionButtonCount)
    }
  }

  @Test func theAppNamesItsCarPlaySceneAndKeepsMultipleScenes() throws {
    let manifest = try #require(
      Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
    #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
    let roles = try #require(manifest["UISceneConfigurations"] as? [String: [[String: String]]])
    #expect(Array(roles.keys) == ["CPTemplateApplicationSceneSessionRoleApplication"])
    let car = try #require(roles["CPTemplateApplicationSceneSessionRoleApplication"]?.first)
    #expect(car["UISceneClassName"] == "CPTemplateApplicationScene")
    #expect(car["UISceneDelegateClassName"] == "Agent.CarPlayScene")
    let delegate = try #require(NSClassFromString("Agent.CarPlayScene") as? NSObject.Type)
    #expect(delegate.conforms(to: CPTemplateApplicationSceneDelegate.self))
  }
#endif
