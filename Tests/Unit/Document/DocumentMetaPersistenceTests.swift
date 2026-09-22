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

/// Covers ``Document/metaToBytes()`` / ``Document/restoreMetaFromBytes(_:)`` -- the header
/// half of offline persistence (`Client.saveMetaToStore`/`Client.replayAppendedLog`) -- plus
/// ``Document/applyRestoredMeta(checkpoint:changeID:epoch:docID:)``'s drop filter, which is
/// beyond what yorkie-js-sdk's `document.ts` does: upstream filters only the *appended log*
/// against the acked watermark and leaves the snapshot's own pending queue alone, while this
/// SDK applies the same rule to both (see the comment on `applyRestoredMeta` for why).
final class DocumentMetaPersistenceTests: XCTestCase {
    private let actor = "000000000000000000000001"

    // MARK: applyRestoredMeta's drop filter

    @MainActor
    func test_applyrestoredmeta_drops_a_pending_change_the_checkpoint_already_covers() throws {
        // given: two pending changes, clientSeq 1 and 2.
        let doc = Document(key: "meta-drop-covered")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.a = "1"
        }
        try doc.update { root, _ in
            root.b = "2"
        }
        XCTAssertEqual(doc.getPendingChangeStructs().count, 2)

        // when: a header whose checkpoint acks clientSeq 1 is applied -- a sync recorded the
        // header without rewriting the snapshot, so the snapshot's own queue still carries a
        // change the sync went on to acknowledge.
        doc.applyRestoredMeta(checkpoint: Checkpoint(serverSeq: 5, clientSeq: 1), changeID: nil, epoch: nil, docID: nil)

