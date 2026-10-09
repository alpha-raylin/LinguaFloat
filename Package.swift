// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LinguaFloat", platforms: [.macOS(.v14)], products: [.executable(name: "LinguaFloat", targets: ["LinguaFloat"])], targets: [.target(name: "LinguaCore"), .executableTarget(name: "LinguaFloat", dependencies: ["LinguaCore"]), .testTarget(name: "LinguaCoreTests", dependencies: ["LinguaCore"]), .testTarget(name: "LinguaFloatTests", dependencies: ["LinguaFloat", "LinguaCore"])])
