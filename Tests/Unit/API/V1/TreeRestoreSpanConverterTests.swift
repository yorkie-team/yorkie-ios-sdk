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

/// Ports `packages/sdk/test/unit/api/tree_restore_converter_test.ts` from
/// yorkie-js-sdk v0.7.14 (yorkie-js-sdk#1297 "Add identity-preserving restore
/// for Tree undo/redo"), covering the new `TreeRestoreSpan` message and the
/// `Operation.TreeEdit` fields `restore_spans = 8`, `restore_mode = 9` and
/// `retombstone_spans = 10`.
final class TreeRestoreSpanConverterTests: XCTestCase {
    private let seed = TimeTicket(lamport: 1, delimiter: 0, actorID: ActorIDs.initial)
    private let executedAt = TimeTicket(lamport: 4, delimiter: 0, actorID: ActorIDs.initial)

    private func textSpan() -> TreeRestoreSpan {
        TreeRestoreSpan(id: CRDTTreeNodeID(createdAt: self.seed, offset: 2),
                        nodeType: DefaultTreeNodeType.text.rawValue,
                        isText: true,
                        length: 3,
                        value: "bcd",
                        attrs: nil,
                        parentID: CRDTTreeNodeID(createdAt: self.seed, offset: 0),
                        leftSiblingID: CRDTTreeNodeID(createdAt: self.seed, offset: 1),
                        rightSiblingID: CRDTTreeNodeID(createdAt: self.seed, offset: 5))
    }

    func test_round_trips_a_text_span_over_the_wire() throws {
        // given / when
        let restored = try Converter.fromTreeRestoreSpan(Converter.toTreeRestoreSpan(self.textSpan()))

        // then
        XCTAssertEqual(restored.id, CRDTTreeNodeID(createdAt: self.seed, offset: 2))
        XCTAssertTrue(restored.isText)
        XCTAssertEqual(restored.length, 3)
        XCTAssertEqual(restored.value, "bcd")
        XCTAssertEqual(restored.parentID, CRDTTreeNodeID(createdAt: self.seed, offset: 0))
        XCTAssertEqual(restored.leftSiblingID, CRDTTreeNodeID(createdAt: self.seed, offset: 1))
        XCTAssertEqual(restored.rightSiblingID, CRDTTreeNodeID(createdAt: self.seed, offset: 5))
    }

    /// `RHT` iterates removed nodes too, so a tombstoned attribute must survive
    /// the wire with its `isRemoved` flag intact — otherwise a restored element
    /// resurrects an attribute the user had deleted.
    func test_round_trips_an_element_span_including_a_tombstoned_attribute() throws {
        // given
        let attrs = RHT()
        attrs.setInternal(key: "bold", value: "true", executedAt: self.seed, removed: false)
        attrs.setInternal(key: "italic", value: "true", executedAt: self.seed, removed: true)
        let span = TreeRestoreSpan(id: CRDTTreeNodeID(createdAt: self.seed, offset: 0),
                                   nodeType: "p",
                                   isText: false,
                                   length: 0,
                                   value: nil,
                                   attrs: attrs,
                                   parentID: CRDTTreeNodeID(createdAt: self.seed, offset: 0),
                                   leftSiblingID: nil,
                                   rightSiblingID: nil)

        // when
        let restored = try Converter.fromTreeRestoreSpan(Converter.toTreeRestoreSpan(span))

        // then
        XCTAssertFalse(restored.isText)
        XCTAssertEqual(restored.nodeType, "p")
        XCTAssertNil(restored.value, "an element span carries no text value")
        let got = try XCTUnwrap(restored.attrs)
        var seen = [String: Bool]()
        for node in got {
            seen[node.key] = node.isRemoved
        }
        XCTAssertEqual(seen["bold"], false)
        XCTAssertEqual(seen["italic"], true, "the attribute tombstone must survive the wire")
        XCTAssertNil(restored.leftSiblingID, "nil means the node was the first child")
        XCTAssertNil(restored.rightSiblingID, "nil means the node was the last child")
    }

