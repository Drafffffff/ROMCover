// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ROMCover",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ROMCover", targets: ["ROMCoverApp"]),
        .library(name: "ROMCoverCore", targets: ["ROMCoverCore"])
    ],
    targets: [
        .target(name: "ROMCoverCore"),
        .executableTarget(name: "ROMCoverApp", dependencies: ["ROMCoverCore"]),
        .executableTarget(name: "ROMCoverValidation", dependencies: ["ROMCoverCore"], path: "Tests/ROMCoverValidation"),
        .executableTarget(name: "ROMCoverLiveValidation", dependencies: ["ROMCoverCore"], path: "Tests/ROMCoverLiveValidation"),
        .executableTarget(name: "ROMCoverNameValidation", dependencies: ["ROMCoverCore"], path: "Tests/ROMCoverNameValidation")
    ]
)