        // then: the acked change is gone, and the one above the checkpoint survives -- both
        // matter, since a filter that drops everything or nothing would pass either half of
        // this alone.
        let pending = doc.getPendingChangeStructs()
        XCTAssertEqual(pending.count, 1, "the change the checkpoint already covers must be dropped")
        XCTAssertEqual(pending[0].id.getClientSeq(), 2, "a change above the checkpoint must survive")
    }

    @MainActor
    func test_applyrestoredmeta_with_a_zero_checkpoint_keeps_every_pending_change() throws {
        // The boundary case of the drop filter: an unacknowledged checkpoint (clientSeq 0)
        // must not be mistaken for "everything is acked", or a document that has never
        // synced would lose its entire offline queue the first time a header is applied.
        let doc = Document(key: "meta-drop-none-acked")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.a = "1"
        }
        try doc.update { root, _ in
            root.b = "2"
        }

        doc.applyRestoredMeta(checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0), changeID: nil, epoch: nil, docID: nil)

        XCTAssertEqual(doc.getPendingChangeStructs().count, 2)
    }

    // MARK: metaToBytes / restoreMetaFromBytes round trip

    @MainActor
    func test_meta_round_trip_preserves_checkpoint_changeid_epoch_and_docid() throws {
        let doc = Document(key: "meta-roundtrip")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "hello"
        }
        doc.setDocID("server-doc-id")
        let ackPack = ChangePack(key: doc.getKey(),
                                 checkpoint: Checkpoint(serverSeq: 4, clientSeq: 1),
                                 isRemoved: false,
                                 changes: [],
                                 versionVector: nil,
                                 epoch: 12)
        try doc.applyChangePack(ackPack)

        let metaBytes = try doc.metaToBytes()

        let restoring = Document(key: "meta-roundtrip")
        restoring.setActor(self.actor)
        try restoring.restoreMetaFromBytes(metaBytes)

        XCTAssertEqual(restoring.checkpoint, doc.checkpoint)
        XCTAssertEqual(restoring.changeID.getClientSeq(), doc.changeID.getClientSeq())
        XCTAssertEqual(restoring.changeID.getActorID(), doc.changeID.getActorID())
        XCTAssertEqual(restoring.getEpoch(), doc.getEpoch())
        XCTAssertEqual(restoring.getDocID(), doc.getDocID())
    }

    @MainActor
    func test_restoremetafrombytes_decodes_a_header_with_only_the_first_two_blobs() throws {
        // Trailing blobs (epoch, docID) are deliberately optional, the same back-compat rule
        // `toBytes()`'s envelope follows, so a header written before those fields existed must
        // still decode rather than being treated as corrupt.
        let doc = Document(key: "meta-legacy-two-blobs")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "hello"
        }
        doc.setDocID("server-doc-id")
        let ackPack = ChangePack(key: doc.getKey(),
                                 checkpoint: Checkpoint(serverSeq: 4, clientSeq: 1),
                                 isRemoved: false,
                                 changes: [],
                                 versionVector: nil,
                                 epoch: 12)
        try doc.applyChangePack(ackPack)

        let fullMeta = try doc.metaToBytes()
        let blobs = Self.unpackMetaBlobs(fullMeta)
        XCTAssertEqual(blobs.count, 4, "metaToBytes() should still write all four blobs")

        let legacyMeta = Self.packMetaBlobs(Array(blobs.prefix(2)))

        let restoring = Document(key: "meta-legacy-two-blobs")
        restoring.setActor(self.actor)
        try restoring.restoreMetaFromBytes(legacyMeta)

        XCTAssertEqual(restoring.checkpoint, doc.checkpoint)
        XCTAssertEqual(restoring.changeID.getClientSeq(), doc.changeID.getClientSeq())
        XCTAssertEqual(restoring.getEpoch(), 0, "the epoch blob is absent, so it must default rather than throw")
        XCTAssertEqual(restoring.getDocID(), "", "the docID blob is absent, so it must default rather than throw")
    }

    @MainActor
    func test_restoremetafrombytes_throws_invalidargument_on_a_truncated_header() throws {
        let doc = Document(key: "meta-corrupt")
        doc.setActor(self.actor)

        // Fewer than 4 bytes: not even one full length prefix -- the same malformed input
        // `restoreFromBytes` is pinned against, but on the header decoder instead, so a
        // corrupt header throws rather than trapping on the length-prefixed framing.
        let corrupt = Data([0x01, 0x02, 0x03])

        XCTAssertThrowsError(try doc.restoreMetaFromBytes(corrupt)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_restoremetafrombytes_throws_invalidargument_on_too_few_blobs() throws {
        let doc = Document(key: "meta-too-few-blobs")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.value = "hello"
        }
        let metaBytes = try doc.metaToBytes()

        let blobs = Self.unpackMetaBlobs(metaBytes)
        let tooFewMeta = Self.packMetaBlobs(Array(blobs.prefix(1)))

        XCTAssertThrowsError(try doc.restoreMetaFromBytes(tooFewMeta)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError, got \(error)")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
    }

    /// Splits a `metaToBytes()` header back into its ordered blobs: each blob is prefixed
    /// with its length as a 4-byte little-endian `UInt32`, the same framing `packBlobs` uses
    /// in `Document+Persistence.swift`. Reimplemented here rather than reached via
    /// `@testable`, because `packBlobs`/`unpackBlobs` are `private` to that file, not merely
    /// `internal`.
    private static func unpackMetaBlobs(_ bytes: Data) -> [Data] {
        let bytes = [UInt8](bytes)
        var blobs = [Data]()
        var offset = 0
        while offset < bytes.count {
            let length = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            offset += 4
            blobs.append(Data(bytes[offset ..< (offset + Int(length))]))
            offset += Int(length)
        }
        return blobs
    }

    private static func packMetaBlobs(_ blobs: [Data]) -> Data {
        var out = Data()
        for blob in blobs {
            let length = UInt32(blob.count)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8((length >> 16) & 0xFF))
            out.append(UInt8((length >> 24) & 0xFF))
            out.append(blob)
        }
        return out
    }
}
