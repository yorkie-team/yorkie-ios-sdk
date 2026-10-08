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

// Ported from yorkie-js-sdk 790422ce:
// `packages/sdk/test/integration/history_tree_opinfo_test.ts`
// (yorkie-js-sdk#1421, "Report where Tree undo and redo landed in their
// OpInfo"). `Tests/Unit/Document/TreeUndoOpInfoTests.swift` already ports the
// two new-behaviour cases of the JS file's companion unit test
// (`tree_undo_opinfo_test.ts`, referenced from this file's own comments).
// This file ports the other seven: the five parametrized edit shapes, the
// shifted-position case, and the parent-then-children case.
//
// None of the seven need a live server: the JS file's `withTwoClientsAndDocuments`
// plus three `sync()` round trips exist to push local changes through a real
// server and pull the peer's back, which an in-process bidirectional
// `crossSync` (both change packs exchanged and acked at once) achieves in one
// call. `follow` mirrors `doc`'s tree-edit OpInfos into a second in-process
// `Document` exactly as the JS harness does; the only JS feature this drops is
// `event.source === 'undoredo'`, which iOS's `ChangeInfo` does not carry on
// the event. Since each test here calls `undo()`/`redo()` directly and that
// call publishes its `LocalChangeEvent` synchronously before returning (see
// `Document.executeUndoRedo`), scoping collection to the call -- a capturing
// flag toggled immediately around it -- is equivalent to filtering on the
// source the JS event carries.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let actorHistoryA: ActorID = "000000000000000000000001"
private let actorHistoryB: ActorID = "000000000000000000000002"
private let historyDocKey = "tree-history-opinfo"

/// Returns a document with the given actor id already set, pinned to the
/// shared key so change packs exchange cleanly between replicas.
@MainActor
private func replicaWithHistoryActor(_ actorID: ActorID) -> Document {
    let doc = Document(key: historyDocKey)
    doc.setActor(actorID)
    return doc
}

/// Exchanges pending local changes between two in-process documents and acks
/// both sides, mimicking a server round trip. One call converges both
/// directions regardless of who edited, which is what three real
/// `client.sync()` calls (push, push, pull) achieve against a live server.
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

/// Reads a replica's Tree field as XML.
@MainActor
private func xmlOf(_ doc: Document) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
}

/// Renders tree node content the same way regardless of element/text kind, so
/// a `TreeEditOpInfo.value` can be compared against an expected literal.
private func describe(_ nodes: [any JSONTreeNode]) -> String {
    nodes.map(\.toJSONString).joined(separator: ",")
}

/// A `<p>` element wrapping a single text node.
private func para(_ value: String) -> JSONTreeElementNode {
    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: value)])
}

/// Mirrors a document's tree-edit OpInfos into a second in-process document,
/// the way an editor binding would, so the mirror stays equal to `doc` for as
/// long as the OpInfos fully describe the change. `isCapturingUndoRedo`,
/// toggled by the caller around its own `undo()`/`redo()` calls, records
/// those OpInfos separately -- the in-process equivalent of filtering on
/// `event.source === 'undoredo'`.
@MainActor
private final class TreeHistoryFollower {
    private let mirror: Document
    private(set) var undoRedoInfos: [TreeEditOpInfo] = []
    var isCapturingUndoRedo = false

    init(_ doc: Document, initial: JSONTreeElementNode) throws {
        self.mirror = Document(key: "mirror")
        try self.mirror.update { root, _ in
            root.t = JSONTree(initialRoot: initial)
        }

        doc.subscribe { [weak self] event, _ in
            guard let self else { return }

            let operations: [any OperationInfo]
            let isLocal: Bool
            switch event {
            case let local as LocalChangeEvent:
                operations = local.value.operations
                isLocal = true
            case let remote as RemoteChangeEvent:
                operations = remote.value.operations
                isLocal = false
            default:
                return
            }

            for op in operations {
                guard let info = op as? TreeEditOpInfo else { continue }
                if self.isCapturingUndoRedo, isLocal {
                    self.undoRedoInfos.append(info)
                }
                do {
                    try self.mirror.update { root, _ in
                        guard let tree = root.t as? JSONTree else { return }
                        if info.value.isEmpty {
                            _ = try tree.editByPath(info.fromPath, info.toPath)
                        } else {
                            _ = try tree.editBulkByPath(info.fromPath, info.toPath, info.value)
                        }
                    }
                } catch {
                    XCTFail("mirror failed to replay \(info): \(error)")
                }
            }
        }
    }

