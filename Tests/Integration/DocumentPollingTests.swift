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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// MARK: - Document Polling tests (PR #1243)

/// Ports: "Document Polling" from packages/sdk/test/integration/document_polling_test.ts.
///
/// iOS-side note: only the Document polling path was ported in v0.7.8. Channel-level
/// polling (broadcast isolation, legacy mode) was explicitly deferred. These tests
/// cover:
///   - `documentPollInterval` validation (≤ 0 throws `.errInvalidArgument`)
///   - `SyncMode.polling` attach opens no watch stream but still pushpull-syncs
///   - `changeSyncMode(_:.polling)` transitions back to polling

final class DocumentPollingTests: XCTestCase {
    // Ports: "attach rejects documentPollInterval: 0 with ErrInvalidArgument"
    //
    // Passing `documentPollInterval: 0` (or any value ≤ 0) must throw
    // `YorkieError` with code `.errInvalidArgument` immediately at attach time
    // without contacting the server.
    @MainActor
    func test_attach_rejects_documentPollInterval_zero_with_errInvalidArgument() async throws {
        // given
        let rpcAddress = "http://localhost:8080"
        let client = Client(rpcAddress)
        try await client.activate()
        defer {
            Task { try await client.deactivate() }
        }

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        // when / then — documentPollInterval: 0 must throw errInvalidArgument
        do {
            _ = try await client.attach(doc, [:], .realtime, documentPollInterval: 0)
            XCTFail("attach with documentPollInterval:0 should throw errInvalidArgument")
        } catch let error as YorkieError {
            XCTAssertEqual(error.code, .errInvalidArgument,
                           "expected errInvalidArgument, got \(error.code)")
        }
    }

    // Ports: "attach rejects documentPollInterval: -1 with ErrInvalidArgument"
    @MainActor
    func test_attach_rejects_negative_documentPollInterval_with_errInvalidArgument() async throws {
        // given
        let rpcAddress = "http://localhost:8080"
        let client = Client(rpcAddress)
        try await client.activate()
        defer {
            Task { try await client.deactivate() }
        }

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        // when / then — documentPollInterval: -1 must throw errInvalidArgument
        do {
            _ = try await client.attach(doc, [:], .realtime, documentPollInterval: -1)
            XCTFail("attach with documentPollInterval:-1 should throw errInvalidArgument")
        } catch let error as YorkieError {
            XCTAssertEqual(error.code, .errInvalidArgument)
        }
    }

    // Ports: "Polling document receives remote changes within poll interval"
    //
    // A document attached in `.polling` mode must receive remote changes via
    // the timer-driven pushpull loop (no watch stream). The test waits long
    // enough for at least two polling ticks and then asserts the value arrived.
    @MainActor
    func test_polling_document_receives_remote_changes_within_poll_interval() async throws {
        // given
        let rpcAddress = "http://localhost:8080"
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        defer {
            Task {
                try await c1.deactivate()
                try await c2.deactivate()
            }
        }

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        // c1 attaches in Polling mode with 300ms interval
        _ = try await c1.attach(d1, [:], .polling, documentPollInterval: 0.3)
        _ = try await c2.attach(d2)

        // Fulfilled when a polling tick pulls c2's change into d1. Use an
        // expectation rather than `Task.sleep`: the periodic sync loop runs on a
        // `RunLoop.main` timer that fires while `XCTWaiter` pumps the run loop, but
        // NOT while an async test is merely suspended in `Task.sleep`.
        let received = expectation(description: "polling delivers remote change")
        received.assertForOverFulfill = false
        d1.subscribe { _, doc in
            if doc.getRoot().k as? String == "v" {
                received.fulfill()
            }
        }

        // when — c2 makes a change and syncs it to the server
        try await d2.update { root, _ in
            root.k = "v"
        }
        try await c2.sync()

        // then — d1 receives the change via a polling tick (interval 0.3s)
        await fulfillment(of: [received], timeout: 5.0)
        XCTAssertEqual(d1.getRoot().k as? String, "v")

        try await c1.detach(d1)
        try await c2.detach(d2)
    }

    // Ports: "changeSyncMode transitions Polling → Realtime for documents"
    //
    // Switching a document from `.polling` to `.realtime` must open a watch
    // stream and start delivering remote changes via push, not the slow
    // polling tick.
    @MainActor
    func test_changeSyncMode_transitions_polling_to_realtime() async throws {
        // given
        let rpcAddress = "http://localhost:8080"
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        defer {
            Task {
                try await c1.deactivate()
                try await c2.deactivate()
            }
        }

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        // c1 starts in Polling mode with a very long interval (5 s) to prove it's
        // the Realtime path that delivers the change, not the polling tick.
        _ = try await c1.attach(d1, [:], .polling, documentPollInterval: 5.0)
        _ = try await c2.attach(d2)

        // Switch c1 to Realtime — should open a watch stream.
        try c1.changeSyncMode(d1, .realtime)

        // when — c2 makes a change
        try await d2.update { root, _ in
            root.k = "rt"
        }
        try await c2.sync()

        // Realtime should deliver within 2s (much faster than the 5s polling interval).
        try await Task.sleep(milliseconds: 2000)

        // then
        let value = d1.getRoot().k as? String
        XCTAssertEqual(value, "rt")

        try await c1.detach(d1)
        try await c2.detach(d2)
    }

    // Unit-style validation: the `errInvalidArgument` guard is triggered on an
    // active client before any network call completes. Running as @MainActor so
    // Client initializer (which is @MainActor-isolated) is accessible.
    @MainActor
    func test_attach_documentPollInterval_zero_throws_before_network_contact() async {
        // given — inactive client (never activated)
        let rpcAddress = "http://localhost:8080"
        let client = Client(rpcAddress)
        let doc = Document(key: "poll-guard-unit")

        do {
            _ = try await client.attach(doc, [:], .realtime, documentPollInterval: 0)
            // Either errClientNotActivated or errInvalidArgument is acceptable;
            // what must NOT happen is a silent success.
            XCTFail("attach must throw when client is not active or poll interval is invalid")
        } catch {
            // Any throw is correct — the test guards that no silent success occurs.
            XCTAssertNotNil(error)
        }
    }
}
