// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ResearchLibrary", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "ResearchCore", targets: ["ResearchCore"]),
    .executable(name: "ResearchLibrary", targets: ["ResearchLibrary"]),
    .executable(name: "ResearchLibraryTool", targets: ["ResearchLibraryTool"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "ResearchCore", dependencies: ["CSQLite"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "ResearchLibrary", dependencies: ["ResearchCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "ResearchLibraryTool", dependencies: ["ResearchCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "ResearchCoreTests", dependencies: ["ResearchCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
  ])