    func xml() throws -> String {
        try XCTUnwrap(self.mirror.getRoot().t as? JSONTree).toXML()
    }
}

final class TreeHistoryOpInfoPositionsTests: XCTestCase {
    // MARK: - Parametrized edit shapes

    /// Drives one (edit, undo, redo) round trip on `d1`, syncing `d2` after
    /// every step, and asserts each replica's mirror -- built purely from the
    /// tree-edit OpInfos that replica published -- still matches it. Every
    /// OpInfo captured from `d1`'s own undo/redo reports a non-empty path.
    @MainActor
    private func assertUndoAndRedoLanded(
        initial: [JSONTreeElementNode],
        edit: (JSONTree) throws -> Void
    ) throws {
        // given
        let d1 = replicaWithHistoryActor(actorHistoryA)
        let d2 = replicaWithHistoryActor(actorHistoryB)
        let root = JSONTreeElementNode(type: "doc", children: initial)

        try d1.update { treeRoot, _ in treeRoot.t = JSONTree(initialRoot: root) }
        try crossSync(d1, d2)

        let m1 = try TreeHistoryFollower(d1, initial: root)
        let m2 = try TreeHistoryFollower(d2, initial: root)

        func check(_ label: String) throws {
            XCTAssertEqual(try m1.xml(), try xmlOf(d1), "d1 \(label)")
            XCTAssertEqual(try m2.xml(), try xmlOf(d2), "d2 \(label)")
        }

        // when / then
        try d1.update { treeRoot, _ in
            guard let tree = treeRoot.t as? JSONTree else { return }
            try edit(tree)
        }
        try crossSync(d1, d2)
        try check("after edit")

        m1.isCapturingUndoRedo = true
        try d1.undo()
        m1.isCapturingUndoRedo = false
        try crossSync(d1, d2)
        try check("after undo")

        m1.isCapturingUndoRedo = true
        try d1.redo()
        m1.isCapturingUndoRedo = false
        try crossSync(d1, d2)
        try check("after redo")

        for info in m1.undoRedoInfos {
            XCTAssertGreaterThan(info.fromPath.count, 0, "undo/redo reports a path")
        }
    }

    @MainActor
    func test_reports_where_undo_and_redo_of_insert_text_landed() throws {
        try self.assertUndoAndRedoLanded(initial: [para("abcd")]) { tree in
            _ = try tree.editByPath([0, 2], [0, 2], JSONTreeTextNode(value: "X"))
        }
    }

    @MainActor
    func test_reports_where_undo_and_redo_of_delete_text_landed() throws {
        try self.assertUndoAndRedoLanded(initial: [para("abcd")]) { tree in
            _ = try tree.editByPath([0, 1], [0, 3])
        }
    }

