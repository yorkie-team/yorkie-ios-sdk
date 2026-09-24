/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

/// Pins the ``DocStore`` contract that ``MemoryDocStore`` -- the reference implementation --
/// is documented to satisfy. A third-party backend is written against these same rules
/// (`DocStore.swift`'s doc comments), so this is the spec a custom implementation has to
/// match, not merely one possible behaviour of the shipped default.
///
/// `Tests/Unit/Core/ClientPersistenceTests.swift` already covers the plain
/// save/load/remove round trip on a snapshot with no log or meta; this file is specifically
/// the incremental-log half of the contract that shipped untested.
final class MemoryDocStoreContractTests: XCTestCase {
    // MARK: appendChange is an upsert keyed by clientSeq

    func test_appendchange_with_a_repeated_clientseq_replaces_rather_than_duplicates() async throws {
        // given: a snapshot to append against, and a first change at clientSeq 1.
        let store = MemoryDocStore()
        try await store.saveSnapshot(docKey: "doc-1", bytes: Data("snapshot".utf8))
        try await store.appendChange(docKey: "doc-1", change: StoredChange(clientSeq: 1, bytes: Data("first-attempt".utf8)))

        // when: the same clientSeq is appended again with different bytes -- a retried write,
        // the case the contract exists to make safe.
        try await store.appendChange(docKey: "doc-1", change: StoredChange(clientSeq: 1, bytes: Data("retried".utf8)))

        // then: one entry, holding the retried bytes rather than both.
        let loaded = try await store.load(docKey: "doc-1")
        let changes = try XCTUnwrap(loaded).changes
        XCTAssertEqual(changes.count, 1, "a repeated clientSeq must replace, not append, a second entry")
        XCTAssertEqual(changes[0].bytes, Data("retried".utf8))
    }

    // MARK: appendChange keeps the log ordered

    func test_appendchange_out_of_order_still_returns_changes_ascending_by_clientseq() async throws {
        // given: a snapshot, then changes appended out of the order they were minted in --
        // exactly what a retried or reordered write could produce.
        let store = MemoryDocStore()
        try await store.saveSnapshot(docKey: "doc-1", bytes: Data("snapshot".utf8))

        try await store.appendChange(docKey: "doc-1", change: StoredChange(clientSeq: 3, bytes: Data("c3".utf8)))
        try await store.appendChange(docKey: "doc-1", change: StoredChange(clientSeq: 1, bytes: Data("c1".utf8)))
        try await store.appendChange(docKey: "doc-1", change: StoredChange(clientSeq: 2, bytes: Data("c2".utf8)))

        // then: `load` must hand back an ascending run, since a restore replays the log in
        // that order and cannot re-sort it itself (the interface only promises order, not
        // that the caller re-derives it).
        let loaded = try await store.load(docKey: "doc-1")
        let clientSeqs = try XCTUnwrap(loaded).changes.map(\.clientSeq)
        XCTAssertEqual(clientSeqs, [1, 2, 3])
    }

    // MARK: saveSnapshot compacts: log and meta both go

    func test_savesnapshot_drops_both_the_appended_log_and_any_stored_meta() async throws {
        // given: a snapshot with an appended log and a recorded header -- the state a
        // document accumulates between compactions.
        let store = MemoryDocStore()
        try await store.saveSnapshot(docKey: "doc-1", bytes: Data("first-snapshot".utf8))
        try await store.appendChange(docKey: "doc-1", change: StoredChange(clientSeq: 1, bytes: Data("c1".utf8)))
        try await store.saveMeta(docKey: "doc-1", bytes: Data("header".utf8))

        let beforeCompaction = try await store.load(docKey: "doc-1")
        XCTAssertEqual(beforeCompaction?.changes.count, 1)
        XCTAssertNotNil(beforeCompaction?.meta)

        // when: compaction folds the log into a fresh snapshot.
        try await store.saveSnapshot(docKey: "doc-1", bytes: Data("compacted-snapshot".utf8))

        // then: both the log and the header are gone -- keeping either would either replay a
        // change already embedded in the new snapshot, or apply a header newer than what the
        // new snapshot's own checkpoint carries.
        let afterCompaction = try await store.load(docKey: "doc-1")
        XCTAssertEqual(afterCompaction?.snapshot, Data("compacted-snapshot".utf8))
        XCTAssertEqual(afterCompaction?.changes, [], "compaction must drop the appended log")
        XCTAssertNil(afterCompaction?.meta, "compaction must drop the stored header")
    }

    // MARK: appendChange / saveMeta on a key with nothing stored

    func test_appendchange_on_an_absent_key_is_a_silent_noop() async throws {
        // given: a key nothing has ever been saved under.
        let store = MemoryDocStore()

        // when
        try await store.appendChange(docKey: "never-saved", change: StoredChange(clientSeq: 1, bytes: Data("c1".utf8)))

        // then: still nothing stored -- an append against a key with no base snapshot must
        // not fabricate one out of a single change.
        let loaded = try await store.load(docKey: "never-saved")
        XCTAssertNil(loaded)
    }

    func test_savemeta_on_an_absent_key_is_a_silent_noop() async throws {
        let store = MemoryDocStore()

        try await store.saveMeta(docKey: "never-saved", bytes: Data("header".utf8))

        let loaded = try await store.load(docKey: "never-saved")
        XCTAssertNil(loaded)
    }

    // MARK: load

    func test_load_of_an_absent_key_returns_nil() async throws {
        let store = MemoryDocStore()

        let loaded = try await store.load(docKey: "never-saved")

        XCTAssertNil(loaded)
    }
}
