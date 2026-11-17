import Foundation

/// What one run targets. xcodebuild passes each `TEST_RUNNER_<NAME>` to the runner as `<NAME>`.
struct PhoneAcceptanceConfiguration: Sendable {
  enum Mode: Sendable {
    /// Drives the app already installed, with no launch arguments or environment.
    case attach
    /// Launches the simulator's Debug app against two loopback peers.
    case rehearsal
  }

  struct Invalid: Error, CustomStringConvertible {
    let description: String
  }

  let app: String
  let coordinator: String
  let run: String
  let mode: Mode

  static func current() throws -> Self { try parse(ProcessInfo.processInfo.environment) }

  static func parse(_ environment: [String: String]) throws -> Self {
    func value(_ name: String) -> String? {
      environment[name].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap {
        $0.isEmpty ? nil : $0
      }
    }
    let required = ["PHONE_ACCEPTANCE_APP", "PHONE_ACCEPTANCE_COORDINATOR", "PHONE_ACCEPTANCE_RUN"]
    let missing = required.filter { value($0) == nil }
    guard missing.isEmpty, let app = value(required[0]), let coordinator = value(required[1]),
      let run = value(required[2])
    else {
      throw Invalid(
        description:
          "Missing \(missing.joined(separator: ", ")). Pass each as TEST_RUNNER_<NAME>.")
    }
    guard run.count <= 24,
      run.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw Invalid(
        description: "PHONE_ACCEPTANCE_RUN must be up to 24 letters, digits or hyphens: \(run)")
    }
    let mode: Mode
    switch value("PHONE_ACCEPTANCE_REHEARSAL") {
    case nil, "0": mode = .attach
    case "1":
      #if targetEnvironment(simulator)
        mode = .rehearsal
      #else
        throw Invalid(description: "PHONE_ACCEPTANCE_REHEARSAL=1 runs only on a simulator.")
      #endif
    case let other?:
      throw Invalid(description: "PHONE_ACCEPTANCE_REHEARSAL must be 1 or unset, not \(other)")
    }
    return Self(app: app, coordinator: coordinator, run: run, mode: mode)
  }
}
