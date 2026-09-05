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
    ),
    .library(
      name: "ActivityArchiveVault",
      targets: ["ActivityArchiveVault"]
    ),
  ],
  targets: [
    .target(name: "ActivityArchiveCore"),
    .target(
      name: "ActivityArchiveVault",
      dependencies: ["ActivityArchiveCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "ActivityArchiveCoreTests",
      dependencies: ["ActivityArchiveCore"]
    ),
    .testTarget(
      name: "ActivityArchiveVaultTests",
      dependencies: ["ActivityArchiveCore", "ActivityArchiveVault"]
    ),
  ]
)
