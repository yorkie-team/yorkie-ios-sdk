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

/// Covers `Client.replayAppendedLog` (private) -- the js#1355 fix landed in ae8894010412 --
/// through `Client.prepareOfflineResume(for:)`, which is `internal` rather than `private`
/// specifically so tests can drive it (see `ClientPersistenceTests`'s class doc). Unlike
/// `attach()`, `prepareOfflineResume` makes no RPC of its own -- it only acquires the session
/// lease and reads/restores the configured store -- so it is reachable here without a live
/// server. A `StoredDoc` is assembled by hand for each case and driven straight through
/// `store.saveSnapshot`/`appendChange`/`saveMeta`, keyed by `client.storeKey(_:)` exactly as
/// `prepareOfflineResume` itself keys its lookup, mirroring exactly how a prior session would
/// have left the store.
///
/// The four rejection/acceptance cases each isolate one clause of `replayAppendedLog`'s final
/// guard (`backsTheHeader`, `contiguous`, `startsAtWatermark`) by construction, so a
/// regression in any single clause fails exactly one test rather than all of them.
final class RestoreLogValidationTests: XCTestCase {
    private let actor = "000000000000000000000001"
    private let fillerActor = "000000000000000000000009"

    // MARK: Fixtures

    /// A snapshot with a single pending change (clientSeq 1) and an un-synced checkpoint, so
    /// every scenario below shares the same `snapshotWatermark` of 1 -- a fresh log must
    /// start at clientSeq 2 to be replayable.
    @MainActor
    private func makeBaseSnapshot(docKey: String) throws -> (bytes: Data, doc: Document) {
        let doc = Document(key: docKey)
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.a = "1"
        }
        return try (doc.toBytes(), doc)
    }

    /// `count` distinct, individually-decodable serialized changes from an unrelated
    /// document, for tagging onto `StoredChange` values with whatever `clientSeq` a scenario
    /// needs. This decouples "the log's clientSeq bookkeeping is corrupt" (what these tests
    /// pin) from "the payload itself fails to decode" (a different failure mode, covered by
    /// `restoreAppendedChanges`'s own ascending-order guard).
    @MainActor
    private func fillerChangeBytes(_ count: Int) throws -> [Data] {
        let filler = Document(key: "filler")
        filler.setActor(self.fillerActor)
        for index in 0 ..< count {
            try filler.update { root, _ in
                root.value = Int64(index)
            }
        }
        return try filler.getPendingChangeStructs().map { try Converter.toChange($0).serializedData() }
    }

    /// Builds a header carrying an arbitrary checkpoint/changeID pair, via a throwaway
    /// document rather than hand-encoding the blob framing -- so the fixture stays valid even
    /// if the header's byte layout changes.
    @MainActor
    private func makeMetaBytes(docKey: String, ackedClientSeq: UInt32, headerClientSeq: UInt32) throws -> Data {
        let metaDoc = Document(key: docKey)
        metaDoc.setActor(self.actor)
        let changeID = ChangeID(clientSeq: headerClientSeq, lamport: Int64(headerClientSeq), actor: self.actor, versionVector: .initial)
        metaDoc.applyRestoredMeta(
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: ackedClientSeq),
            changeID: changeID,
            epoch: nil,
            docID: nil
        )
        return try metaDoc.metaToBytes()
    }

    @MainActor
    private func makeClient(store: DocStore, clientKey: String) -> Client {
        Client("http://localhost:8080", ClientOptions(key: clientKey, store: store))
    }

    // MARK: One short of the header's changeID.clientSeq (ae8894010412d1656021bbb9320a69e390daf2b8)

    @MainActor
    func test_a_log_reaching_the_checkpoint_but_one_short_of_the_headers_changeid_is_rejected() async throws {
        // given: the exact bug js#1355 fixed -- an edit minted while a sync was in flight, so
        // the response acks clientSeq 2 while the header's own counter is already 3. The log
        // has the acked entry but not the trailing one, satisfying the checkpoint alone.
        let store = MemoryDocStore()
        let docKey = "restore-one-short"
        let client = self.makeClient(store: store, clientKey: "one-short-client")
        let storeKey = client.storeKey(docKey)

        let (snapshot, snapshotDoc) = try self.makeBaseSnapshot(docKey: docKey)
        let filler = try self.fillerChangeBytes(1)
        let meta = try self.makeMetaBytes(docKey: docKey, ackedClientSeq: 2, headerClientSeq: 3)

        try await store.saveSnapshot(docKey: storeKey, bytes: snapshot)
        try await store.appendChange(docKey: storeKey, change: StoredChange(clientSeq: 2, bytes: filler[0]))
        try await store.saveMeta(docKey: storeKey, bytes: meta)

        let resuming = Document(key: docKey)
        resuming.setActor(self.actor)
        var dropped: LocalChangesDroppedEvent?
        resuming.subscribe { event, _ in
            if let event = event as? LocalChangesDroppedEvent {
                dropped = event
            }
        }

        // when
        _ = try await client.prepareOfflineResume(for: resuming)

        // then: rejected -- validating against the checkpoint alone (the pre-#1355 bug) would
        // have accepted this log, since it does reach clientSeq 2.
        let event = try XCTUnwrap(dropped, "a log that cannot back the header must publish logDiscontinuity")
        XCTAssertEqual(event.value.reason, .logDiscontinuity)

        // and: the document is back to exactly what the snapshot alone carries.
        XCTAssertEqual(resuming.toSortedJSON(), snapshotDoc.toSortedJSON())
        XCTAssertEqual(resuming.checkpoint, snapshotDoc.checkpoint)
        XCTAssertEqual(resuming.getPendingChangeStructs().map { $0.id.getClientSeq() }, [1])

        // and: the store has been re-based to the snapshot -- log and header both cleared.
        let restoredEntry = try await store.load(docKey: storeKey)
        XCTAssertEqual(restoredEntry?.snapshot, snapshot)
        XCTAssertEqual(restoredEntry?.changes, [])
        XCTAssertNil(restoredEntry?.meta)
    }

    // MARK: A hole in the log

    @MainActor
    func test_a_log_with_a_hole_is_rejected() async throws {
        // given: clientSeq 2 and 4 appended, clientSeq 3 missing -- a failed append leaving a
        // gap the server would reject on every push from then on.
        let store = MemoryDocStore()
        let docKey = "restore-hole"
        let client = self.makeClient(store: store, clientKey: "hole-client")
        let storeKey = client.storeKey(docKey)

        let (snapshot, snapshotDoc) = try self.makeBaseSnapshot(docKey: docKey)
        let filler = try self.fillerChangeBytes(2)
        let meta = try self.makeMetaBytes(docKey: docKey, ackedClientSeq: 2, headerClientSeq: 4)

        try await store.saveSnapshot(docKey: storeKey, bytes: snapshot)
        try await store.appendChange(docKey: storeKey, change: StoredChange(clientSeq: 2, bytes: filler[0]))
        try await store.appendChange(docKey: storeKey, change: StoredChange(clientSeq: 4, bytes: filler[1]))
        try await store.saveMeta(docKey: storeKey, bytes: meta)

        let resuming = Document(key: docKey)
        resuming.setActor(self.actor)
        var dropped: LocalChangesDroppedEvent?
        resuming.subscribe { event, _ in
            if let event = event as? LocalChangesDroppedEvent {
                dropped = event
            }
        }

        // when
        _ = try await client.prepareOfflineResume(for: resuming)

        // then
        let event = try XCTUnwrap(dropped)
        XCTAssertEqual(event.value.reason, .logDiscontinuity)
        XCTAssertEqual(resuming.toSortedJSON(), snapshotDoc.toSortedJSON())
        XCTAssertEqual(resuming.getPendingChangeStructs().map { $0.id.getClientSeq() }, [1])

        let restoredEntry = try await store.load(docKey: storeKey)
        XCTAssertEqual(restoredEntry?.snapshot, snapshot)
        XCTAssertEqual(restoredEntry?.changes, [])
        XCTAssertNil(restoredEntry?.meta)
    }

    // MARK: The log does not start at snapshotWatermark + 1

    @MainActor
    func test_a_log_that_skips_the_entry_right_after_the_snapshot_is_rejected() async throws {
        // given: the snapshot's watermark is clientSeq 1 (its one embedded pending change), so
        // a replayable log has to start at clientSeq 2. This one starts at 3 instead --
        // clientSeq 2 is missing entirely, not merely out of order.
        let store = MemoryDocStore()
        let docKey = "restore-skips-watermark"
        let client = self.makeClient(store: store, clientKey: "skips-watermark-client")
        let storeKey = client.storeKey(docKey)

        let (snapshot, snapshotDoc) = try self.makeBaseSnapshot(docKey: docKey)
        let filler = try self.fillerChangeBytes(1)
        let meta = try self.makeMetaBytes(docKey: docKey, ackedClientSeq: 3, headerClientSeq: 3)

        try await store.saveSnapshot(docKey: storeKey, bytes: snapshot)
        try await store.appendChange(docKey: storeKey, change: StoredChange(clientSeq: 3, bytes: filler[0]))
        try await store.saveMeta(docKey: storeKey, bytes: meta)

        let resuming = Document(key: docKey)
        resuming.setActor(self.actor)
        var dropped: LocalChangesDroppedEvent?
        resuming.subscribe { event, _ in
            if let event = event as? LocalChangesDroppedEvent {
                dropped = event
            }
        }

        // when
        _ = try await client.prepareOfflineResume(for: resuming)

        // then
        let event = try XCTUnwrap(dropped)
        XCTAssertEqual(event.value.reason, .logDiscontinuity)
        XCTAssertEqual(resuming.toSortedJSON(), snapshotDoc.toSortedJSON())
        XCTAssertEqual(resuming.getPendingChangeStructs().map { $0.id.getClientSeq() }, [1])

        let restoredEntry = try await store.load(docKey: storeKey)
        XCTAssertEqual(restoredEntry?.snapshot, snapshot)
        XCTAssertEqual(restoredEntry?.changes, [])
        XCTAssertNil(restoredEntry?.meta)
    }

    // MARK: A clean log

    @MainActor
    func test_a_clean_log_is_replayed_and_only_entries_above_the_ack_watermark_stay_pending() async throws {
        // given: a real edit history rather than filler bytes, since this path actually
        // replays the log onto the restored root and the result has to be checked.
        //   clientSeq 1 -- embedded in the snapshot.
        //   clientSeq 2 -- appended, and acknowledged by the header below.
        //   clientSeq 3 -- appended, minted while that ack's sync was in flight, so it is
        //                  above the checkpoint and must come back pending.
        let docKey = "restore-clean-log"
        let store = MemoryDocStore()
        let client = self.makeClient(store: store, clientKey: "clean-log-client")
        let storeKey = client.storeKey(docKey)

        let history = Document(key: docKey)
        history.setActor(self.actor)
        try history.update { root, _ in
            root.a = "1"
        }
        let snapshot = try history.toBytes()
        try history.update { root, _ in
            root.b = "2"
        }
        try history.update { root, _ in
            root.c = "3"
        }
        let log = try history.getPendingChangesAfter(1)
        XCTAssertEqual(log.map(\.clientSeq), [2, 3])

        let metaDoc = Document(key: docKey)
        metaDoc.setActor(self.actor)
        metaDoc.applyRestoredMeta(
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: 2),
            changeID: history.changeID,
            epoch: nil,
            docID: nil
        )
        let meta = try metaDoc.metaToBytes()

        try await store.saveSnapshot(docKey: storeKey, bytes: snapshot)
        for change in log {
            try await store.appendChange(docKey: storeKey, change: change)
        }
        try await store.saveMeta(docKey: storeKey, bytes: meta)

        let resuming = Document(key: docKey)
        resuming.setActor(self.actor)
        var dropped: LocalChangesDroppedEvent?
        resuming.subscribe { event, _ in
            if let event = event as? LocalChangesDroppedEvent {
                dropped = event
            }
        }

        // when
        let result = try await client.prepareOfflineResume(for: resuming)

        // then: the log actually replayed onto the restored root.
        XCTAssertTrue(result.didRestore)
        XCTAssertNil(dropped, "a clean, replayable log must not report a discontinuity")
        XCTAssertEqual(resuming.toSortedJSON(), history.toSortedJSON())
        XCTAssertEqual(resuming.checkpoint, Checkpoint(serverSeq: 0, clientSeq: 2))

        // and: clientSeq 2 was acknowledged by the header and must not come back pending;
        // clientSeq 3, minted after that ack, must.
        let pending = resuming.getPendingChangeStructs()
        XCTAssertEqual(pending.map { $0.id.getClientSeq() }, [3])
    }
}
