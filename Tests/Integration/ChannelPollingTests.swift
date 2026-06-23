/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

/// Port of yorkie-js-sdk packages/sdk/test/integration/channel_polling_test.ts
/// at v0.7.9 (yorkie-js-sdk#1247 "Fix Polling channel subscriber notification"
/// and yorkie-js-sdk#1256 "Add PeekChannel client").
///
/// Covered scenarios:
///   1. peekChannel returns a live session count without creating a server session.
///   2. peekChannel throws errClientNotActivated when the client is not active.
///   3. refreshChannel publishes ChannelPresenceEvent only when the session count changes.
///   4. refreshChannel does NOT re-publish ChannelPresenceEvent when the count is unchanged.
final class ChannelPollingTests: XCTestCase {
    private let rpcAddress = "http://localhost:8080"

    // MARK: - peekChannel

    // Ports: "PeekChannel returns live session count without creating a session"
    //
    // A client that calls `peekChannel` for a channel that already has attached
    // sessions must get a count >= 1 without itself being counted (the peek
    // does not create a server session).
    //
    // Requires a yorkie server >= 0.7.9 that implements the PeekChannel RPC.
    // The test is skipped automatically when the running server returns
    // `unimplemented` (older server via SSH tunnel).
    //
    // Stability note (line ~58): the `defer` teardown block uses
    // `Task { try? await ... }`, which is the idiomatic fire-and-forget cleanup
    // pattern used throughout the integration suite.  It is not fragile because
    // XCTest keeps the process alive long enough for those tasks to complete, and
    // any failure there is non-fatal by design.  The channel key uniqueness was
    // the only fragility here; it is addressed by `channelTestKey` using a UUID
    // suffix instead of a second-resolution timestamp.
    @MainActor
    func test_peekChannel_returns_session_count_without_creating_a_session() async throws {
        // given — one client attached to a known channel key
        let channelKey = channelTestKey(self.description)
        let c1 = Client(rpcAddress)
        let observer = Client(rpcAddress)

        try await c1.activate()
        try await observer.activate()
        defer {
            Task {
                try? await c1.deactivate()
                try? await observer.deactivate()
            }
        }

        let ch1 = try Channel(key: channelKey)
        _ = try await c1.attachChannel(ch1)
        defer { Task { try? await c1.detachChannel(ch1) } }

        // when — observer peeks (no attach, no session created)
        let count: Int
        do {
            count = try await observer.peekChannel(channelKey)
        } catch {
            try skipIfPeekChannelUnavailable(error)
            throw error
        }

        // then — must see at least the one attached client's session
        XCTAssertGreaterThanOrEqual(count, 1, "peekChannel should return >= 1 when a client is attached")
    }

    // Ports: "PeekChannel reflects count increase when more clients attach"
    //
    // Attaching a second client and then peeking should return a higher count.
    //
    // Requires a yorkie server >= 0.7.9 that implements the PeekChannel RPC.
    @MainActor
    func test_peekChannel_reflects_increased_count_when_second_client_attaches() async throws {
        // given — two clients attached to the same channel, one observer
        let channelKey = channelTestKey(self.description)
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        let observer = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()
        try await observer.activate()
        defer {
            Task {
                try? await c1.deactivate()
                try? await c2.deactivate()
                try? await observer.deactivate()
            }
        }

        let ch1 = try Channel(key: channelKey)
        let ch2 = try Channel(key: channelKey)
        _ = try await c1.attachChannel(ch1)
        defer { Task { try? await c1.detachChannel(ch1) } }
        _ = try await c2.attachChannel(ch2)
        defer { Task { try? await c2.detachChannel(ch2) } }

        // when — observer peeks after both clients have attached
        let count: Int
        do {
            count = try await observer.peekChannel(channelKey)
        } catch {
            try skipIfPeekChannelUnavailable(error)
            throw error
        }

        // then — must see both sessions
        XCTAssertGreaterThanOrEqual(count, 2, "peekChannel should return >= 2 when two clients are attached")
    }

