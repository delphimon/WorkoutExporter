// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ActivityArchiveCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "ActivityArchiveCore",
      targets: ["ActivityArchiveCore"]
    )
  ],
  targets: [
    .target(name: "ActivityArchiveCore"),
    .testTarget(
      name: "ActivityArchiveCoreTests",
      dependencies: ["ActivityArchiveCore"]
    ),
  ]
)
