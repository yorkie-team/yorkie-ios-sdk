# Yorkie iOS SDK

Swift client SDK for Yorkie, providing real-time collaboration primitives for iOS and macOS applications.

## Tech Stack

- Swift 5.7+, Swift Package Manager
- Platforms: iOS 15+, macOS 13+
- connect-swift (gRPC), swift-protobuf, swift-log, Semaphore
- XCTest, SwiftLint, SwiftFormat

## Development Commands

```sh
swift build                # Build the SDK
swift test                 # Run unit tests (YorkieUnitTests)
swiftlint --strict         # Lint (v0.58.2)
swiftformat .              # Format code (v0.55.6)

# Integration tests (requires Yorkie server)
docker compose -f docker/docker-compose-ci.yml up -d
# Then run YorkieIntegrationTests via Xcode or swift test
```

## Project Structure

```
Sources/
  Core/               # Client, Attachment, Auth, Logger, YorkieService
  Document/
    Change/            # Change tracking (ChangeID, ChangePack)
    CRDT/              # CRDT data structures
    Json/              # JSON-like interface (JSONObject, JSONArray, JSONText)
    Operation/         # Operations on CRDT elements
    Presence/          # Presence tracking
    Ruleset/           # Document schema validation
    Time/              # TimeTicket, ActorID, VersionVector
    Util/              # Helpers (JSONObjectable, Payload, YorkieCountable)
    Document.swift     # Main Document class
  Util/                # IndexTree, LLRBTree, SplayTree, extensions
  API/V1/Generated/    # Protobuf generated code (excluded from linting)
  Version.swift        # SDK version
Tests/
  Unit/                # Unit tests mirroring Sources structure
  Integration/         # Integration tests (requires running server)
  Benchmark/           # Performance benchmarks
  Helper/              # Shared test utilities
Examples/              # Sample apps (Kanban, RichTextEditor, Scheduler, etc.)
docker/                # Docker Compose for test servers
Yorkie.xcodeproj/      # Xcode project
```

## Code Conventions

- Apache 2.0 license header on all files
- PascalCase for types, camelCase for functions/variables
- `@dynamicMemberLookup` on JSON types for subscript access
- Doc comments (`/** */`) on public APIs
- SwiftLint: max cyclomatic complexity 25, function body 110 lines
- SwiftFormat: excludes Sources/API (generated code)
- Commit messages: subject max 70 chars, body wrapped at 80 chars

## Architecture Notes

- **Three-layer hierarchy**: Document -> CRDT -> JSON-like interface
- **TimeTicket**: Logical clock with lamport + delimiter + actorID for conflict resolution
- **connect-swift**: gRPC communication with Yorkie server
- **Concurrency**: Swift async/await with Semaphore for synchronization
- **Build tag**: `SWIFT_TEST` defined for test targets
- Version in `Sources/Version.swift` must match git tag for SPM releases
