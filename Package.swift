// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "calfind",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "calfind", targets: ["calfind"])
  ],
  dependencies: [
    .package(url: "https://github.com/airbnb/swift.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.2"),
    .package(url: "https://github.com/kubens/RRuleKit", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "CalfindKit",
      dependencies: ["RRuleKit"],
      linkerSettings: [
        .linkedFramework("Security")
      ],
    ),
    .target(
      name: "CalfindCLI",
      dependencies: [
        "CalfindKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
    ),
    .executableTarget(
      name: "calfind",
      dependencies: [
        "CalfindCLI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
    ),
    .testTarget(
      name: "CalfindKitTests",
      dependencies: ["CalfindKit"],
    ),
  ],
  swiftLanguageModes: [.v6],
)
