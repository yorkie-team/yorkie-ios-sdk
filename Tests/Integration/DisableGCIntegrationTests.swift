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

// Port of yorkie-js-sdk packages/sdk/test/integration/disable_gc_test.ts at v0.7.10.
//
// Server-side semantics (skip minVV write, omit response VV) are validated in
// the yorkie server's own tests. These tests verify the SDK-side contract:
//   - The option is accepted by `attach`.
//   - Push-pull succeeds, and counter values converge when the flag is mixed.
//   - Re-attach without the flag restores normal sync behavior.
//
// Tests run against the local tunneled server (localhost:8080). They are
// structured as @MainActor to match every other integration test in this repo.
final class DisableGCIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    // Ports: "Can attach a Counter document with disableGC and sync without error"
    @MainActor
    func test_can_attach_with_disableGC_true_and_sync_without_error() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        // when
        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual, disableGC: true)
        self.addTeardownBlock { try? await client.detach(doc) }

        try doc.update { root, _ in
            root.counter = JSONCounter(value: Int64(0))
        }
        try await client.sync()

        // then — document synced successfully; the counter is reachable
        let value = (doc.getRoot().counter as? JSONCounter<Int64>)?.value
        XCTAssertEqual(value, 0)
    }

    // Ports: "Mixed opt-in and opt-out clients converge on the Counter value"
    @MainActor
    func test_mixed_disableGC_clients_converge_on_counter_value() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        self.addTeardownBlock {
            try? await c1.deactivate()
            try? await c2.deactivate()
        }

        // c1 attaches without disableGC (normal GC)
        let d1 = Document(key: docKey)
        try await c1.attach(d1, [:], .manual)
        self.addTeardownBlock { try? await c1.detach(d1) }

        try d1.update { root, _ in
            root.counter = JSONCounter(value: Int64(0))
        }
        try await c1.sync()

        // c2 attaches with disableGC = true
        let d2 = Document(key: docKey)
        try await c2.attach(d2, [:], .manual, disableGC: true)
        self.addTeardownBlock { try? await c2.detach(d2) }

        // when — both clients increment independently
        try d1.update { root, _ in
            (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
        }
        try d2.update { root, _ in
            (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
        }

        try await c1.sync()
        try await c2.sync()
        try await c1.sync()

        // then — both converge to 2
        let v1 = (d1.getRoot().counter as? JSONCounter<Int64>)?.value
        let v2 = (d2.getRoot().counter as? JSONCounter<Int64>)?.value
        XCTAssertEqual(v1, 2, "c1 counter must converge to 2")
        XCTAssertEqual(v2, 2, "c2 counter must converge to 2")
    }

    // Ports: "Re-attach without disableGC restores normal sync behavior"
    @MainActor
    func test_reattach_without_disableGC_restores_normal_sync() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        // when — first attach with disableGC = true
        let d1 = Document(key: docKey)
        try await client.attach(d1, [:], .manual, disableGC: true)
        try d1.update { root, _ in
            root.counter = JSONCounter(value: Int64(0))
            (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
        }
        try await client.sync()
        try await client.detach(d1)

        // re-attach on a fresh document without the option
        let d2 = Document(key: docKey)
        try await client.attach(d2, [:], .manual)
        self.addTeardownBlock { try? await client.detach(d2) }
        try d2.update { root, _ in
            (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
        }
        try await client.sync()

        // then — counter accumulated across both sessions
        let value = (d2.getRoot().counter as? JSONCounter<Int64>)?.value
        XCTAssertEqual(value, 2, "counter must be 2 after both increments sync")
    }

    // Additional: the disableGC flag does not prevent remote changes from landing.
    @MainActor
    func test_disableGC_client_receives_remote_changes_correctly() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        self.addTeardownBlock {
            try? await c1.deactivate()
            try? await c2.deactivate()
        }

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        // c2 opts out of GC
        try await c1.attach(d1, [:], .manual)
        self.addTeardownBlock { try? await c1.detach(d1) }
        try await c2.attach(d2, [:], .manual, disableGC: true)
        self.addTeardownBlock { try? await c2.detach(d2) }

        // when — c1 sets a key, then c2 syncs
        try d1.update { root, _ in
            root.message = "hello"
        }
        try await c1.sync()
        try await c2.sync()

        // then — c2 received the remote change despite GC being disabled
        let msg = d2.getRoot().message as? String
        XCTAssertEqual(msg, "hello")
    }
}
