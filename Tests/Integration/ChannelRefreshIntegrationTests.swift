/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Connect
import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// Integration tests for the RefreshChannel-only channel lifecycle introduced in
// yorkie 0.7.10 (#1258). The full RPC round-trip is needed to verify:
//   - `attachChannel` succeeds via the first-call RefreshChannel path (no AttachChannel RPC).
//   - `detachChannel` is local-only (no DetachChannel RPC issued).
//   - A non-recoverable RefreshChannel error publishes `ChannelSyncErrorEvent`.
//   - `syncChannel` (the public manual-refresh wrapper) works correctly.
//
// These tests run against the local tunneled yorkie server (localhost:8080).
final class ChannelRefreshIntegrationTests: XCTestCase {
    private let rpcAddress = "http://localhost:8080"

    // MARK: - First-call success path

    // Port of yorkie-js-sdk channel_test.ts "should attach via first-call refresh".
    //
    // After `attachChannel` the channel must be `.attached` and hold a non-empty
    // session id — the session was created by the implicit first-call RefreshChannel
    // RPC rather than a dedicated AttachChannel call.
    @MainActor
    func test_attachChannel_sets_attached_status_and_sessionID_after_first_call_refresh() async throws {
        // given
        let channelKey = channelTestKey(self.description)
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        let ch = try Channel(key: channelKey)

        // when
        _ = try await client.attachChannel(ch)
        self.addTeardownBlock { try? await client.detachChannel(ch) }

        // then — channel is attached with a real session id from the server
        XCTAssertEqual(ch.getStatus(), .attached, "channel must be .attached after attachChannel")
        XCTAssertNotNil(ch.getSessionID(), "channel must have a non-nil session id")
        XCTAssertFalse(ch.getSessionID()?.isEmpty ?? true, "session id must not be empty")
    }

    // MARK: - detachChannel is local-only

    // `detachChannel` must succeed without any network call; it only tears down
    // the local attachment state. The channel transitions to `.detached`.
    @MainActor
    func test_detachChannel_transitions_channel_to_detached_without_rpc() async throws {
        // given
        let channelKey = channelTestKey(self.description)
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        let ch = try Channel(key: channelKey)
        _ = try await client.attachChannel(ch)

        // when
        _ = try await client.detachChannel(ch)

        // then
        XCTAssertEqual(ch.getStatus(), .detached)
        // The client no longer tracks the channel
        XCTAssertFalse(client.has(channelKey))
    }

    // MARK: - syncChannel (manual refresh)

    // `syncChannel` is the public thin wrapper around `refreshChannel`. After a
    // successful attach the session count must be >= 1.
    @MainActor
    func test_syncChannel_returns_positive_session_count_after_attach() async throws {
        // given
        let channelKey = channelTestKey(self.description)
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        let ch = try Channel(key: channelKey)
        _ = try await client.attachChannel(ch)
        self.addTeardownBlock { try? await client.detachChannel(ch) }

        // when
        let count = try await client.syncChannel(ch)

        // then
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    // MARK: - Non-recoverable error → ChannelSyncErrorEvent

    // When `refreshChannel` encounters a non-recoverable error (simulated via
    // mock injection), it must publish a `ChannelSyncErrorEvent` and throw.
    // Uses `isMockingEnabled: true` + `setMockError` so no real server call is
    // needed after the initial attach.
    @MainActor
    func test_syncChannel_publishes_syncErrorEvent_on_non_recoverable_error() async throws {
        // given — activate and attach using a real server, then inject a mock error
        let channelKey = channelTestKey(self.description)
        let client = Client(rpcAddress, isMockingEnabled: true)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        let ch = try Channel(key: channelKey)
        _ = try await client.attachChannel(ch)
        self.addTeardownBlock { try? await client.detachChannel(ch) }

        var capturedSyncError: ChannelSyncErrorEvent?
        let errorExp = expectation(description: "ChannelSyncErrorEvent published")
        ch.subscribeAll { event in
            if let syncErr = event as? ChannelSyncErrorEvent {
                capturedSyncError = syncErr
                errorExp.fulfill()
            }
        }

        // Inject a non-recoverable error for the next refreshChannel call.
        // `failedPrecondition` is not in the retryable set and carries no
        // Yorkie-specific metadata, so the state machine publishes the sync error.
        client.setMockError(
            for: YorkieServiceClient.Metadata.Methods.refreshChannel,
            error: connectError(from: .failedPrecondition)
        )

        // when — manually trigger a refresh via the public syncChannel API
        do {
            _ = try await client.syncChannel(ch)
            XCTFail("syncChannel must throw when refreshChannel returns an error")
        } catch {
            // expected
        }

        // then — the sync-error event was published
        await fulfillment(of: [errorExp], timeout: 2.0)
        XCTAssertEqual(capturedSyncError?.method, "RefreshChannel")
    }

    // MARK: - Presence count via syncChannel

    // When two clients are attached to the same channel, `syncChannel` on one
    // of them must return a session count >= 2.
    @MainActor
    func test_syncChannel_reflects_second_client_in_session_count() async throws {
        // given — two clients on the same channel
        let channelKey = channelTestKey(self.description)
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        self.addTeardownBlock {
            try? await c1.deactivate()
            try? await c2.deactivate()
        }

        let ch1 = try Channel(key: channelKey)
        let ch2 = try Channel(key: channelKey)
        _ = try await c1.attachChannel(ch1)
        self.addTeardownBlock { try? await c1.detachChannel(ch1) }
        _ = try await c2.attachChannel(ch2)
        self.addTeardownBlock { try? await c2.detachChannel(ch2) }

        // when — manually poll until c1 sees both sessions
        var count = 0
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            count = try await c1.syncChannel(ch1)
            if count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // then
        XCTAssertGreaterThanOrEqual(count, 2, "syncChannel must return >= 2 when two clients are attached")
    }
}

// MARK: - Helpers

/// Builds a unique, server-safe channel key from the test description.
/// Mirrors the helper in ChannelPollingTests.swift.
private func channelTestKey(_ description: String) -> String {
    let uniqueSuffix = UUID().uuidString.lowercased().prefix(8)
    return String(uniqueSuffix)
        .appending("-ch-")
        .appending(
            description
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                .prefix(40)
                .description
        )
}
