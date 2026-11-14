import Foundation
import Testing

@testable import AgentCore

@Test(.timeLimit(.minutes(1)), arguments: [Optional<Bool>.none, .some(false), .some(true)])
func newNativeInputsAdvertiseIOSOnlyWhenTheCurrentConnectionSupportsOrigins(advertised: Bool?)
  async throws
{
  try await withCoordinator { session, fixture, outbox in
    await fixture.advertiseInputOrigins(advertised)
    await session.connect()
    for await update in session.updates where update.connection == .connected { break }
    #expect(await session.submit("A deliberately unsent-until-admitted native message"))
    let requests = try queuedRequests(outbox)
    #expect(requests.count == 1)
    #expect(requests.first?.origin == (advertised == true ? .ios : nil))
  }
}

@Test(.timeLimit(.minutes(1)))
func reconnectDoesNotReuseOriginCapabilityOrRewriteAnOlderPendingInput() async throws {
  try await withCoordinator { session, fixture, outbox in
    await fixture.advertiseInputOrigins(true)
    await fixture.loseInputAcknowledgements()
    await session.connect()
    for await update in session.updates where update.connection == .connected { break }
    #expect(await session.submit("Original input"))
    await session.disconnect()
    await fixture.advertiseInputOrigins(nil)
    await session.connect()
    for await update in session.updates where update.connection == .connected { break }
    #expect(await session.submit("New input on a legacy connection"))
    let requests = try queuedRequests(outbox)
    #expect(requests.last?.origin == nil)
  }
}

@Test(.timeLimit(.minutes(1)))
func retryingALegacyOutboxNeverInventsAnOriginEvenAfterCapabilityIsAdvertised() async throws {
  try await withCoordinator { session, fixture, outbox in
    let legacy = NativeRequestSubmit(
      inputId: UUID().uuidString, mode: .steer, text: "Legacy pending input")
    let item = OutboxItem(
      request: legacy, sendID: UUID().uuidString, recipients: [session.profile],
      queuedAt: Date().timeIntervalSince1970)
    try writePrivately(JSONEncoder().encode([item]), to: outbox)
    await fixture.advertiseInputOrigins(true)
    await session.connect()
    for await update in session.updates where update.connection == .connected { break }
    await session.retry(legacy.inputId)
    for await actual in fixture.observedInputs {
      #expect(actual == legacy)
      #expect(actual.origin == nil)
      break
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func aCoordinatorThatListsSiriAcceptsItAndAnUnknownListedOriginIsSkipped() async throws {
  try await withCoordinator { session, fixture, outbox in
    await fixture.advertiseInputOrigins(true)
    await fixture.advertiseAcceptedOrigins(["cli", "ios", "siri", "invented-future-origin"])
    await session.connect()
    for await update in session.updates where update.connection == .connected { break }
    #expect(await session.accepts(.siri))
    #expect(await session.accepts(.ios))
    #expect(await session.submit("A composer message"))
    #expect(try queuedRequests(outbox).first?.origin == .ios)
    await session.disconnect()
    #expect(await !session.accepts(.siri))
  }
}

@Test(.timeLimit(.minutes(1)), arguments: [Optional<Bool>.none, .some(false), .some(true)])
func aCoordinatorThatListsNoOriginsNeverAcceptsSiri(advertised: Bool?) async throws {
  try await withCoordinator { session, fixture, _ in
    await fixture.advertiseInputOrigins(advertised)
    await session.connect()
    for await update in session.updates where update.connection == .connected { break }
    #expect(await !session.accepts(.siri))
    #expect(await session.accepts(.ios) == (advertised == true))
  }
}

@Test func eachInputOriginHasItsOwnRowLabel() {
  let labels = [InputOrigin.cli, .ios, .siri].map {
    ChatRow(id: $0.rawValue, role: .user, text: "Invented message", inputOrigin: $0)
      .provenanceLabel
  }
  #expect(labels == ["CLI", "iOS", "Siri"])
}
