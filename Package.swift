// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "Yorkie",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(
            name: "Yorkie",
            targets: ["Yorkie"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.9.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.19.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "Yorkie",
            dependencies: [.product(name: "GRPC", package: "grpc-swift"),
                           .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources",
            exclude: ["Info.plist",
                      "API/V1/Protos"]
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
        )
    ]
)