    /// CONFIRMED IOS DIVERGENCE FROM JS: restoring a multi-node subtree (an
    /// element plus its text child) in one change reports the PARENT's
    /// `TreeEditOpInfo.value` with the child already embedded, even though
    /// the child is ALSO reported in its own separate `TreeEditOpInfo` right
    /// after it -- so a consumer that applies every OpInfo literally (as this
    /// file's `TreeHistoryFollower`, or any real editor binding, does) inserts
    /// the child's content twice.
    ///
    /// Root cause: `CRDTTree.makeInsertionChange`
    /// (Sources/Document/Crdt/CRDTTree.swift:3357-3372) stores a LIVE
    /// `CRDTTreeNode` reference (`value: .nodes([node])`), not a snapshot.
    /// `TreeEditOperation.executeIdentityPreservingEdit`'s opInfo construction
    /// (Sources/Document/Operation/TreeEditOperation.swift:579-594) converts
    /// every queued node to a `JSONTreeNode` only AFTER the whole
    /// retombstone+restore loop has run (`CRDTTree.restore`,
    /// Sources/Document/Crdt/CRDTTree.swift:3134-3211) -- by which point every
    /// span's `unremove()` has already executed. `CRDTTreeNode.toJSONTreeNode`
    /// (Sources/Document/Json/JSONTree.swift:41-53) recurses into
    /// `node.children`, which filters on `isRemoved` AT CONVERSION TIME
    /// (`IndexTreeNode.children`, Sources/Util/IndexTree.swift:300-306) -- so
    /// by the time the PARENT's queued node is finally converted, a child
    /// revived by a LATER span in the same change already reads as live and
    /// is pulled into the parent's snapshot.
    ///
    /// JS does not have this hole: `CRDTTree.restore`'s `revived` closure
    /// calls `makeInsertionChange`, which calls `toTreeNode(node)` EAGERLY,
    /// inside the per-span loop (`packages/sdk/src/document/crdt/tree.ts`,
    /// `restore`/`makeInsertionChange`) -- so the parent's snapshot is taken
    /// before the child span runs, while `node.children` (same
    /// filter-on-`isRemoved` semantics, `index_tree.ts:333-338`) is still
    /// empty. iOS defers the snapshot; JS does not.
    @MainActor
    func test_reports_where_undo_and_redo_of_insert_element_landed() throws {
        try XCTExpectFailure("""
        iOS bug: redo restores "<p>cd</p>" by identity (the identity-preserving         restore path), and the parent <p>'s TreeEditOpInfo wrongly embeds the         already-revived "cd" text child a second time. See the doc comment on         this test for the full root-cause trace.
        """) {
            try self.assertUndoAndRedoLanded(initial: [para("ab")]) { tree in
                _ = try tree.editByPath([1], [1], para("cd"))
            }
        }
    }

    /// See the divergence documented on
    /// `test_reports_where_undo_and_redo_of_insert_element_landed`: undoing
    /// this deletion restores "<p>cd</p>" by identity, and the parent's
    /// OpInfo embeds the child a second time.
    @MainActor
    func test_reports_where_undo_and_redo_of_delete_element_landed() throws {
        try XCTExpectFailure("""
        iOS bug: undo restores "<p>cd</p>" by identity, and the parent <p>'s         TreeEditOpInfo wrongly embeds the already-revived "cd" text child a         second time (CRDTTree.swift:3357-3372, TreeEditOperation.swift:579-594).
        """) {
            try self.assertUndoAndRedoLanded(initial: [para("ab"), para("cd")]) { tree in
                _ = try tree.editByPath([0], [1])
            }
        }
    }

    /// See the divergence documented on
    /// `test_reports_where_undo_and_redo_of_insert_element_landed`.
    @MainActor
    func test_reports_where_undo_and_redo_of_delete_two_elements_landed() throws {
        try XCTExpectFailure("""
        iOS bug: undo restores both deleted paragraphs by identity, and each         restored parent <p>'s TreeEditOpInfo wrongly embeds its already-revived         text child a second time (CRDTTree.swift:3357-3372,         TreeEditOperation.swift:579-594).
        """) {
            try self.assertUndoAndRedoLanded(initial: [para("ab"), para("cd"), para("ef")]) { tree in
                _ = try tree.editByPath([0], [2])
            }
        }
    }

    // MARK: - Shifted positions

