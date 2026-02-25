# Yorkie iOS SDK

Swift client SDK for real-time collaboration on iOS 15+ and macOS 13+. Uses connect-swift for gRPC.

## Development Commands

```sh
swift build                # Build the SDK
swift test                 # Run unit tests (YorkieUnitTests)
swiftlint --strict         # Lint (zero warnings)
swiftformat .              # Format code

# Integration tests (requires Yorkie server)
docker compose -f docker/docker-compose-ci.yml up -d
# Then run YorkieIntegrationTests via Xcode or swift test
```

## After Making Changes

Always run before submitting:
```sh
swiftlint --strict && swift build && swift test
```

## Gotchas

- Apache 2.0 license header required on all files
- Generated protobuf code in `Sources/API/V1/Generated/` — excluded from linting/formatting, don't edit manually
- SwiftFormat excludes `Sources/API` directory
- SwiftLint: max cyclomatic complexity 25, function body 110 lines
- `@dynamicMemberLookup` on JSON types for subscript access — maintain this pattern
- Version in `Sources/Version.swift` must match git tag for SPM releases
- `SWIFT_TEST` build flag defined for test targets
- Concurrency uses Swift async/await with Semaphore for synchronization
