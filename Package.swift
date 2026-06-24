// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "Yorkie",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(
            name: "Yorkie",
            targets: ["Yorkie"]
        ),
        .library(
            name: "YorkieDevtoolsUI",
            targets: ["YorkieDevtoolsUI"]
        ),
        .library(
            name: "YorkieDevtoolsServer",
            targets: ["YorkieDevtoolsServer"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", exact: "1.0.3"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
        .package(url: "https://github.com/groue/Semaphore.git", exact: "0.0.8"),
        .package(url: "https://github.com/apple/swift-docc-plugin", exact: "1.4.3"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0")
    ],
    targets: [
        .target(
            name: "Yorkie",
            dependencies: [.product(name: "Connect", package: "connect-swift"),
                           .product(name: "Logging", package: "swift-log"),
                           .product(name: "Semaphore", package: "Semaphore")],
            path: "Sources",
            exclude: ["Info.plist",
                      "DevtoolsUI",
                      "DevtoolsServer",
                      "API/V1/yorkie/v1/resources.proto",
                      "API/V1/yorkie/v1/yorkie.proto",
                      "API/V1/googleapis/google/rpc/error_details.proto",
                      "API/V1/buf.gen.yaml",
                      "API/V1/buf.yaml",
                      "API/V1/run_protoc.sh"]
        ),
        .target(
            name: "YorkieDevtoolsUI",
            dependencies: ["Yorkie"],
            path: "Sources/DevtoolsUI"
        ),
        .target(
            name: "YorkieDevtoolsServer",
            dependencies: ["Yorkie"],
            path: "Sources/DevtoolsServer",
            resources: [.process("Resources/viewer.html")]
        ),
        .target(
            name: "YorkieTestHelper",
            dependencies: [
                "Yorkie",
                .product(name: "ConnectNIO", package: "connect-swift")
            ],
            path: "Tests/Helper"
        ),
        .testTarget(
            name: "YorkieUnitTests",
            dependencies: ["Yorkie", "YorkieTestHelper"],
            path: "Tests/Unit",
            swiftSettings: [.define("SWIFT_TEST")]
        ),
        .testTarget(
            name: "YorkieIntegrationTests",
            dependencies: ["Yorkie", "YorkieTestHelper"],
            path: "Tests/Integration",
            swiftSettings: [.define("SWIFT_TEST")]
        ),
        .testTarget(
            name: "YorkieBenchmarkTests",
            dependencies: ["Yorkie", "YorkieTestHelper"],
            path: "Tests/Benchmark",
            resources: [.process("editing-trace.json")],
            swiftSettings: [.define("SWIFT_TEST")]
        ),
        .testTarget(
            name: "YorkieDevtoolsUITests",
            dependencies: ["YorkieDevtoolsUI", "Yorkie"],
            path: "Tests/DevtoolsUI",
            swiftSettings: [.define("SWIFT_TEST")]
        )
    ]
)
