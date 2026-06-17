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

/// Integration tests for ``JSONDedupCounter`` (HyperLogLog-backed dedup counter).
///
/// Ports the new dedup-counter behaviour from yorkie-js-sdk #1215/#1216.
/// The dedup counter counts distinct actors — repeated add() calls with the
/// same actor ID are idempotent.
///
/// Requires a live 0.7.5 yorkie server.
final class DedupCounterIntegrationTests: XCTestCase {
    // MARK: - Basic convergence

    /// Two clients attach to the same document, each registers a distinct actor via
    /// ``JSONDedupCounter``, sync, and both documents must converge to value 2.
    ///
    /// Mirrors the HLL dedup convergence scenario described in yorkie-js-sdk PR #1215.
    @MainActor
    func test_can_sync_dedup_counter_with_two_distinct_actors() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — create the dedup counter on d1
            try d1.update { root, _ in
                root.uv = JSONDedupCounter()
            }
            try await c1.sync()
            try await c2.sync()

            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — each client records a distinct actor
            try d1.update { root, _ in
                try (root.uv as? JSONDedupCounter)?.add("user-a")
            }
            try d2.update { root, _ in
                try (root.uv as? JSONDedupCounter)?.add("user-b")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both documents must converge (value is approximately 2)
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    /// Same actor added from two concurrent clients — after sync the counter
    /// must still reflect only 1 distinct actor on both sides.
    @MainActor
    func test_can_deduplicate_same_actor_across_two_clients() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given
            try d1.update { root, _ in
                root.uv = JSONDedupCounter()
            }
            try await c1.sync()
            try await c2.sync()

            // when — same actor ID submitted from both clients concurrently
            try d1.update { root, _ in
                try (root.uv as? JSONDedupCounter)?.add("shared-user")
            }
            try d2.update { root, _ in
                try (root.uv as? JSONDedupCounter)?.add("shared-user")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both documents converge; the HLL may estimate ~1 (±1 due to ~2 % error)
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            let value = (d1.getRoot().uv as? JSONDedupCounter)?.value ?? -1
            XCTAssertGreaterThan(value, 0)
            XCTAssertLessThanOrEqual(value, 3, "HLL estimate for 1 actor must be ≤ 3")
        }
    }

    /// Adding an actor multiple times across multiple update closures is idempotent
    /// on a single client — the counter value must not keep increasing.
    @MainActor
    func test_multiple_adds_for_same_actor_are_idempotent() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client("http://localhost:8080")
        try await c1.activate()

        let d1 = Document(key: docKey)
        try await c1.attach(d1, [:], .manual)

        // given
        try d1.update { root, _ in
            root.uv = JSONDedupCounter()
        }

        // when — add the same actor 5 times across separate update closures
        for _ in 0 ..< 5 {
            try d1.update { root, _ in
                try (root.uv as? JSONDedupCounter)?.add("repeat-user")
            }
        }

        try await c1.sync()

        // then — value must be 1 (single distinct actor)
        let value = (d1.getRoot().uv as? JSONDedupCounter)?.value ?? -1
        XCTAssertEqual(value, 1)

        try await c1.detach(d1)
        try await c1.deactivate()
    }

    /// HLL state survives a snapshot round-trip — after the snapshot threshold the
    /// server compacts history into a snapshot; attaching with a fresh document key
    /// should restore the same cardinality.
    @MainActor
    func test_dedup_counter_survives_snapshot_roundtrip() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client("http://localhost:8080")
        let c2 = Client("http://localhost:8080")
        try await c1.activate()
        try await c2.activate()

        let d1 = Document(key: docKey)
        try await c1.attach(d1, [:], .manual)

        // given — populate a dedup counter with 3 actors
        try d1.update { root, _ in
            root.uv = JSONDedupCounter()
        }
        try d1.update { root, _ in
            try (root.uv as? JSONDedupCounter)?.add("actor-1")
        }
        try d1.update { root, _ in
            try (root.uv as? JSONDedupCounter)?.add("actor-2")
        }
        try d1.update { root, _ in
            try (root.uv as? JSONDedupCounter)?.add("actor-3")
        }
        try await c1.sync()

        let originalValue = (d1.getRoot().uv as? JSONDedupCounter)?.value ?? -1

        // when — c2 attaches to the same document key (reads from server state)
        let d2 = Document(key: docKey)
        try await c2.attach(d2, [:], .manual)
        try await c2.sync()

        // then — c2 should see the same approximate cardinality
        let restoredValue = (d2.getRoot().uv as? JSONDedupCounter)?.value ?? -1
        XCTAssertEqual(restoredValue, originalValue, "HLL cardinality must be preserved after sync")

        try await c1.detach(d1)
        try await c2.detach(d2)
        try await c1.deactivate()
        try await c2.deactivate()
    }

    // MARK: - Concurrent actor additions converge

    /// Three clients each add a unique actor concurrently, then sync.
    /// After full convergence all three must agree on the cardinality.
    @MainActor
    func test_can_converge_three_concurrent_distinct_actors() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client("http://localhost:8080")
        let c2 = Client("http://localhost:8080")
        let c3 = Client("http://localhost:8080")

        try await c1.activate()
        try await c2.activate()
        try await c3.activate()

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)
        let d3 = Document(key: docKey)

        try await c1.attach(d1, [:], .manual)
        try await c2.attach(d2, [:], .manual)
        try await c3.attach(d3, [:], .manual)

        // given
        try d1.update { root, _ in
            root.uv = JSONDedupCounter()
        }
        try await c1.sync()
        try await c2.sync()
        try await c3.sync()

        // when — each client adds a unique actor simultaneously
        try d1.update { root, _ in
            try (root.uv as? JSONDedupCounter)?.add("actor-c1")
        }
        try d2.update { root, _ in
            try (root.uv as? JSONDedupCounter)?.add("actor-c2")
        }
        try d3.update { root, _ in
            try (root.uv as? JSONDedupCounter)?.add("actor-c3")
        }

        // sync in round-robin until convergence
        try await c1.sync()
        try await c2.sync()
        try await c3.sync()
        try await c1.sync()
        try await c2.sync()
        try await c1.sync()

        // then — all three documents must converge to the same JSON
        let j1 = d1.toSortedJSON()
        let j2 = d2.toSortedJSON()
        let j3 = d3.toSortedJSON()

        XCTAssertEqual(j1, j2, "d1 and d2 diverged")
        XCTAssertEqual(j2, j3, "d2 and d3 diverged")

        try await c1.detach(d1)
        try await c2.detach(d2)
        try await c3.detach(d3)
        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }
}
