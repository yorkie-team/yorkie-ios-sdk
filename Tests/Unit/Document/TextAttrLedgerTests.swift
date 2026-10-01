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

/// Ports: `packages/sdk/test/unit/document/text_attr_ledger_test.ts` from
/// yorkie-js-sdk PR #1365 "Charge an attribute to live only while it is the
/// live value" (commit 190204f8).
///
/// `docSize.live` is a RUNNING ACCUMULATOR: operations return a diff and it is
/// added, never recomputed. So it cannot detect its own drift, and the only
/// way to see any of this is to rebuild a root from the same content and
/// compare. The Go server fixed the same four defects; this is the mirror.
/// They must agree, or the same document is a different size depending on
/// which SDK is looking at it, and MaxSizeLimit is enforced client-side.

/// `rebuilt` mirrors a root from the given document's content, the way every
/// client joining an existing document holds one.
@MainActor
private func rebuilt(_ doc: Document) throws -> CRDTRoot {
    guard let rebuiltObject = doc.getRootObject().deepcopy() as? CRDTObject else {
        XCTFail("deepcopy did not produce a CRDTObject")
        return CRDTRoot()
    }
    return CRDTRoot(rootObject: rebuiltObject)
}

/// `assertLedgerExact` checks the invariant the whole of docSize rests on: a
/// document's garbage is a function of its content, so a root rebuilt from
/// that content reports the same size and the same count.
@MainActor
private func assertLedgerExact(_ doc: Document, _ msg: String) throws {
    let root = try rebuilt(doc)
    XCTAssertEqual(doc.getDocSize().live, root.getDocSize().live, "\(msg): live")
    XCTAssertEqual(doc.getDocSize().gc, root.getDocSize().gc, "\(msg): gc")
    XCTAssertEqual(doc.getGarbageLength(), root.garbageLength, "\(msg): count")
}

private func assertNotNegative(_ size: DataSize, _ msg: String) {
    XCTAssertGreaterThanOrEqual(size.data, 0, "\(msg): live data went negative")
    XCTAssertGreaterThanOrEqual(size.meta, 0, "\(msg): live meta went negative")
}

/// `seededText` builds a document with a single Text field seeded with
/// "abcdefghij".
@MainActor
private func seededText() throws -> Document {
    let doc = Document(key: "test-doc")
    try doc.update { root, _ in
        root.k = JSONText()
        _ = (root.k as? JSONText)?.edit(0, 0, "abcdefghij")
    }
    return doc
}

/// `seededTree` builds a document whose tree has two `<p>` siblings holding
/// "abcd" and "efgh".
@MainActor
private func seededTree() throws -> Document {
    let doc = Document(key: "test-doc")
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(
            type: "doc",
            children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "efgh")])
            ]
        ))
    }
    return doc
}

final class TextAttrLedgerTests: XCTestCase {
    /// `RHT.set` drops a superseded LIVE node from the map and reports only
    /// the node it installed, so nothing ever subtracts the old value's
    /// bytes. Every overwrite leaks one attribute, on the most common
    /// operation a rich-text editor performs, and `MaxSizeLimit` reads
    /// live + gc.
    @MainActor
    func test_does_not_leak_when_a_text_attribute_is_overwritten() throws {
        // given
        let doc = try seededText()

        // when
        for value in ["1", "2", "3"] {
            try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": value]) }
        }

        // then
        try assertLedgerExact(doc, "after three text overwrites")
    }

