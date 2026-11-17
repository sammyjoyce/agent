import CoreImage
import Foundation
import Vision
import XCTest

/// A check the runner refused or an evidence record that failed. The runner stops at the first.
struct PhoneAcceptanceFailure: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Text compared the way OCR reads it: letters and digits only, lowercased, so wrapping and
/// punctuation do not decide a match.
enum Glyphs {
  static func normalized(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  static func lines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map { normalized(String($0)) }.filter { !$0.isEmpty }
  }

  static func showEveryLine(of text: String, in recognized: String) -> Bool {
    let seen = normalized(recognized)
    let wanted = lines(text)
    return !wanted.isEmpty && wanted.allSatisfy(seen.contains)
  }

  static func showAnyLine(of text: String, in recognized: String) -> Bool {
    let seen = normalized(recognized)
    return lines(text).contains(where: seen.contains)
  }

  /// Every line Vision reads in `image`, also after brightening it, since a dim placeholder can be
  /// visible while Vision sees only the bright buttons.
  static func recognized(in image: CGImage) throws -> String {
    let exposed = CIImage(cgImage: image).applyingFilter(
      "CIExposureAdjust", parameters: [kCIInputEVKey: 2])
    guard let brighter = CIContext().createCGImage(exposed, from: exposed.extent) else {
      throw PhoneAcceptanceFailure("Could not brighten the composer screenshot for OCR")
    }
    var recognized: [String] = []
    for input in [image, brighter] {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: input).perform([request])
      recognized += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    return recognized.joined(separator: " ")
  }
}

/// Wall-clock milliseconds since 1970 on the device that runs the runner, so a phone record lines
/// up with the coordinator's own times.
func epochMilliseconds() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

/// What the composer showed in the first screenshot after a Send tap.
struct SendEvidence: Codable, Sendable {
  let label: String
  /// When the runner tapped Send.
  let sentAt: Int64
  let recipientLine: String?
  let composerValue: String?
  let placeholderShown: Bool
  let sentGlyphsAbsent: Bool
  let keyboardShown: Bool
  let ocrText: String
  let cropAttachment: String
  let screenAttachment: String

  var problems: [String] {
    [
      placeholderShown ? nil : "the composer did not show its placeholder",
      sentGlyphsAbsent ? nil : "the composer still showed sent text",
      keyboardShown ? nil : "the keyboard was down",
    ].compactMap { $0 }
  }
}

/// What the composer showed at a check that follows no Send tap: a return to the app, a relaunch,
/// an admission or an alert tap.
struct DraftEvidence: Codable, Sendable {
  let label: String
  /// The draft the composer must hold, or its placeholder when it must hold none.
  let expected: String
  let composerValue: String?
  let expectedShown: Bool
  let sent: String?
  let sentGlyphsAbsent: Bool
  let ocrText: String
  let cropAttachment: String

  var problems: [String] {
    [
      expectedShown ? nil : "the composer did not show \(String(reflecting: expected))",
      sentGlyphsAbsent ? nil : "the composer showed sent text again",
    ].compactMap { $0 }
  }
}

/// A system alert that showed a codeword, or its absence at the deadline.
struct AlertEvidence: Codable, Sendable {
  enum Surface: String, Codable, Sendable {
    case banner
    case notificationCenter
  }

  enum AppState: String, Codable, Sendable {
    case background
    case terminated
    case foreground
    case unknown

    init(_ state: XCUIApplication.State) {
      switch state {
      case .notRunning: self = .terminated
      case .runningBackground, .runningBackgroundSuspended: self = .background
      case .runningForeground: self = .foreground
      case .unknown: self = .unknown
      @unknown default: self = .unknown
      }
    }
  }

  let codeword: String
  let surface: Surface
  let appState: AppState
  /// The label of the element that showed the codeword, or nil when none did in time.
  let alertLabel: String?
  /// When the runner first found the alert. Its poll can lag the alert by about a second.
  let seenAt: Int64?
  /// When the runner tapped the alert, for an alert it opened.
  var tappedAt: Int64?
  let attachment: String

  /// A surface that never showed the codeword is an observation, not a problem: Focus or the
  /// banner style can hide banners. The test fails only when no surface showed it.
  func problems(expecting state: AppState) -> [String] {
    guard alertLabel != nil, appState != state else { return [] }
    return ["the app was \(appState.rawValue), not \(state.rawValue)"]
  }
}

/// What the rehearsal's coordinator received for one draft.
struct SubmitEvidence: Codable, Sendable {
  let label: String
  let draftLines: Int
  /// Every submit that starts like the draft, so a draft split at a Return shows as several.
  let submits: [String]

  var problems: [String] {
    guard submits.count == 1, let text = submits.first else {
      return ["the coordinator received \(submits.count) submits for one draft"]
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return lines == draftLines ? [] : ["the submit had \(lines) lines, not \(draftLines)"]
  }
}

/// The Notifications section of Connection, as the phone showed it.
struct RegistrationEvidence: Codable, Sendable {
  let mainChatUpdates: Bool
  /// Lines under the toggle that name the coordinator, each a reason it cannot alert.
  let coordinatorHints: [String]
  let attachment: String

  var problems: [String] {
    [
      mainChatUpdates ? nil : "Main-chat updates is off",
      coordinatorHints.isEmpty ? nil : "the coordinator has hints: \(coordinatorHints)",
    ].compactMap { $0 }
  }
}

/// One record as the host script reads it back from the result bundle.
private struct EvidenceEnvelope<Record: Encodable>: Encodable {
  let kind: String
  let test: String
  let record: Record
  let problems: [String]
}

extension XCTestCase {
  @MainActor func keep(_ screenshot: XCUIScreenshot, as name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Keeps the record beside its PNGs, then fails the test with its problems, if any.
  @MainActor func check<Record: Encodable>(
    _ record: Record, kind: String, name: String, problems: [String]
  ) throws {
    try keepRecord(record, kind: kind, name: name, problems: problems)
    guard problems.isEmpty else {
      throw PhoneAcceptanceFailure("\(kind) \(name): \(problems.joined(separator: "; "))")
    }
  }

  /// Keeps the record beside its PNGs as JSON the host script reads back.
  @MainActor func keepRecord<Record: Encodable>(
    _ record: Record, kind: String, name: String, problems: [String]
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let envelope = EvidenceEnvelope(kind: kind, test: self.name, record: record, problems: problems)
    let attachment = XCTAttachment(
      data: try encoder.encode(envelope), uniformTypeIdentifier: "public.json")
    attachment.name = "\(kind)-\(name).json"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
