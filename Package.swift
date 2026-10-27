// swift-tools-version: 6.2
import PackageDescription

var dependencies: [Package.Dependency] = []
var products: [Product] = [.library(name: "VoiceCore", targets: ["VoiceCore"])]
var targets: [Target] = [
    .target(name: "VoiceCore"),
    .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"], resources: [.copy("Fixtures")])
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git",
    revision: "1b0ed50d686873128a4129b3510ce3914c849bab", traits: []))
products.append(.executable(name: "MacVoice", targets: ["MacVoice"]))
targets.append(.executableTarget(name: "MacVoice", dependencies: ["VoiceCore", .product(name: "FluidAudio", package: "FluidAudio")]))
targets.append(.testTarget(name: "MacVoiceTests", dependencies: ["MacVoice", "VoiceCore"]))
#endif
let package = Package(name: "MacVoiceControl", platforms: [.macOS("14.2")],
    products: products, dependencies: dependencies, targets: targets, swiftLanguageModes: [.v5])
