// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BeepBoopMenuBar",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "BeepBoopStatusCore", targets: ["BeepBoopStatusCore"]),
    .executable(name: "BeepBoopMenuBar", targets: ["BeepBoopMenuBar"]),
  ],
  dependencies: [
    .package(name: "Agent", path: "../../ios")
  ],
  targets: [
    .target(
      name: "BeepBoopStatusCore",
      dependencies: [
        .product(name: "AgentCore", package: "Agent")
      ]
    ),
    .executableTarget(
      name: "BeepBoopMenuBar",
      dependencies: ["BeepBoopStatusCore"]
    ),
    .testTarget(
      name: "BeepBoopStatusTests",
      dependencies: [
        "BeepBoopStatusCore",
        .product(name: "AgentCore", package: "Agent"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
