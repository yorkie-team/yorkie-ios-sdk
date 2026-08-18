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

import SwiftProtobuf
import XCTest
@testable import Yorkie

/// Ports: `packages/sdk/test/unit/api/restore_converter_test.ts` from
/// yorkie-js-sdk v0.7.13 (yorkie-js-sdk#1293 "Identity-preserving restore for
/// Text undo/redo"), covering the new proto fields `Operation.Edit.restore_spans
/// = 8`, `restore_mode = 9`, `retombstone_spans = 10` and the `RestoreSpan`
/// message / `RestoreMode` enum.
final class RestoreSpanConverterTests: XCTestCase {
    private let seed = TimeTicket(lamport: 1, delimiter: 0, actorID: ActorIDs.initial)
    private let executedAt = TimeTicket(lamport: 4, delimiter: 0, actorID: ActorIDs.initial)
    private lazy var pos = RGATreeSplitPos(RGATreeSplitNodeID(self.seed, 0), 0)

    private func span(_ start: Int32, _ end: Int32, _ content: String) -> RestoreSpan<CRDTTextValue> {
        RestoreSpan(createdAt: self.seed, start: start, end: end, value: CRDTTextValue(content))
    }

    /// `RestoreMode` has no `Equatable` conformance in production code, so
    /// compare by switching rather than adding a conformance from the test
    /// module.
    private func assertMode(_ actual: RestoreMode?, _ expected: RestoreMode, file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (.restore, .restore), (.retombstone, .retombstone):
            return
        default:
            XCTFail("expected \(expected), got \(String(describing: actual))", file: file, line: line)
        }
    }

    /// Serializes the given operation to bytes and decodes it back, mirroring
    /// `converter.operationToBinary` / `converter.bytesToOperation` in JS.
    private func roundTrip(_ operation: Yorkie.Operation) throws -> EditOperation {
        let pbOperation = try Converter.toOperation(operation)
        let bytes = try pbOperation.serializedData()
        let restoredPb = try PbOperation(serializedBytes: bytes)
        let restoredOps = try Converter.fromOperations([restoredPb])
        guard let editOp = restoredOps.first as? EditOperation else {
            throw YorkieError(code: .errUnexpected, message: "expected an EditOperation after round-trip")
        }
        return editOp
    }

    func test_round_trips_a_restore_operation_over_the_wire() throws {
        // given
        let spans = [self.span(4, 6, "45"), self.span(2, 8, "234567")]
        let op = EditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            content: "",
            attributes: [:],
            executedAt: self.executedAt,
            isUndoOp: true,
            restoreSpans: spans,
            restoreMode: .restore
        )

        // when
        let restored = try self.roundTrip(op)

        // then
        self.assertMode(restored.restoreMode, .restore)
        let got = try XCTUnwrap(restored.restoreSpans)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].start, 4)
        XCTAssertEqual(got[0].end, 6)
        XCTAssertEqual(got[0].value.toString, "45")
        XCTAssertEqual(got[1].value.toString, "234567")
        XCTAssertEqual(got[0].createdAt, self.seed)
    }

    func test_round_trips_a_retombstone_operation() throws {
        // given
        let op = EditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            content: "",
            attributes: [:],
            executedAt: self.executedAt,
            isUndoOp: true,
            restoreSpans: [self.span(4, 6, "45")],
            restoreMode: .retombstone
        )

        // when
        let restored = try self.roundTrip(op)

        // then
        self.assertMode(restored.restoreMode, .retombstone)
        XCTAssertEqual(restored.restoreSpans?.count, 1)
    }

    func test_round_trips_the_companion_retombstone_spans_of_a_replace_reverse() throws {
        // given — the reverse of a replace revives the removed content
        // (restoreSpans) and re-removes the inserted content (retombstoneSpans),
        // both by identity. Both span sets must survive the wire or a
        // peer/server diverges.
        let op = EditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            content: "",
            attributes: [:],
            executedAt: self.executedAt,
            isUndoOp: true,
            restoreSpans: [self.span(2, 4, "CD")], // restore (revive the removed "CD")
            restoreMode: .restore,
            retombstoneSpans: [self.span(0, 2, "12")] // retombstone (re-remove the inserted "12")
        )

        // when
        let restored = try self.roundTrip(op)

        // then
        self.assertMode(restored.restoreMode, .restore)
        XCTAssertEqual(restored.restoreSpans?.count, 1)
        XCTAssertEqual(restored.restoreSpans?.first?.value.toString, "CD")
        XCTAssertEqual(restored.retombstoneSpans?.count, 1)
        XCTAssertEqual(restored.retombstoneSpans?.first?.value.toString, "12")
        XCTAssertEqual(restored.retombstoneSpans?.first?.createdAt, self.seed)
    }

    func test_leaves_ordinary_edits_without_a_restore_payload() throws {
        // given — a plain edit, no restore/retombstone spans at all.
        let op = EditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            content: "hi",
            attributes: [:],
            executedAt: self.executedAt
        )

        // when
        let restored = try self.roundTrip(op)

        // then
        XCTAssertNil(restored.restoreSpans)
        XCTAssertEqual(restored.content, "hi")
    }

    /// Mixed-version interop contract: a restore/undo op carries its content
    /// only in restoreSpans; its base Edit fields are a zero-width,
    /// empty-content edit (from === to, content === ""). A peer or server
    /// without restore support drops the unknown restore fields and applies
    /// just the base edit — which inserts nothing and deletes nothing. So a
    /// restore op reaching an old node CANNOT duplicate or corrupt content
    /// (there is no inline content to re-insert); at worst the old node does
    /// not perform the restore and stays diverged until upgraded. This pins
    /// that wire contract so a future change can't quietly start emitting
    /// inline content on the restore path.
    func test_decodes_to_a_harmless_no_op_for_peers_that_ignore_restore_fields() throws {
        // given
        let op = EditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            content: "",
            attributes: [:],
            executedAt: self.executedAt,
            isUndoOp: true,
            restoreSpans: [self.span(4, 6, "45")],
            restoreMode: .restore
        )

        // when
        let pbOp = try Converter.toOperation(op)

        // then — base Edit fields carry no inline content for an old peer to
        // re-insert.
        guard case .edit(let pbEdit) = pbOp.body else {
            return XCTFail("expected an edit operation body")
        }
        XCTAssertEqual(pbEdit.content, "", "restore ops carry no inline content for an old peer to re-insert")

        let restored = try self.roundTrip(op)
        XCTAssertEqual(restored.fromPos, restored.toPos, "restore ops are zero-width, so an old peer deletes nothing either")
        XCTAssertEqual(restored.content, "")

        // A new peer still receives the full identity payload.
        self.assertMode(restored.restoreMode, .restore)
        XCTAssertEqual(restored.restoreSpans?.count, 1)
    }

    /// A server or peer older than v0.7.13 does not know fields 8-10 and drops
    /// them, so the op arrives as a bare zero-width edit whose range is the
    /// head-anchored position `normalizePos` produced. Executing that must not
    /// throw: the error would escape the sync loop, and the change would be
    /// re-pulled and re-fail indefinitely.
    func test_executes_without_throwing_when_an_old_peer_strips_the_restore_fields() throws {
        // given — a text holding "0123456789" with "45" deleted, i.e. the state
        // in which an identity-preserving undo would arrive.
        let actorID = ActorIDs.initial
        let rootObject = CRDTObject(createdAt: TimeTicket.initial)
        let root = CRDTRoot(rootObject: rootObject)

        let textCreatedAt = TimeTicket(lamport: 2, delimiter: 0, actorID: actorID)
        let text = CRDTText(rgaTreeSplit: RGATreeSplit<CRDTTextValue>(), createdAt: textCreatedAt)
        rootObject.set(key: "text", value: text)
        root.registerElement(text, parent: rootObject)

        let head = RGATreeSplitPos(RGATreeSplitNodeID.initial, 0)
        try text.edit((head, head), "0123456789", TimeTicket(lamport: 3, delimiter: 0, actorID: actorID))
        let seedID = RGATreeSplitNodeID(TimeTicket(lamport: 3, delimiter: 0, actorID: actorID), 0)
        try text.edit(
            (RGATreeSplitPos(seedID, 4), RGATreeSplitPos(seedID, 6)),
            "",
            TimeTicket(lamport: 4, delimiter: 0, actorID: actorID)
        )
        XCTAssertEqual(text.toString, "01236789", "sanity: \"45\" is deleted, leaving a tombstone to revive")

        // A reverse op shaped exactly as `toReverseOperation` emits one: the
        // range is head-anchored (only `normalizePos` yields offset > 0 on the
        // head sentinel) and the payload lives entirely in the restore fields.
        let headAnchored = RGATreeSplitPos(RGATreeSplitNodeID.initial, 4)
        let undoOp = EditOperation(
            parentCreatedAt: textCreatedAt,
            fromPos: headAnchored,
            toPos: headAnchored,
            content: "",
            attributes: [:],
            executedAt: self.executedAt,
            isUndoOp: true,
            restoreSpans: [self.span(4, 6, "45")],
            restoreMode: .restore
        )

        // when — serialize, then strip fields 8-10 the way an old peer would.
        var pbOp = try Converter.toOperation(undoOp)
        guard case .edit(var pbEdit) = pbOp.body else {
            return XCTFail("expected an edit operation body")
        }
        pbEdit.restoreSpans = []
        pbEdit.retombstoneSpans = []
        pbEdit.restoreMode = Yorkie_V1_RestoreMode.unspecified
        pbOp.body = Yorkie_V1_Operation.OneOf_Body.edit(pbEdit)

        let bytes = try pbOp.serializedData()
        let decoded = try Converter.fromOperations([PbOperation(serializedBytes: bytes)])
        let stripped = try XCTUnwrap(decoded.first as? EditOperation)
        XCTAssertNil(stripped.restoreSpans, "the old peer must see no identity payload")
        XCTAssertNil(stripped.restoreMode, "no restoreMode means the op is not recognised as an undo")

        // then — executing the stripped op must not throw.
        XCTAssertNoThrow(try stripped.execute(root: root), "a stripped restore op must not wedge the sync loop")
    }

    /// A nonconforming peer may send a span whose `[start, end)` disagrees with
    /// `content`. yorkie-js-sdk never rejects one, so neither may this SDK:
    /// throwing here escapes `applyChangePack` and the change pack re-pulls and
    /// re-fails forever. The bounds are clamped to match `content` instead, which
    /// also keeps the NSString slicing in `restore` inside the string.
    func test_clamps_a_restore_span_whose_bounds_disagree_with_its_content() throws {
        // given — end overshoots the content by 40 characters, and start is negative.
        var pbSpan = Yorkie_V1_RestoreSpan()
        pbSpan.createdAt = Converter.toTimeTicket(self.seed)
        pbSpan.start = -3
        pbSpan.end = 42
        pbSpan.content = "45"

        // when
        let span = Converter.fromRestoreSpan(pbSpan, self.executedAt)

        // then — the span is self-consistent, so slicing cannot overrun.
        XCTAssertEqual(span.start, 0, "a negative start is clamped to zero")
        XCTAssertEqual(span.end, 2, "end is derived from the content length")
        XCTAssertEqual(span.value.toString, "45", "content itself is preserved verbatim")
    }
}