    @MainActor
    func test_does_not_leak_when_a_tree_attribute_is_overwritten() throws {
        // given
        let doc = try seededTree()

        // when
        for value in ["1", "2", "3"] {
            try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0], [1], ["b": value]) }
        }

        // then
        try assertLedgerExact(doc, "after three tree overwrites")
    }

    /// A tombstoned attribute belongs to gc, not to live. `CRDTTextValue
    /// .getDataSize` counts removed attributes while the tree's skips them, so
    /// the text half held the tombstone in live and in gc at once, and kept
    /// it in live after collection purged it from gc.
    @MainActor
    func test_moves_a_tombstoned_text_attribute_out_of_live() throws {
        // given
        let doc = try seededText()
        let before = doc.getDocSize().live

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "1"]) }
        try doc.undo()

        // then
        XCTAssertEqual(doc.getGarbageLength(), 1, "the tombstone is registered")
        XCTAssertEqual(doc.getDocSize().live, before, "charged to gc and live at once")
        try assertLedgerExact(doc, "after undoing a text style")
    }

    @MainActor
    func test_does_not_strand_a_purged_text_attribute_in_live() throws {
        // given
        let doc = try seededText()
        let before = doc.getDocSize().live

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "1"]) }
        try doc.undo()
        _ = doc.garbageCollect(minSyncedVersionVector: doc.getVersionVector())

        // then
        XCTAssertEqual(doc.getGarbageLength(), 0)
        XCTAssertEqual(doc.getDocSize().live, before, "the purged tombstone never left live")
        try assertLedgerExact(doc, "after collecting a text attribute tombstone")
    }

    /// A style whose range opens inside one element and runs past its end
    /// yields that element as an End token with no Start token. Both halves
    /// of the per-token accounting have to agree about such a visit.
    @MainActor
    func test_keeps_live_exact_for_a_style_straddling_an_element_boundary() throws {
        // given
        let doc = try seededTree()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0], [2], ["b": "1"]) }

        // when / then
        for index in 0 ..< 6 {
            try doc.update { root, _ in try (root.t as? JSONTree)?.style(1, 6, ["b": "v\(index)"]) }
            try assertLedgerExact(doc, "straddling overwrite \(index + 1)")
            assertNotNegative(doc.getDocSize().live, "straddling overwrite \(index + 1)")
        }
    }

    /// A split deep-copies the value's attributes, tombstones included, so
    /// the copy is new garbage under a new parent with no registration of its
    /// own.
    @MainActor
    func test_keeps_a_split_text_attribute_tombstone_collectable() throws {
        // given
        let doc = try seededText()
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "1"]) }
        try doc.undo()
        XCTAssertEqual(doc.getGarbageLength(), 1, "one tombstone before the split")

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.edit(5, 5, "X") }

        // then
        try assertLedgerExact(doc, "after splitting the node the tombstone rides on")

        let purged = doc.garbageCollect(minSyncedVersionVector: doc.getVersionVector())
        XCTAssertGreaterThan(purged, 0)
        XCTAssertEqual(doc.getGarbageLength(), 0, "every tombstone was collected")
    }

    /// `splitValue` used to replace the LEFT node's value with a brand new
    /// object, and `CRDTRoot.keyOf` identifies a pair's parent by object
    /// identity, so every pair already registered against that value was
    /// orphaned. This needs no split at style time -- the pair is registered
    /// first, and any later split of that node orphans it.
    @MainActor
    func test_keeps_a_registered_pair_alive_across_a_later_split() throws {
        // given
        let doc = try seededText()
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "1"]) }
        try doc.undo()
        XCTAssertEqual(doc.getGarbageLength(), 1, "registered before any split")

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.edit(3, 3, "Z") }

        // then
        try assertLedgerExact(doc, "after a split of the node the pair names")

        _ = doc.garbageCollect(minSyncedVersionVector: doc.getVersionVector())
        try assertLedgerExact(doc, "after collecting")
        XCTAssertEqual(doc.getGarbageLength(), 0)

        let root = try rebuilt(doc)
        XCTAssertEqual(
            root.getDocSize().gc,
            DataSize(data: 0, meta: 0),
            "the content still holds a tombstone the ledger called collected"
        )
    }

    /// A style that spans both live and already-deleted text, then an undo of
    /// it.
    ///
    /// NOTE ON WHAT THIS DOES NOT COVER. `canStyle` skips a node whose removal
    /// the change had already seen, and a local change has seen every removal
    /// in its own replica -- so the history below never reaches a tombstoned
    /// node at all, and the accounting case for one is exercised in
    /// `StyleTombstoneTests` instead, on the concurrent histories that do
    /// reach it. This test pins only that the ledger stays exact along the
    /// local path.
    @MainActor
    func test_balances_a_style_that_spans_deleted_text_and_its_undo() throws {
        // given
        let doc = try seededText()

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(4, 6, ["bbbbbbbbbb": "vvvvvvvvvv"]) }
        try doc.update { root, _ in _ = (root.k as? JSONText)?.edit(4, 6, "") }
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 8, ["bbbbbbbbbb": "vvvvvvvvvv"]) }
        try doc.undo()

        // then
        try assertLedgerExact(doc, "after undoing a style that spanned deleted text")
        assertNotNegative(doc.getDocSize().live, "style spanning deleted text")

        _ = doc.garbageCollect(minSyncedVersionVector: doc.getVersionVector())
        XCTAssertEqual(doc.getGarbageLength(), 0)
        XCTAssertEqual(doc.getDocSize().gc, DataSize(data: 0, meta: 0), "gc residue")
    }

    /// Re-styling a key whose value is a tombstone REVIVES it. The pair is
    /// re-registered under the same key, which un-registers it: the attribute
    /// is no longer collectable, it is simply gone. `registerGCPair` has to
    /// subtract exactly what the first registration added, or the bytes stay
    /// charged to gc for the life of the document.
    @MainActor
    func test_does_not_strand_a_revived_attribute_in_gc() throws {
        // given
        let doc = try seededText()
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "1"]) }
        try doc.undo()
        XCTAssertEqual(doc.getGarbageLength(), 1)

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "2"]) }

        // then
        XCTAssertEqual(doc.getGarbageLength(), 0, "the tombstone was revived")
        try assertLedgerExact(doc, "after reviving an attribute tombstone")
    }

    @MainActor
    func test_does_not_strand_a_revived_tree_attribute_in_gc() throws {
        // given
        let doc = try seededTree()
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0], [1], ["b": "1"]) }
        try doc.undo()

        // when
        try doc.update { root, _ in try (root.t as? JSONTree)?.styleByPath([0], [1], ["b": "2"]) }

        // then
        try assertLedgerExact(doc, "after reviving a tree attribute tombstone")
    }

    /// `Document.ensureClone` rebuilds the clone from a POPULATED root after a
    /// snapshot, an offline restore, or an update whose callback threw. The
    /// clone's split values must not alias the root's, or the clone's edit
    /// mutates the root as a side effect and the root's own application of
    /// the same operation then sees an already-shortened value.
    @MainActor
    func test_keeps_the_tail_when_a_split_follows_a_snapshot() throws {
        // given
        let source = try seededText()
        let bytes = try Converter.snapshotToBytes(root: source.getRootObject(), presences: [:])
        let doc = Document(key: "test-doc")
        try doc.applySnapshot(1, source.getVersionVector(), bytes, -1)

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.edit(5, 5, "X") }

        // then
        XCTAssertEqual(
            doc.toJSON(),
            "{\"k\":[{\"val\":\"abcde\"},{\"val\":\"X\"},{\"val\":\"fghij\"}]}",
            "the tail after the split point was destroyed"
        )
    }

    @MainActor
    func test_charges_live_for_a_style_that_follows_a_snapshot() throws {
        // given
        let source = try seededText()
        let bytes = try Converter.snapshotToBytes(root: source.getRootObject(), presences: [:])
        let doc = Document(key: "test-doc")
        try doc.applySnapshot(1, source.getVersionVector(), bytes, -1)

        // when
        try doc.update { root, _ in _ = (root.k as? JSONText)?.setStyle(0, 10, ["b": "1"]) }

        // then
        try assertLedgerExact(doc, "style after a snapshot")
    }
}
