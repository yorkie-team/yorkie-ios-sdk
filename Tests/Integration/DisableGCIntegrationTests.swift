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

    // Ports (v0.7.11 #1270): "Opt-out clients keep per-Change VV at size 1 under multi-actor fanout"
    //
    // Regression for the bug where each opt-out client's Change.ID.versionVector accumulated
    // O(num_actors) entries because applyChanges -> syncClocks merged every remote actor. After
    // the syncLamport fix the per-Change VV must stay at size 1.
    @MainActor
    func test_optout_clients_keep_per_change_vv_at_size_1_under_multi_actor_fanout() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        let c3 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        try await c3.activate()
        self.addTeardownBlock {
            try? await c1.deactivate()
            try? await c2.deactivate()
            try? await c3.deactivate()
        }

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)
        let d3 = Document(key: docKey)
        try await c1.attach(d1, [:], .manual, disableGC: true)
        try await c2.attach(d2, [:], .manual, disableGC: true)
        try await c3.attach(d3, [:], .manual, disableGC: true)
        self.addTeardownBlock {
            try? await c1.detach(d1)
            try? await c2.detach(d2)
            try? await c3.detach(d3)
        }

        try d1.update { root, _ in
            root.counter = JSONCounter(value: Int64(0))
        }
        try await c1.sync()
        try await c2.sync()
        try await c3.sync()

        // when — every client increments independently for three rounds
        for _ in 0 ..< 3 {
            try d1.update { root, _ in (root.counter as? JSONCounter<Int64>)?.increase(value: 1) }
            try d2.update { root, _ in (root.counter as? JSONCounter<Int64>)?.increase(value: 1) }
            try d3.update { root, _ in (root.counter as? JSONCounter<Int64>)?.increase(value: 1) }
            try await c1.sync()
            try await c2.sync()
            try await c3.sync()
        }
        // Drain remaining pushed changes so every client sees them.
        try await c1.sync()
        try await c2.sync()
        try await c3.sync()
        try await c1.sync()

        // then — all converge to 9 ...
        XCTAssertEqual((d1.getRoot().counter as? JSONCounter<Int64>)?.value, 9)
        XCTAssertEqual((d2.getRoot().counter as? JSONCounter<Int64>)?.value, 9)
        XCTAssertEqual((d3.getRoot().counter as? JSONCounter<Int64>)?.value, 9)

        // ... and every opt-out doc's per-Change VV stays at size 1.
        for (idx, doc) in [d1, d2, d3].enumerated() {
            XCTAssertEqual(doc.getVersionVector().size(), 1, "opt-out doc[\(idx)] versionVector must stay at size 1")
        }
    }

    // Attaching with `disableGC: true` selects the lamport-only sync path but must NOT disable
    // local garbage collection when the document was constructed with GC enabled — mirroring the
    // JS split between `opts.disableGC` (gates GC) and the attach-time `disableGC` (gates sync).
    @MainActor
    func test_disableGC_attach_does_not_disable_local_garbage_collection() async throws {
        // given — a normally constructed document (GC enabled) attached with disableGC = true
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual, disableGC: true)
        self.addTeardownBlock { try? await client.detach(doc) }

        // when — create then remove an element, producing tombstones
        try doc.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }
        try await client.sync()
        try doc.update { root, _ in
            root.remove(key: "point")
        }
        try await client.sync()

        XCTAssertEqual(doc.getGarbageLength(), 3, "point, x, y are pending purge")

        // then — GC still runs (returns > 0) despite the disableGC attach option
        let purged = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [client.id]))
        XCTAssertEqual(purged, 3, "local GC must still purge for a GC-enabled document")
    }
}
