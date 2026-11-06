// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Domestique",
    platforms: [.macOS(.v26)],
    products: [
        // Everything below the UI, linked by the Xcode app target (Domestique.xcodeproj).
        .library(name: "DomestiqueKit", targets: ["DQCore", "AgentKit", "GitKit", "GitHubKit", "ProcessKit", "HostKit", "RaceRadioKit"]),
        // `swift run DomestiqueDev` runs the same UI sources without Xcode (no bundle; dev only).
        .executable(name: "DomestiqueDev", targets: ["DomestiqueDev"]),
        .executable(name: "dq", targets: ["dq"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // Race Radio messages. Keep the major/minor in step with protoc-gen-swift (proto/buf.gen.swift.yaml).
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        // Models, persistence, config file, shell helpers. No UI.
        .target(name: "DQCore"),
        // Claude Code (stream-json control protocol) + Codex (app-server JSON-RPC).
        .target(name: "AgentKit", dependencies: ["DQCore"]),
        // git worktrees, diffs, rebase/push.
        .target(name: "GitKit", dependencies: ["DQCore"]),
        // GitHub REST/GraphQL: PRs, checks, merge.
        .target(name: "GitHubKit", dependencies: ["DQCore"]),
        // Setup scripts, run tasks, logs, listening-port detection.
        .target(name: "ProcessKit", dependencies: ["DQCore"]),
        // Cloud machines: boat.dev API, multiplexed SSH, port forwarding.
        .target(name: "HostKit", dependencies: ["DQCore"]),
        // Race Radio client: talks to Team Car servers (generated types in Generated/).
        .target(
            name: "RaceRadioKit",
            dependencies: ["DQCore", "AgentKit", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        // The macOS app.
        .executableTarget(
            name: "DomestiqueDev",
            dependencies: ["DQCore", "AgentKit", "GitKit", "GitHubKit", "ProcessKit", "HostKit", "RaceRadioKit", "SwiftTerm"],
            path: "Sources/Domestique",
            exclude: ["Resources"]  // asset catalog (app icon) is compiled by the Xcode app target
        ),
        // CLI harness for poking the agent layer without the UI.
        .executableTarget(name: "dq", dependencies: ["DQCore", "AgentKit", "HostKit", "GitKit", "ProcessKit"]),
        .testTarget(name: "DQCoreTests", dependencies: ["DQCore"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit"]),
        .testTarget(name: "ProcessKitTests", dependencies: ["ProcessKit"]),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"]),
        .testTarget(name: "RaceRadioKitTests", dependencies: ["RaceRadioKit"]),
    ]
)
