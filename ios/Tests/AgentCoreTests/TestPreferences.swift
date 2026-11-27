import Foundation
import Testing

final class TestPreferences: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any] = [:]

  init() {
    super.init(suiteName: nil)!
  }

  override func object(forKey key: String) -> Any? {
    lock.withLock { values[key] }
  }

  override func set(_ value: Any?, forKey key: String) {
    lock.withLock { values[key] = value }
  }

  override func removeObject(forKey key: String) {
    lock.withLock { _ = values.removeValue(forKey: key) }
  }

  override func dictionaryRepresentation() -> [String: Any] {
    lock.withLock { values }
  }
}

@Test
func testPreferencesKeepValuesInMemoryAndIsolateInstances() {
  let first = TestPreferences()
  let second = TestPreferences()
  let key = "test-preferences-\(UUID())"
  first.set("value", forKey: key)
  #expect(first.string(forKey: key) == "value")
  #expect(second.object(forKey: key) == nil)
  #expect(UserDefaults.standard.object(forKey: key) == nil)
  first.set(true, forKey: key)
  #expect(first.bool(forKey: key))
  first.set(42, forKey: key)
  #expect(first.integer(forKey: key) == 42)
  first.removeObject(forKey: key)
  #expect(first.dictionaryRepresentation().isEmpty)
}