    func test_round_trips_a_tree_edit_operation_carrying_both_span_sets() throws {
        // given
        let pos = CRDTTreePos(parentID: CRDTTreeNodeID(createdAt: self.seed, offset: 0),
                              leftSiblingID: CRDTTreeNodeID(createdAt: self.seed, offset: 0))
        let op = TreeEditOperation(parentCreatedAt: TimeTicket.initial,
                                   fromPos: pos,
                                   toPos: pos,
                                   contents: nil,
                                   splitLevel: 0,
                                   executedAt: self.executedAt,
                                   isUndoOp: true,
                                   fromIdx: 0,
                                   toIdx: 0,
                                   restoreSpans: [self.textSpan()],
                                   restoreMode: .retombstone,
                                   retombstoneSpans: [self.textSpan()])

        // when — serialize to bytes and back, mirroring a real change pack
        let bytes = try Converter.toOperation(op).serializedData()
        let decoded = try Converter.fromOperations([PbOperation(serializedBytes: bytes)])

        // then
        let restored = try XCTUnwrap(decoded.first as? TreeEditOperation)
        XCTAssertEqual(restored.restoreSpans?.count, 1)
        XCTAssertEqual(restored.retombstoneSpans?.count, 1)
        guard case .retombstone = restored.restoreMode else {
            return XCTFail("expected .retombstone, got \(String(describing: restored.restoreMode))")
        }
    }

    func test_leaves_ordinary_tree_edits_without_a_restore_payload() throws {
        // given — a plain edit, no spans at all
        let pos = CRDTTreePos(parentID: CRDTTreeNodeID(createdAt: self.seed, offset: 0),
                              leftSiblingID: CRDTTreeNodeID(createdAt: self.seed, offset: 0))
        let op = TreeEditOperation(parentCreatedAt: TimeTicket.initial,
                                   fromPos: pos,
                                   toPos: pos,
                                   contents: nil,
                                   splitLevel: 0,
                                   executedAt: self.executedAt)

        // when
        let bytes = try Converter.toOperation(op).serializedData()
        let decoded = try Converter.fromOperations([PbOperation(serializedBytes: bytes)])

        // then
        let restored = try XCTUnwrap(decoded.first as? TreeEditOperation)
        XCTAssertNil(restored.restoreSpans)
        XCTAssertNil(restored.restoreMode)
    }

    /// A span addresses content by insertion identity, so a node ID without a
    /// `createdAt` — or an attribute without an `updatedAt` — is malformed. It is
    /// rejected at the boundary rather than decoded into a default ticket that
    /// only fails deep inside the restore path.
    func test_rejects_a_span_missing_a_timestamp() throws {
        // given — a well-formed span, then each timestamp stripped in turn
        let base = Converter.toTreeRestoreSpan(self.textSpan())

        var noID = base
        noID.clearID()
        XCTAssertThrowsError(try Converter.fromTreeRestoreSpan(noID), "a span with no id must be rejected")

        var noParentTicket = base
        noParentTicket.parentID.clearCreatedAt()
        XCTAssertThrowsError(try Converter.fromTreeRestoreSpan(noParentTicket), "a parent anchor with no createdAt must be rejected")

        var noLeftTicket = base
        noLeftTicket.leftSiblingID.clearCreatedAt()
        XCTAssertThrowsError(try Converter.fromTreeRestoreSpan(noLeftTicket), "a left anchor with no createdAt must be rejected")

        var noAttrTicket = base
        var attr = PbNodeAttr()
        attr.value = "true"
        noAttrTicket.attributes["bold"] = attr
        XCTAssertThrowsError(try Converter.fromTreeRestoreSpan(noAttrTicket), "an attribute with no updatedAt must be rejected")
    }
}
