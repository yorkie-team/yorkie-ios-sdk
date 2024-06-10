// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "Yorkie",
    platforms: [.iOS(.v13), .macOS(.v13)],
    products: [
        .library(
            name: "Yorkie",
            targets: ["Yorkie"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
        .package(url: "https://github.com/groue/Semaphore.git", from: "0.0.8"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "Yorkie",
            dependencies: [.product(name: "Connect", package: "connect-swift"),
                           .product(name: "Logging", package: "swift-log"),
                           .product(name: "Semaphore", package: "Semaphore")],
            path: "Sources",
            exclude: ["Info.plist",
                      "API/V1/yorkie/v1/resources.proto",
                      "API/V1/yorkie/v1/yorkie.proto",
                      "API/V1/buf.gen.yaml",
                      "API/V1/buf.yaml",
                      "API/V1/run_protoc.sh"]
        ),
        .testTarget(
            name: "YorkieUnitTests",
            dependencies: ["Yorkie"],
            path: "Tests/Unit"
        ),
        .testTarget(
            name: "YorkieIntegrationTests",
            dependencies: ["Yorkie"],
            path: "Tests/Integration"
        ),
        .testTarget(
            name: "YorkieBenchmarkTests",
            dependencies: ["Yorkie"],
            path: "Tests/Benchmark"
        )
    ]
)
