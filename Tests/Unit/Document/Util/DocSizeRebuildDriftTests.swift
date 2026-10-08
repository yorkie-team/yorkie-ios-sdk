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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Ports: `packages/sdk/test/unit/document/docsize_rebuild_drift_test.ts` from
/// yorkie-js-sdk 8fb5a71c "Make docSize agree with a rebuild (issue #1383, part
/// 3)" (yorkie-js-sdk#1392).
///
/// `docSize` is a running accumulator: every operation reports a diff which is
/// added, and nothing ever recomputes it. It therefore cannot notice its own
/// drift, and a rebuild is the only witness. It also has to agree with the Go
/// server, which rebuilds the document from its change log -- the size limit
/// is enforced client-side against each peer's own accounting, so a
/// disagreement is a different allowance per peer for the same document.

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// Builds two in-process documents that share a document key but use
/// distinct actors, mirroring the JS `newReplicas` helper.
@MainActor
private func newReplicas() -> (Document, Document) {
    let d1 = Document(key: "test-doc")
    let d2 = Document(key: "test-doc")
    d1.setActor(actorA1)
    d2.setActor(actorA2)
    return (d1, d2)
}

/// Exchanges pending local changes between two in-process documents,
/// mimicking a server round-trip without going through real serialization.
///
/// Because each replica applies its own change first, the pair covers BOTH
/// delivery orders of a concurrent pair in one exchange: d1 saw its own
/// change then the peer's, d2 the other way round. Asserting on both is what
/// makes a case "in both delivery orders". See the identical helper in
/// `DocumentSizeContainerGCTests.swift`.
@MainActor
private func crossSync(_ d1: Document, _ d2: Document) throws {
    let p1 = d1.createChangePack()
    let p2 = d2.createChangePack()

    try d2.applyChangePack(ChangePack(key: p1.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: p1.getChanges(),
                                      versionVector: VersionVector.initial))
    try d1.applyChangePack(ChangePack(key: p2.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: p2.getChanges(),
                                      versionVector: VersionVector.initial))

    func ack(_ pack: ChangePack) -> ChangePack {
        let changes = pack.getChanges()
        let lastSeq = changes.last?.id.getClientSeq() ?? 0
        return ChangePack(key: pack.getDocumentKey(),
                          checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                          isRemoved: false,
                          changes: [],
                          versionVector: VersionVector.initial)
    }
    try d1.applyChangePack(ack(p1))
    try d2.applyChangePack(ack(p2))
}

/// Asserts the running `docSize` equals what a root rebuilt from the same
/// content computes.
@MainActor
private func assertMatchesRebuild(_ doc: Document, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let rebuiltObject = doc.getRootObject().deepcopy() as? CRDTObject else {
        XCTFail("deepcopy did not produce a CRDTObject", file: file, line: line)
        return
    }
    let rebuilt = CRDTRoot(rootObject: rebuiltObject)
    XCTAssertEqual(doc.getDocSize().live, rebuilt.getDocSize().live, "\(msg): live", file: file, line: line)
    XCTAssertEqual(doc.getDocSize().gc, rebuilt.getDocSize().gc, "\(msg): gc", file: file, line: line)
}

/// Builds a two-paragraph tree.
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

