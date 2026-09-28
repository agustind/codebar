// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "codebar",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
  ],
  targets: [
    .executableTarget(
      name: "codebar",
      dependencies: ["SwiftTerm"],
      path: "Sources/codebar"
    ),
  ]
)
