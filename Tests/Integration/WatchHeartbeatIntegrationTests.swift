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

import XCTest
@testable import Yorkie

// Port of yorkie-js-sdk packages/sdk/test/integration/watch_heartbeat_test.ts (#1483).
//
// A server with a per-stream heartbeat (yorkie#2209) clamps the interval a stream asks for into its
// own bounds, 5s to 60s by default, and advertises the result. These tests assert on what comes
// back rather than on a fixed number, and they skip rather than fail on a server that predates the
// feature: such a server ignores the request and advertises its own global setting instead.
//
// Requires a yorkie server at localhost:8080.

/// Collects the Watch responses a client's streams carry, which the client otherwise consumes
/// silently. Written from the transport's callback queue and read from the test.
private final class WatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var responses = [WatchResponse]()

    func record(_ response: WatchResponse) {
        self.lock.withLock { self.responses.append(response) }
    }

    /// The interval the init response advertised, or `nil` before it arrived.
    var advertised: Int64? {
        self.lock.withLock {
            for response in self.responses {
                if case .initialization(let initialization)? = response.body {
                    return initialization.heartbeatIntervalMs
                }
            }
            return nil
        }
    }

    var heartbeats: Int {
        self.lock.withLock {
            self.responses.filter { if case .heartbeat? = $0.body { return true } else { return false } }.count
        }
    }
}

final class WatchHeartbeatIntegrationTests: XCTestCase {
    private let rpcAddress = "http://localhost:8080"
    private let requestedIntervalMs = 1000
    // A stream advertised more than this would outlast the test waiting for its first heartbeat.
    private let maxWaitableIntervalMs: Int64 = 20000
    // Longer than the 5s default minimum, so a server heartbeating a no-heartbeat stream shows up.
    private let noHeartbeatWindow: TimeInterval = 8

    @MainActor
    private func makeClient(interval: Int) async throws -> (Client, WatchRecorder) {
        let client = Client(self.rpcAddress, ClientOptions(watchHeartbeatInterval: interval), isMockingEnabled: true)
        let recorder = WatchRecorder()
        client.observeWatchResponses { recorder.record($0) }
        try await client.activate()
        return (client, recorder)
    }

    /// Polls until `ready` holds, with an expectation as the clock rather than a sleep.
    private func waitFor(_ what: String, timeout: TimeInterval, _ ready: @escaping @Sendable () -> Bool) async {
        let expectation = XCTestExpectation(description: what)
        let poller = Task.detached {
            while !ready(), !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if ready() { expectation.fulfill() }
        }
        await fulfillment(of: [expectation], timeout: timeout)
        poller.cancel()
    }

    private func awaitAdvertised(_ recorder: WatchRecorder) async throws -> Int64 {
        await self.waitFor("init response", timeout: 5) { recorder.advertised != nil }
        return try XCTUnwrap(recorder.advertised, "the watch stream never delivered its init response")
    }

    private func skipReason(_ interval: Int64) -> String? {
        if interval == 0 {
            return "the server sends no heartbeats; it predates the per-stream heartbeat interval (yorkie#2209)"
        }
        if interval > self.maxWaitableIntervalMs {
            return "the server advertised \(interval)ms, too long to wait for a heartbeat here"
        }
        return nil
    }

    @MainActor
    func test_advertises_the_clamped_interval_on_a_document_stream_and_heartbeats_it() async throws {
        let (client, recorder) = try await self.makeClient(interval: self.requestedIntervalMs)
        let doc = Document(key: "\(Date().timeIntervalSince1970)-\(self.name)".toDocKey)
        try await client.attach(doc)

        let interval = try await self.awaitAdvertised(recorder)
        if let reason = self.skipReason(interval) {
            try await client.deactivate()
            throw XCTSkip(reason)
        }

        // A request under the minimum is clamped up, and the effective value advertised.
        XCTAssertGreaterThanOrEqual(interval, Int64(self.requestedIntervalMs))
        await self.waitFor("a heartbeat", timeout: TimeInterval(interval) * 2 / 1000 + 5) { recorder.heartbeats > 0 }
        XCTAssertGreaterThan(recorder.heartbeats, 0)

        try await client.deactivate()
    }

    @MainActor
    func test_advertises_the_clamped_interval_on_a_channel_stream_and_heartbeats_it() async throws {
        let (client, recorder) = try await self.makeClient(interval: self.requestedIntervalMs)
        let channel = try Channel(key: "\(Date().timeIntervalSince1970)-\(self.name)".toDocKey)
        _ = try await client.attachChannel(channel)

        let interval = try await self.awaitAdvertised(recorder)
        if let reason = self.skipReason(interval) {
            try await client.deactivate()
            throw XCTSkip(reason)
        }

        XCTAssertGreaterThanOrEqual(interval, Int64(self.requestedIntervalMs))
        await self.waitFor("a heartbeat", timeout: TimeInterval(interval) * 2 / 1000 + 5) { recorder.heartbeats > 0 }
        XCTAssertGreaterThan(recorder.heartbeats, 0)

        try await client.deactivate()
    }

    @MainActor
    func test_sends_no_heartbeat_to_a_stream_that_asked_for_none() async throws {
        // This is also how an SDK older than the field is served, which is what makes heartbeats
        // safe to leave on.
        let (client, recorder) = try await self.makeClient(interval: 0)
        let doc = Document(key: "\(Date().timeIntervalSince1970)-\(self.name)".toDocKey)
        try await client.attach(doc)

        let interval = try await self.awaitAdvertised(recorder)
        if interval != 0 {
            // The request was ignored: a server without yorkie#2209 heartbeats every stream or none.
            try await client.deactivate()
            throw XCTSkip("the server advertised \(interval)ms to a stream that asked for none; it predates yorkie#2209")
        }

        // Longer than the minimum interval, so a heartbeat would have arrived.
        let window = XCTestExpectation(description: "no-heartbeat window")
        DispatchQueue.main.asyncAfter(deadline: .now() + self.noHeartbeatWindow) { window.fulfill() }
        await fulfillment(of: [window], timeout: self.noHeartbeatWindow + 5)
        XCTAssertEqual(recorder.heartbeats, 0)

        try await client.deactivate()
    }
}