final class DocSizeRebuildDriftTests: XCTestCase {
    // charges nothing for the value of a removed tree attribute test
    //
    // A rebuild through `deepcopy` cannot witness this one: it copies the
    // tombstone, value and all, so a running size that kept the value agrees
    // with it. What it disagrees with is a rebuild from the CHANGE LOG -- the
    // server's -- which replays the same removal and holds nothing. The
    // observable claim on this side is that the value's LENGTH stops
    // mattering once the attribute is removed, so styling with a long value
    // and a short one has to land on the same size.
    @MainActor
    func test_charges_nothing_for_the_value_of_a_removed_tree_attribute() throws {
        func sizeAfterRemoving(_ value: String) throws -> DocSize {
            let doc = try seededTree()
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": value])
            }
            try doc.update { root, _ in
                try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["bold"])
            }
            return doc.getDocSize()
        }

        XCTAssertEqual(
            try sizeAfterRemoving(String(repeating: "x", count: 64)),
            try sizeAfterRemoving("x"),
            "a removed attribute still charged its value"
        )
    }

    // charges nothing for the value of a removed text attribute test
    @MainActor
    func test_charges_nothing_for_the_value_of_a_removed_text_attribute() throws {
        func sizeAfterRemoving(_ value: String) throws -> DocSize {
            let doc = Document(key: "test-doc")
            try doc.update { root, _ in
                root.k = JSONText()
                (root.k as? JSONText)?.edit(0, 0, "abcdefghij")
            }
            try doc.update { root, _ in
                (root.k as? JSONText)?.setStyle(0, 10, ["bold": value])
            }
            // `CRDTText.removeStyle` has no proxy method; undoing the style is
            // the route the public API gives to it.
            try doc.undo()
            return doc.getDocSize()
        }

        XCTAssertEqual(
            try sizeAfterRemoving(String(repeating: "x", count: 64)),
            try sizeAfterRemoving("x"),
            "a removed attribute still charged its value"
        )
    }

    // charges nothing for the value dropped from a removed node test
    //
    // The node holding the attribute is itself a tombstone, so the container
    // never counted the attribute into live: the dropped value has to come
    // out of the gc charge taken when the node was removed.
    @MainActor
    func test_charges_nothing_for_the_value_dropped_from_a_removed_node() throws {
        func sizeAfterRemoving(_ value: String) throws -> DocSize {
            let (d1, d2) = newReplicas()
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(
                    type: "doc",
                    children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "efgh")])
                    ]
                ))
                try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": value])
            }
            try crossSync(d1, d2)

            try d1.update { root, _ in
                try (root.t as? JSONTree)?.editByPath([0], [1])
            }
            try d2.update { root, _ in
                try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["bold"])
            }
            try crossSync(d1, d2)
            return d2.getDocSize()
        }

        XCTAssertEqual(
            try sizeAfterRemoving(String(repeating: "x", count: 64)),
            try sizeAfterRemoving("x"),
            "a removed attribute on a tombstoned node still charged its value"
        )
    }

    // charges the movedAt ticket of a moved array element test
    @MainActor
    func test_charges_the_movedAt_ticket_of_a_moved_array_element() throws {
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.arr = ["a", "b", "c"]
        }
        assertMatchesRebuild(doc, "before any move")

        try doc.update { root, _ in
            try (root.arr as? JSONArray)?.moveAfterByIndex(prevIndex: 2, targetIndex: 0)
        }
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[\"b\",\"c\",\"a\"]}")
        assertMatchesRebuild(doc, "after one move")
    }

    // charges the movedAt ticket exactly once across repeated moves test
    @MainActor
    func test_charges_the_movedAt_ticket_exactly_once_across_repeated_moves() throws {
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.arr = ["a", "b", "c"]
        }

        // Move 'a' to the back, then keep moving that SAME element. A re-move
        // overwrites a ticket already charged; charging it again would walk
        // live up without bound on a list the user reorders repeatedly.
        try doc.update { root, _ in
            try (root.arr as? JSONArray)?.moveAfterByIndex(prevIndex: 2, targetIndex: 0)
        }
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[\"b\",\"c\",\"a\"]}")
        let afterFirst = doc.getDocSize()

        try doc.update { root, _ in
            guard let arr = root.arr as? JSONArray, let element = arr.getElement(byIndex: 2) as? Primitive else { return }
            try arr.moveFront(id: element.id)
        }
        try doc.update { root, _ in
            guard let arr = root.arr as? JSONArray, let element = arr.getElement(byIndex: 0) as? Primitive else { return }
            try arr.moveLast(id: element.id)
        }
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[\"b\",\"c\",\"a\"]}")
        XCTAssertEqual(doc.getDocSize().live, afterFirst.live, "a re-move must not charge the ticket again")
        assertMatchesRebuild(doc, "after three moves")
    }

    // agrees with a rebuild on a concurrent move and remove test
    //
    // The two replicas see the pair in opposite orders. In d2's order the
    // remove lands first, so the element is already a tombstone when the move
    // stamps its ticket -- live is not holding that element at all, and the
    // charge has to go to gc instead.
    @MainActor
    func test_agrees_with_a_rebuild_on_a_concurrent_move_and_remove() throws {
        let (d1, d2) = newReplicas()

        try d1.update { root, _ in
            root.arr = ["a", "b", "c"]
        }
        try crossSync(d1, d2)

        try d1.update { root, _ in
            try (root.arr as? JSONArray)?.moveAfterByIndex(prevIndex: 2, targetIndex: 0)
        }
        try d2.update { root, _ in
            guard let arr = root.arr as? JSONArray, let element = arr.getElement(byIndex: 0) as? Primitive else { return }
            arr.remove(byID: element.id)
        }
        try crossSync(d1, d2)

        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "replicas must converge first")
        assertMatchesRebuild(d1, "move applied before remove")
        assertMatchesRebuild(d2, "remove applied before move")
    }

    // collects a move charged to gc without overshooting test
    //
    // Same concurrent pair as above, then collected. When the remove lands
    // first the move's ticket is charged to gc, and `accMovedElement` also
    // tops up the element's `sizeInGC` entry -- collection subtracts the
    // element's CURRENT size, so without the top-up it takes back one ticket
    // more than was ever put in and `docSize.gc` ends up short. Nothing but a
    // collection can witness that top-up.
    @MainActor
    func test_collects_a_move_charged_to_gc_without_overshooting() throws {
        let (d1, d2) = newReplicas()

        try d1.update { root, _ in
            root.arr = ["a", "b", "c"]
        }
        try crossSync(d1, d2)

        try d1.update { root, _ in
            try (root.arr as? JSONArray)?.moveAfterByIndex(prevIndex: 2, targetIndex: 0)
        }
        try d2.update { root, _ in
            guard let arr = root.arr as? JSONArray, let element = arr.getElement(byIndex: 0) as? Primitive else { return }
            arr.remove(byID: element.id)
        }
        try crossSync(d1, d2)
        XCTAssertGreaterThan(d2.getDocSize().gc.meta, 0, "the tombstone must be in gc")

        let vector = maxVectorOf(actors: [actorA1, actorA2])
        _ = d1.garbageCollect(minSyncedVersionVector: vector)
        _ = d2.garbageCollect(minSyncedVersionVector: vector)

        let empty = DataSize(data: 0, meta: 0)
        XCTAssertEqual(d1.getDocSize().gc, empty, "gc after collection on d1")
        XCTAssertEqual(d2.getDocSize().gc, empty, "gc after collection on d2")
        XCTAssertEqual(d1.getDocSize(), d2.getDocSize(), "the two delivery orders must collect to the same size")
        assertMatchesRebuild(d1, "collected, move applied before remove")
        assertMatchesRebuild(d2, "collected, remove applied before move")
    }

    // agrees with a rebuild on a concurrent set and removeStyle test
    //
    // A removed attribute holds no value, so the bytes it was charging have
    // to leave whichever side held them. In one order the removeStyle sees
    // the peer's value, in the other it sees its own.
    @MainActor
    func test_agrees_with_a_rebuild_on_a_concurrent_set_and_removeStyle() throws {
        let (d1, d2) = newReplicas()

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "efgh")])
                ]
            ))
            try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": "true"])
        }
        try crossSync(d1, d2)
        assertMatchesRebuild(d1, "after the initial style")

        try d1.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": "maybe"])
        }
        try d2.update { root, _ in
            try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["bold"])
        }
        try crossSync(d1, d2)

        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "replicas must converge first")
        assertMatchesRebuild(d1, "set applied before removeStyle")
        assertMatchesRebuild(d2, "removeStyle applied before set")
    }

    // agrees with a rebuild when removeStyle lands on a removed node test
    //
    // The node holding the attribute is itself a tombstone, so the container
    // never counted the attribute into live: the dropped value comes out of
    // the gc charge taken when the node was removed, not out of live.
    @MainActor
    func test_agrees_with_a_rebuild_when_removeStyle_lands_on_a_removed_node() throws {
        let (d1, d2) = newReplicas()

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "efgh")])
                ]
            ))
            try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": "true"])
        }
        try crossSync(d1, d2)

        try d1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0], [1])
        }
        try d2.update { root, _ in
            try (root.t as? JSONTree)?.removeStyleByPath([0], [1], ["bold"])
        }
        try crossSync(d1, d2)

        XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON(), "replicas must converge first")
        assertMatchesRebuild(d1, "edit applied before removeStyle")
        assertMatchesRebuild(d2, "removeStyle applied before edit")
    }
}