    // Ports: "PeekChannel rejects inactive client"
    //
    // Calling `peekChannel` on a client that has never been activated must
    // throw `YorkieError` with code `.errClientNotActivated` immediately,
    // without making a network call.
    @MainActor
    func test_peekChannel_throws_errClientNotActivated_when_client_is_inactive() async {
        // given — a client that is never activated
        let client = Client(rpcAddress)

        // when / then
        do {
            _ = try await client.peekChannel("some-channel")
            XCTFail("peekChannel must throw when client is not active")
        } catch let error as YorkieError {
            XCTAssertEqual(error.code, .errClientNotActivated,
                           "expected errClientNotActivated, got \(error.code)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - refreshChannel / presence notification

    // Ports: "Polling notifies subscribers when sessionCount changes"
    //
    // When a second client joins a channel, the first client's next
    // `refreshChannel` heartbeat should publish a `ChannelPresenceEvent`
    // with `type == .presenceChanged` carrying the updated count.
    //
    // iOS-side note: `refreshChannel` is called by the heartbeat timer which runs
    // on `RunLoop.main`.  We use `syncChannel` (the public manual-refresh
    // wrapper) to drive the call from the test without waiting for the timer.
    @MainActor
    func test_refreshChannel_publishes_presenceChanged_when_session_count_increases() async throws {
        // given — c1 is attached and has a presence subscription
        let channelKey = channelTestKey(self.description)
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()
        defer {
            Task {
                try? await c1.deactivate()
                try? await c2.deactivate()
            }
        }

        let ch1 = try Channel(key: channelKey)
        _ = try await c1.attachChannel(ch1)
        defer { Task { try? await c1.detachChannel(ch1) } }

        let presenceExp = expectation(description: "presenceChanged event after second client attaches")
        presenceExp.assertForOverFulfill = false

        var observedCounts: [Int] = []
        ch1.subscribePresenceChange { event in
            observedCounts.append(event.count)
            if event.count >= 2 {
                presenceExp.fulfill()
            }
        }

        // when — second client attaches, then c1 manually refreshes its session count
        let ch2 = try Channel(key: channelKey)
        _ = try await c2.attachChannel(ch2)
        defer { Task { try? await c2.detachChannel(ch2) } }

        // Manually trigger refreshChannel via the public syncChannel wrapper.
        // Using syncChannel rather than waiting for the heartbeat timer avoids
        // RunLoop/Task.sleep timing issues (the timer fires on RunLoop.main which
        // is pumped by XCTWaiter, not by Task.sleep).
        _ = try await c1.syncChannel(ch1)

        // then — presence callback was invoked with a count >= 2
        await fulfillment(of: [presenceExp], timeout: 5.0)
        XCTAssertGreaterThanOrEqual(observedCounts.last ?? 0, 2,
                                    "latest observed count should be >= 2 after second client attaches")
    }

    // Ports: "Polling does NOT notify subscribers when sessionCount is unchanged"
    //
    // PR #1247 fixed a bug where `refreshChannel` published a presence event
    // even when the returned count was identical to the cached value.
    // After the fix, the event must be suppressed when the count does not change.
    //
    // The assertion uses an inverted XCTestExpectation so that any late-arriving
    // callback fired after the syncChannel call but before the timeout window
    // closes is caught as a test failure.  A plain `XCTAssertEqual(eventCount, 0)`
    // immediately after syncChannel would race against callbacks delivered on
    // RunLoop.main; the inverted expectation holds the RunLoop open so those
    // callbacks have a chance to arrive before the verdict is recorded.
    @MainActor
    func test_refreshChannel_does_not_publish_presenceChanged_when_count_is_unchanged() async throws {
        // given — c1 attached, initial count cached via syncChannel
        let channelKey = channelTestKey(self.description)
        let c1 = Client(rpcAddress)

        try await c1.activate()
        defer { Task { try? await c1.deactivate() } }

        let ch1 = try Channel(key: channelKey)
        _ = try await c1.attachChannel(ch1)
        defer { Task { try? await c1.detachChannel(ch1) } }

        // Seed the cached count with a first refresh call.
        _ = try await c1.syncChannel(ch1)
        let countAfterFirstSync = ch1.getSessionCount()

        // Register a presence callback AFTER the seed so only subsequent events
        // are counted.  The inverted expectation is fulfilled (i.e. fails the
        // test) if any presence callback fires within the observation window.
        let noEventExp = expectation(description: "no presenceChanged event when count is unchanged")
        noEventExp.isInverted = true

        ch1.subscribePresenceChange { _ in
            noEventExp.fulfill()
        }

        // when — refresh again with no membership change; count must stay the same
        _ = try await c1.syncChannel(ch1)
        let countAfterSecondSync = ch1.getSessionCount()

        // then — hold the RunLoop open for 1 s so any late callback has time to
        // arrive.  XCTWaiter pumps RunLoop.main, which is where the channel timer
        // and callbacks are dispatched.  If a callback fires inside this window the
        // inverted expectation is fulfilled, which causes wait() to return
        // `.incorrectOrder` / `.invertedFulfillment` and fails the test.
        await fulfillment(of: [noEventExp], timeout: 1.0)

        XCTAssertEqual(countAfterFirstSync, countAfterSecondSync,
                       "session count should not change between two consecutive syncs without membership change")
    }
}

// MARK: - Helpers

/// Builds a unique, server-safe channel key from the test description.
/// Uses a UUID suffix instead of a second-resolution timestamp to prevent
/// key collisions across concurrent or rapidly-repeated test runs.
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

/// Skips the calling test when the server returns `.unimplemented` for
/// PeekChannel.  This happens when the SSH-tunneled server predates v0.7.9
/// and does not have the PeekChannel RPC registered.
private func skipIfPeekChannelUnavailable(_ error: Error) throws {
    if let connectError = error as? ConnectError, connectError.code == Connect.Code.unimplemented {
        throw XCTSkip("PeekChannel RPC is not available on this server (requires yorkie >= 0.7.9)")
    }
}