    /// A peer inserts text before the run `d1` is about to undo. The undo's
    /// reverse operation has to resolve against the CURRENT tree -- shifted
    /// by the peer's insert -- not the positions the original edit recorded.
    @MainActor
    func test_reports_shifted_positions_when_a_peer_edited_before_the_undone_text() throws {
        // given
        let d1 = replicaWithHistoryActor(actorHistoryA)
        let d2 = replicaWithHistoryActor(actorHistoryB)
        let root = JSONTreeElementNode(type: "doc", children: [para("ab")])

        try d1.update { treeRoot, _ in treeRoot.t = JSONTree(initialRoot: root) }
        try crossSync(d1, d2)

        let m1 = try TreeHistoryFollower(d1, initial: root)
        let m2 = try TreeHistoryFollower(d2, initial: root)

        // when -- d1 appends "cd" to "ab", both converge on "abcd", then d2
        // inserts "XYZ" at the very front.
        try d1.update { treeRoot, _ in
            _ = try (treeRoot.t as? JSONTree)?.editByPath([0, 2], [0, 2], JSONTreeTextNode(value: "cd"))
        }
        try crossSync(d1, d2)
        try d2.update { treeRoot, _ in
            _ = try (treeRoot.t as? JSONTree)?.editByPath([0, 0], [0, 0], JSONTreeTextNode(value: "XYZ"))
        }
        try crossSync(d1, d2)

        m1.isCapturingUndoRedo = true
        try d1.undo()
        m1.isCapturingUndoRedo = false
        try crossSync(d1, d2)

        // then
        XCTAssertEqual(try xmlOf(d1), "<doc><p>XYZab</p></doc>")
        XCTAssertEqual(try m1.xml(), try xmlOf(d1), "d1 after undo")
        XCTAssertEqual(try m2.xml(), try xmlOf(d2), "d2 after undo")
        XCTAssertEqual(m1.undoRedoInfos.map(\.fromPath), [[0, 5]])
        XCTAssertEqual(m1.undoRedoInfos.map(\.toPath), [[0, 7]])
    }

    // MARK: - Restored subtree

    /// Undoing the removal of a paragraph with content restores the parent
    /// element first, then its children -- two separate `TreeEditOpInfo`s, in
    /// that order, not one that names both in a single call.
    ///
    /// CONFIRMED IOS DIVERGENCE FROM JS: the underlying CRDT document
    /// converges correctly on both replicas either way (the `xmlOf(d2)`
    /// assertion below passes) -- only the REPORTED `TreeEditOpInfo` for the
    /// restored parent is wrong. See the root-cause trace on
    /// `test_reports_where_undo_and_redo_of_insert_element_landed`: the
    /// parent's op should carry `value: [{ type: 'p', children: [] }]` (its
    /// child is reported separately, right after), but iOS's deferred
    /// node-to-`JSONTreeNode` conversion lets the child's own revival leak
    /// into the parent's snapshot, so a consumer that replays every OpInfo
    /// literally (`TreeHistoryFollower`, below) ends up with "cdcd".
    @MainActor
    func test_reports_a_restored_subtree_parent_first_then_its_children() throws {
        // given
        let d1 = replicaWithHistoryActor(actorHistoryA)
        let d2 = replicaWithHistoryActor(actorHistoryB)
        let root = JSONTreeElementNode(type: "doc", children: [para("ab"), para("cd")])

        try d1.update { treeRoot, _ in treeRoot.t = JSONTree(initialRoot: root) }
        try crossSync(d1, d2)

        let m1 = try TreeHistoryFollower(d1, initial: root)
        let m2 = try TreeHistoryFollower(d2, initial: root)

        // when
        try d1.update { treeRoot, _ in _ = try (treeRoot.t as? JSONTree)?.editByPath([1], [2]) }
        try crossSync(d1, d2)

        m1.isCapturingUndoRedo = true
        try d1.undo()
        m1.isCapturingUndoRedo = false
        try crossSync(d1, d2)

        // then -- the real documents converge correctly; only the reported
        // OpInfo diverges from JS.
        XCTAssertEqual(try xmlOf(d2), "<doc><p>ab</p><p>cd</p></doc>")

        try XCTExpectFailure("""
        iOS bug: the restored parent <p>'s TreeEditOpInfo wrongly embeds the \
        already-revived "cd" text child a second time, so a consumer that \
        replays every OpInfo (as this mirror does) renders "cdcd" instead of \
        "cd" (CRDTTree.swift:3357-3372, TreeEditOperation.swift:579-594).
        """) {
            XCTAssertEqual(try m1.xml(), try xmlOf(d1))
            XCTAssertEqual(try m2.xml(), try xmlOf(d2))
            XCTAssertEqual(m1.undoRedoInfos.map(\.fromPath), [[1], [1, 0]])
            XCTAssertEqual(
                m1.undoRedoInfos.map { describe($0.value) },
                [
                    describe([JSONTreeElementNode(type: "p", children: [])]),
                    describe([JSONTreeTextNode(value: "cd")])
                ]
            )
        }
    }
}
