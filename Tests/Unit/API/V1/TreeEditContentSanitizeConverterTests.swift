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

/// A TreeEdit's content is always freshly created by the editing client, so it can never
/// legitimately be a split product, carry a merge lineage, or arrive tombstoned -- yet the wire
/// format carries every one of those fields on each tree node. The converter drops them on the
/// way in, and rejects an empty content group outright. Ported from yorkie-js-sdk#1406
/// "Sync the protos with Go and harden crafted tree payloads",
/// `tree_edit_content_sanitize_test.ts` (mirrors yorkie's `tree_content_tombstone_test.go` and
/// `tree_edit_content_missing_test.go`, yorkie#2033).
final class TreeEditContentSanitizeConverterTests: XCTestCase {
    private func ticket(_ lamport: Int64) -> TimeTicket {
        TimeTicket(lamport: lamport, delimiter: 0, actorID: ActorIDs.initial)
    }

    private lazy var pos = CRDTTreePos(
        parentID: CRDTTreeNodeID(createdAt: self.ticket(1), offset: 0),
        leftSiblingID: CRDTTreeNodeID(createdAt: self.ticket(1), offset: 0)
    )

    /// `roundTrip` encodes a TreeEdit carrying `content` and decodes it back, returning the
    /// decoded content.
    private func roundTrip(_ content: CRDTTreeNode) throws -> CRDTTreeNode {
        let op = TreeEditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            contents: [content],
            splitLevel: 0,
            executedAt: self.ticket(9)
        )
        let pbOperation = try Converter.toOperation(op)
        let bytes = try pbOperation.serializedData()
        let restoredPb = try PbOperation(serializedBytes: bytes)
        let restoredOps = try Converter.fromOperations([restoredPb])
        let decoded = try XCTUnwrap(restoredOps.first as? TreeEditOperation)
        let contents = try XCTUnwrap(decoded.contents)
        XCTAssertEqual(contents.count, 1)
        return contents[0]
    }

    /// `buildContent` builds `<p>hello</p>` as fresh content.
    private func buildContent() throws -> (paragraph: CRDTTreeNode, text: CRDTTreeNode) {
        let text = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(3), offset: 0), type: DefaultTreeNodeType.text.rawValue, value: "hello")
        let paragraph = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(2), offset: 0), type: "p", children: [])
        try paragraph.append(contentsOf: [text])
        return (paragraph, text)
    }

    func test_should_drop_a_tombstone_the_content_carries() throws {
        // given -- a node born tombstoned under a live parent would be counted
        // into the live data size with no GC pair ever registered for it.
        let (paragraph, text) = try self.buildContent()
        paragraph.removedAt = self.ticket(4)
        text.removedAt = self.ticket(4)

        // when
        let content = try self.roundTrip(paragraph)

        // then
        XCTAssertFalse(content.isRemoved, "content arrived tombstoned")
        XCTAssertEqual(content.innerChildren.count, 1)
        XCTAssertFalse(content.innerChildren[0].isRemoved, "content descendant arrived tombstoned")
        // The revived text has to be back in its parent's visible size: the
        // decode excludes removed children from it, so a tombstone cleared
        // without that bookkeeping would size the content as if empty.
        XCTAssertEqual(content.paddedSize, "hello".count + 2)
    }

    /// `craftMergeLineage` stamps a lineage the decoder really does derive a `mergedInto` from:
    /// `text` names its own parent as the parent a merge moved it out of, and that parent is a
    /// tombstone, which is the only shape `rebuildMergeState` plants a forwarding pointer for.
    private func craftMergeLineage(_ paragraph: CRDTTreeNode, _ text: CRDTTreeNode) {
        paragraph.mergedFrom = CRDTTreeNodeID(createdAt: self.ticket(5), offset: 0)
        paragraph.mergedAt = self.ticket(7)
        paragraph.removedAt = self.ticket(6)
        text.mergedFrom = paragraph.id
        text.mergedAt = self.ticket(7)
    }

    func test_should_drop_a_merge_lineage_the_content_carries() throws {
        // given -- only a merge may stamp mergedFrom/mergedAt; the §1.1
        // redirect and the §6.2 delete propagation read them as trusted
        // structural pointers.
        let (paragraph, text) = try self.buildContent()
        self.craftMergeLineage(paragraph, text)

        // iOS's `fromTreeNodes` wraps the decoded content in a `CRDTTree`
        // (unlike the JS converter's standalone node-builder), so decoding
        // really does run `rebuildMergeState` over this fixture before the
        // sanitizer strips what it derived -- the guard JS proves separately
        // with its own small tree is exercised directly here.
        let rawText = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(3), offset: 0), type: DefaultTreeNodeType.text.rawValue, value: "hello")
        let rawParagraph = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(2), offset: 0), type: "p", children: [])
        try rawParagraph.prepend(contentsOf: [rawText])
        self.craftMergeLineage(rawParagraph, rawText)
        _ = CRDTTree(root: rawParagraph, createdAt: self.ticket(8))
        XCTAssertEqual(rawParagraph.mergedInto, rawParagraph.id, "fixture does not make the decoder derive a mergedInto")

        // when
        let content = try self.roundTrip(paragraph)

        // then
        let decodedText = content.innerChildren[0]
        XCTAssertNil(content.mergedFrom)
        XCTAssertNil(content.mergedAt)
        XCTAssertNil(decodedText.mergedFrom)
        XCTAssertNil(decodedText.mergedAt)
        // The decoder really does derive mergedInto from mergedFrom while it
        // builds this content -- the guard above proves it -- so it has to go
        // too: a source must not keep pointing at a destination no field
        // records any more. Two halves of the sanitizer erase it, the
        // lineage drop and `unremove` (a derived pointer only ever sits on a
        // tombstone), and the assertion is on the end state rather than on
        // either one.
        XCTAssertNil(content.mergedInto)
    }

    /// `buildStyledContent` builds `<p live="yes">hello</p>` whose attribute table also holds one
    /// removed entry.
    private func buildStyledContent() throws -> CRDTTreeNode {
        let (_, text) = try self.buildContent()
        let attrs = RHT()
        attrs.set(key: "live", value: "yes", executedAt: self.ticket(2))
        attrs.set(key: "removed", value: String(repeating: "x", count: 64), executedAt: self.ticket(2))
        attrs.remove(key: "removed", executedAt: self.ticket(3))
        let paragraph = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(2), offset: 0), type: "p", attributes: attrs)
        try paragraph.append(contentsOf: [text])
        XCTAssertTrue(paragraph.attrs?.getNodeByKey("removed")?.isRemoved ?? false)
        return paragraph
    }

    func test_should_keep_an_attribute_tombstone_the_content_carries() throws {
        // given / when -- unlike the node tombstone above, a removed RHT
        // entry on content is NOT forgeable-only: the undo copy-reinsert
        // path re-sends a deep copy of nodes a real `removeStyle`
        // tombstoned, and the reinserted node has to keep rejecting the
        // stale styles the original rejects. Dropping it here would also
        // make this decoder disagree with every other producer and decoder
        // of the same bytes -- an older SDK, the Go SDK, the snapshot and
        // Set/Add paths -- which is divergence, not hardening.
        let content = try self.roundTrip(self.buildStyledContent())

        // then
        XCTAssertEqual(try content.attrs?.get(key: "live"), "yes")
        let removed = content.attrs?.getNodeByKey("removed")
        XCTAssertNotNil(removed, "content lost an attribute tombstone")
        XCTAssertTrue(removed?.isRemoved ?? false)
    }

    func test_should_book_an_attribute_tombstone_the_content_carries_into_gc() throws {
        // given -- what makes the kept entry harmless is that `edit`
        // registers it, the way the snapshot and Set/Add payload paths
        // register theirs. Without a pair it is storage `getDataSize`
        // charges to no one and nothing ever purges: growth the document
        // size cannot see.
        let content = try self.roundTrip(self.buildStyledContent())
        let root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(1), offset: 0), type: "r")
        let tree = CRDTTree(root: root, createdAt: self.ticket(1))
        var lamport: Int64 = 20

        // when
        let (_, pairs, _, _, _, _, _, _, _, _, _, _, _) = try tree.editT((0, 0), [content], 0, self.ticket(10)) {
            defer { lamport += 1 }
            return self.ticket(lamport)
        }

        // then
        let attrPairs = pairs.filter { $0.parent is CRDTTreeNode }
        XCTAssertEqual(attrPairs.count, 1, "no GC pair for the attribute tombstone")
        let attrPair = try XCTUnwrap(attrPairs.first, "no GC pair for the attribute tombstone")
        XCTAssertTrue((attrPair.child as? RHTNode) === content.attrs?.getNodeByKey("removed"))
        // Removed entries are skipped by `getDataSize`, so these bytes never
        // entered live: the pair has to carry its own size to gc rather than
        // move it out of live, which would drive live down by bytes it never
        // held.
        XCTAssertNotNil(attrPair.gcOnlySize)
    }

    func test_should_drop_split_links_the_content_carries() throws {
        // given
        let (paragraph, text) = try self.buildContent()
        text.insPrevID = CRDTTreeNodeID(createdAt: self.ticket(3), offset: 9)
        text.insNextID = CRDTTreeNodeID(createdAt: self.ticket(3), offset: 9)

        // when
        let decodedText = try self.roundTrip(paragraph).innerChildren[0]

        // then
        XCTAssertNil(decodedText.insPrevID)
        XCTAssertNil(decodedText.insNextID)
    }

    func test_should_reject_an_empty_content_group() throws {
        // given -- an empty group decodes to no root; carried into the
        // operation it is a crash on apply, where the edit deep-copies each
        // content.
        let (paragraph, _) = try self.buildContent()
        let op = TreeEditOperation(
            parentCreatedAt: TimeTicket.initial,
            fromPos: self.pos,
            toPos: self.pos,
            contents: [paragraph],
            splitLevel: 0,
            executedAt: self.ticket(9)
        )
        var pbOp = try Converter.toOperation(op)
        guard case .treeEdit(var pbTreeEdit) = pbOp.body else {
            return XCTFail("expected a tree edit operation body")
        }
        pbTreeEdit.contents = [PbTreeNodes()]
        pbOp.body = Yorkie_V1_Operation.OneOf_Body.treeEdit(pbTreeEdit)

        // when
        let bytes = try pbOp.serializedData()

        // then
        XCTAssertThrowsError(try Converter.fromOperations([PbOperation(serializedBytes: bytes)])) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            XCTAssertTrue(yorkieError.message.contains("entry with no node"), yorkieError.message)
        }
    }
}
