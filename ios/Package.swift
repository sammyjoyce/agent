// swift-tools-version: 6.0
import Darwin
import Foundation
import PackageDescription

func supports273AppIntentsSDK() -> Bool {
  let env = ProcessInfo.processInfo.environment
  func nonEmpty(_ key: String) -> String? {
    guard let value = env[key], !value.isEmpty else { return nil }
    return value
  }
  let sdkRoot = nonEmpty("SDKROOT")
  var developerDir = nonEmpty("DEVELOPER_DIR")
  if developerDir == nil, let sdkRoot, let range = sdkRoot.range(of: "/Platforms/") {
    developerDir = String(sdkRoot[..<range.lowerBound])
  }
  if developerDir == nil {
    for index in 0..<_dyld_image_count() {
      guard let cName = _dyld_get_image_name(index) else { continue }
      let path = String(cString: cName)
      if let range = path.range(of: "/Toolchains/") {
        developerDir = String(path[..<range.lowerBound])
        break
      }
    }
  }
  // An explicit SDK is authoritative, even when unreadable: never fall back to
  // a newer SDK and enable APIs that the selected compiler cannot import.
  // iOS build callers must select their target SDK before package resolution.
  let candidates: [String]
  if let sdkRoot {
    candidates = ["\(sdkRoot)/SDKSettings.json"]
  } else {
    candidates = developerDir.map {
      ["\($0)/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.json"]
    } ?? []
  }
  for path in candidates {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = json["Version"] as? String
    else { continue }
    let parts = version.split(separator: ".").compactMap { Int($0) }
    if let major = parts.first {
      return (major, parts.dropFirst().first ?? 0) >= (27, 3)
    }
  }
  return false
}

let sdkSwiftSettings: [SwiftSetting] =
  supports273AppIntentsSDK() ? [.define("AGENT_IOS_27_3_SDK")] : []

let package = Package(
  name: "Agent",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "AgentCore", targets: ["AgentCore"]),
    .library(name: "AgentUI", targets: ["AgentUI"]),
  ],
  targets: [
    .target(name: "AgentCore"),
    .target(name: "AgentUI", dependencies: ["AgentCore"], swiftSettings: sdkSwiftSettings),
    .testTarget(
      name: "AgentCoreTests", dependencies: ["AgentCore", "AgentUI"],
      resources: [.copy("Fixtures")], swiftSettings: sdkSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
