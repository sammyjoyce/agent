// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Speech",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "ParakeetSpeech", targets: ["ParakeetSpeech"])],
  dependencies: [
    // `traits: []` drops the prebuilt NeMo text-processing binary, TTS and the diarizers, and needs
    // a tools-6.2 manifest.
    .package(
      url: "https://github.com/FluidInference/FluidAudio",
      revision: "16780f04d2ece24f67d0fc00efccd0296491c1a8", traits: [])
  ],
  targets: [
    .target(
      name: "ParakeetSpeech", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
  ],
  swiftLanguageModes: [.v6]
)
