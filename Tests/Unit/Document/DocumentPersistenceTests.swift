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

/// Ports the `Document` half of yorkie-js-sdk#1338 "Add offline local persistence": the
/// `toBytes()`/`fromBytes()`/`restoreFromBytes()` envelope round trip, `getEpoch()`/
/// `getDocID()`, `getPendingChangeStructs()`, and `resetForReanchor()`.
final class DocumentPersistenceTests: XCTestCase {
    private let actor = "000000000000000000000001"

    // MARK: Round trip

    @MainActor
    func test_round_trip_preserves_content_presence_checkpoint_epoch_docid_and_pending_changes() throws {
        let doc = Document(key: "persist-roundtrip")
        doc.setActor(self.actor)

        try doc.update { root, presence in
            root.title = "hello"
            root.nested = ["count": Int64(1), "list": [Int64(1), Int64(2), Int64(3)]]
            presence.set(["cursor": 7])
        }
        try doc.update { root, _ in
            root.title = "hello world"
        }

        doc.setDocID("server-doc-id-123")

        // Simulate a prior sync that advanced the checkpoint/epoch but did not acknowledge
        // any local changes yet (clientSeq 0), so both pending changes survive.
        let ackPack = ChangePack(key: doc.getKey(),
                                 checkpoint: Checkpoint(serverSeq: 5, clientSeq: 0),
                                 isRemoved: false,
                                 changes: [],
                                 versionVector: nil,
                                 epoch: 42)
        try doc.applyChangePack(ackPack)

        XCTAssertEqual(doc.getPendingChangeStructs().count, 2, "both local changes should still be pending before the round trip")

        let bytes = try doc.toBytes()
        let restored = try Document.fromBytes(key: doc.getKey(), bytes: bytes)

        XCTAssertEqual(restored.toSortedJSON(), doc.toSortedJSON())
        XCTAssertEqual(restored.checkpoint, doc.checkpoint)
        XCTAssertEqual(restored.getEpoch(), doc.getEpoch())
        XCTAssertEqual(restored.getDocID(), doc.getDocID())
        XCTAssertEqual(restored.getPendingChangeStructs().count, doc.getPendingChangeStructs().count)
        XCTAssertEqual(
            String(describing: restored.getPresenceForTest(self.actor)),
            String(describing: doc.getPresenceForTest(self.actor))
        )
    }

    @MainActor
    func test_restorefrombytes_rehydrates_the_receiver_in_place() throws {
        let doc = Document(key: "persist-restore-in-place")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "original"
        }
        doc.setDocID("doc-id-a")
        let bytes = try doc.toBytes()

        let live = Document(key: "persist-restore-in-place")
        live.setActor(self.actor)
        try live.update { root, _ in
            root.value = "will be overwritten"
        }

        try live.restoreFromBytes(bytes)

        XCTAssertEqual(live.toSortedJSON(), doc.toSortedJSON())
        XCTAssertEqual(live.getDocID(), "doc-id-a")
        XCTAssertEqual(live.getPendingChangeStructs().count, 1)
    }

    @MainActor
    func test_restorefrombytes_throws_on_actor_mismatch() throws {
        let doc = Document(key: "persist-actor-guard")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "hello"
        }
        let bytes = try doc.toBytes()

        let other = Document(key: "persist-actor-guard")
        other.setActor("000000000000000000000002")

        XCTAssertThrowsError(try other.restoreFromBytes(bytes)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    // MARK: Empty document

    @MainActor
    func test_round_trip_of_an_empty_document() throws {
        let doc = Document(key: "persist-empty")

        let bytes = try doc.toBytes()
        let restored = try Document.fromBytes(key: doc.getKey(), bytes: bytes)

        XCTAssertEqual(restored.toSortedJSON(), doc.toSortedJSON())
        XCTAssertEqual(restored.checkpoint, doc.checkpoint)
        XCTAssertEqual(restored.getEpoch(), 0)
        XCTAssertEqual(restored.getDocID(), "")
        XCTAssertEqual(restored.getPendingChangeStructs().count, 0)
    }

    // MARK: No pending changes

    @MainActor
    func test_round_trip_with_no_pending_changes() throws {
        let doc = Document(key: "persist-fully-acked")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "synced"
        }

        // Ack every local change: clientSeq matches the last local change's clientSeq.
        let ackPack = ChangePack(key: doc.getKey(),
                                 checkpoint: Checkpoint(serverSeq: 1, clientSeq: 1),
                                 isRemoved: false,
                                 changes: [],
                                 versionVector: nil,
                                 epoch: 1)
        try doc.applyChangePack(ackPack)
        XCTAssertEqual(doc.getPendingChangeStructs().count, 0)

        let bytes = try doc.toBytes()
        let restored = try Document.fromBytes(key: doc.getKey(), bytes: bytes)

        XCTAssertEqual(restored.toSortedJSON(), doc.toSortedJSON())
        XCTAssertEqual(restored.getPendingChangeStructs().count, 0)
        XCTAssertEqual(restored.getEpoch(), 1)
    }

    // MARK: resetForReanchor

    @MainActor
    func test_resetforreanchor_drops_all_state_back_to_initial() throws {
        let doc = Document(key: "persist-reanchor")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "stale"
        }
        doc.setDocID("stale-doc-id")

        let ackPack = ChangePack(key: doc.getKey(),
                                 checkpoint: Checkpoint(serverSeq: 9, clientSeq: 0),
                                 isRemoved: false,
                                 changes: [],
                                 versionVector: nil,
                                 epoch: 7)
        try doc.applyChangePack(ackPack)
        XCTAssertEqual(doc.getEpoch(), 7)
        XCTAssertEqual(doc.getPendingChangeStructs().count, 1)

        doc.resetForReanchor()

        XCTAssertEqual(doc.toSortedJSON(), "{}")
        XCTAssertEqual(doc.getEpoch(), 0)
        XCTAssertEqual(doc.getDocID(), "")
        XCTAssertEqual(doc.getPendingChangeStructs().count, 0)
        XCTAssertEqual(doc.checkpoint, .initial)
    }

    // MARK: Malformed input

    @MainActor
    func test_frombytes_throws_on_a_truncated_length_prefix() {
        // Fewer than 4 bytes: not even one full length prefix.
        let malformed = Data([0x01, 0x02, 0x03])

        XCTAssertThrowsError(try Document.fromBytes(key: "malformed", bytes: malformed)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_frombytes_throws_when_a_length_prefix_exceeds_the_remaining_bytes() {
        // A length prefix (little-endian UInt32.max) claiming far more bytes than follow it.
        let malformed = Data([0xFF, 0xFF, 0xFF, 0xFF])

        XCTAssertThrowsError(try Document.fromBytes(key: "malformed", bytes: malformed)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_frombytes_throws_when_the_envelope_has_the_wrong_blob_count() throws {
        let doc = Document(key: "persist-wrong-blob-count")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "hello"
        }
        let bytes = try doc.toBytes()

        // Drop the trailing bytes so `unpackBlobs` only recovers a subset of the six blobs
        // `fromBytes` requires.
        let truncatedEnvelope = bytes.prefix(bytes.count / 2)

        XCTAssertThrowsError(try Document.fromBytes(key: "persist-wrong-blob-count", bytes: Data(truncatedEnvelope))) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_frombytes_throws_on_empty_bytes_rather_than_crashing() {
        XCTAssertThrowsError(try Document.fromBytes(key: "malformed", bytes: Data())) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }
}
