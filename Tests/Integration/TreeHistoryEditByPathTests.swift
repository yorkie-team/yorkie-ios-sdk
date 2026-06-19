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

// MARK: - Helpers

@MainActor
private func xmlOf(_ doc: Document) -> String {
    (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
}

// MARK: - 4. Single Client — editByPath split/merge undo/redo (PR #1237)

/// Ports: "Tree History - single client split/merge" tests renamed to
/// use `editByPath` variants from packages/sdk/test/integration/history_tree_split_test.ts
/// (added in PR #1239, confirmed updated in PR #1237).
///
/// PR #1237 renamed the split/merge undo/redo tests from `splitByPath`/`mergeByPath`
/// to `editByPath([…], […], undefined, 1)` / `editByPath([0, 2], [1, 0])`.
/// The underlying iOS `JSONTree.editByPath(_:_:_:_:)` call is identical; the key
/// fix is that undoing a cross-boundary merge regenerates a split (not raw content
/// re-insertion), and undoing a split-then-merge editByPath round-trip restores the
/// element boundaries correctly.

final class TreeHistoryEditByPathSplitMergeTests: XCTestCase {
    // Ports: "should undo editByPath split"
    @MainActor
    func test_can_undo_editByPath_split() throws {
        // given
        let doc = Document(key: "editbypath-split-undo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "ABCD")
                    ])
                ])
            )
        }

        let before = xmlOf(doc)
        XCTAssertEqual(before, "<doc><p>ABCD</p></doc>")

        // when — split at offset 2 between "AB" and "CD" via editByPath with splitLevel=1
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 2], [0, 2], nil, 1)
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>AB</p><p>CD</p></doc>")

        // then
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)
    }

    // Ports: "should redo editByPath split"
    @MainActor
    func test_can_redo_editByPath_split() throws {
        // given
        let doc = Document(key: "editbypath-split-redo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeTextNode(value: "ABCD")
                    ])
                ])
            )
        }

        let before = xmlOf(doc)
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 2], [0, 2], nil, 1)
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>AB</p><p>CD</p></doc>")

        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        // then
        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }

    // Ports: "should undo editByPath merge"
    //
    // The cross-boundary merge via editByPath([0, 2], [1, 0]) deletes the
    // </p><p> boundary. The undo must re-create those boundaries (split), not
    // re-insert the boundary tokens as raw content.
    @MainActor
    func test_can_undo_editByPath_merge() throws {
        // given
        let doc = Document(key: "editbypath-merge-undo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "CD")])
                ])
            )
        }

        let before = xmlOf(doc)
        XCTAssertEqual(before, "<doc><p>AB</p><p>CD</p></doc>")

        // when — merge second <p> into first via cross-boundary editByPath
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 2], [1, 0])
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>ABCD</p></doc>")

        // then — undo must re-split (not re-insert raw boundary content)
        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)
    }

    // Ports: "should redo editByPath merge"
    @MainActor
    func test_can_redo_editByPath_merge() throws {
        // given
        let doc = Document(key: "editbypath-merge-redo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "AB")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "CD")])
                ])
            )
        }

        let before = xmlOf(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 2], [1, 0])
        }
        let after = xmlOf(doc)
        XCTAssertEqual(after, "<doc><p>ABCD</p></doc>")

        try doc.undo()
        XCTAssertEqual(xmlOf(doc), before)

        // then
        try doc.redo()
        XCTAssertEqual(xmlOf(doc), after)
    }

    // Ports: "Can merge blocks using editByPath (wafflebase pattern)"
    //
    // Verifies a direct-merge editByPath call (not a split-then-merge roundtrip)
    // produces the correct XML, to establish the baseline for the split-then-merge
    // regression test below.
    @MainActor
    func test_can_merge_blocks_using_editByPath() throws {
        // given — reproduce wafflebase docs tree structure
        let doc = Document(key: "editbypath-merge-wafflebase")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "block", children: [
                        JSONTreeElementNode(type: "inline", children: [
                            JSONTreeTextNode(value: "as")
                        ])
                    ]),
                    JSONTreeElementNode(type: "block", children: [
                        JSONTreeElementNode(type: "inline", children: [
                            JSONTreeTextNode(value: "df")
                        ])
                    ])
                ])
            )
        }

        let initialXML = xmlOf(doc)
        XCTAssertEqual(initialXML,
                       "<doc><block><inline>as</inline></block><block><inline>df</inline></block></doc>")

        // when — wafflebase mergeBlock: editByPath([blockPath, inlineCount], [nextPath, 0])
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 1], [1, 0])
        }

        // then
        let mergedXML = xmlOf(doc)
        XCTAssertEqual(mergedXML,
                       "<doc><block><inline>as</inline><inline>df</inline></block></doc>")
    }

    // Ports: "Can split then merge blocks using editByPath (wafflebase backspace bug)"
    //
    // This is the primary regression test for PR #1237: after splitting a paragraph
    // via editByPath with splitLevel=2, the subsequent cross-boundary merge via
    // editByPath must succeed (not be a no-op) and produce the correct XML.
    @MainActor
    func test_split_then_merge_via_editByPath_roundtrip() throws {
        // given — single block with one inline
        let doc = Document(key: "editbypath-split-then-merge")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "block", children: [
                        JSONTreeElementNode(type: "inline", children: [
                            JSONTreeTextNode(value: "asdf")
                        ])
                    ])
                ])
            )
        }
        XCTAssertEqual(xmlOf(doc), "<doc><block><inline>asdf</inline></block></doc>")

        // when — split at offset 2 with splitLevel=2 (Enter key after "as")
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 0, 2], [0, 0, 2], nil, 2)
        }
        XCTAssertEqual(xmlOf(doc),
                       "<doc><block><inline>as</inline></block><block><inline>df</inline></block></doc>")

        // when — merge via backspace at start of second block
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 1], [1, 0])
        }

        // then — merge must NOT be a no-op
        let mergedXML = xmlOf(doc)
        XCTAssertEqual(mergedXML,
                       "<doc><block><inline>as</inline><inline>df</inline></block></doc>")
    }

    // Ports: "Can split then merge blocks using editByPath (wafflebase backspace bug)" — undo
    //
    // After the split-then-merge round-trip, undo must restore the two-block state.
    @MainActor
    func test_can_undo_split_then_merge_roundtrip() throws {
        // given — split-then-merge as above
        let doc = Document(key: "editbypath-split-merge-undo")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "block", children: [
                        JSONTreeElementNode(type: "inline", children: [
                            JSONTreeTextNode(value: "asdf")
                        ])
                    ])
                ])
            )
        }

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 0, 2], [0, 0, 2], nil, 2)
        }
        let afterSplit = xmlOf(doc)
        XCTAssertEqual(afterSplit,
                       "<doc><block><inline>as</inline></block><block><inline>df</inline></block></doc>")

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0, 1], [1, 0])
        }
        let afterMerge = xmlOf(doc)
        XCTAssertEqual(afterMerge,
                       "<doc><block><inline>as</inline><inline>df</inline></block></doc>")

        // when — undo the merge
        try doc.undo()

        // then — two-block state is restored
        XCTAssertEqual(xmlOf(doc), afterSplit)

        // and — redo re-applies the merge
        try doc.redo()
        XCTAssertEqual(xmlOf(doc), afterMerge)
    }
}

// MARK: - Multi-client editByPath split/merge convergence (PR #1237)

/// Integration tests that verify both clients converge after editByPath
/// split and merge operations with concurrent edits.
final class TreeHistoryEditByPathConvergenceTests: XCTestCase {
    // Ports: "Can sync editByPath split with other clients"
    @MainActor
    func test_can_sync_editByPath_split_with_other_clients() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — nested tree structure matching the JS test
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "tc", children: [
                            JSONTreeElementNode(type: "p", children: [
                                JSONTreeElementNode(type: "tn", children: [
                                    JSONTreeTextNode(value: "1234")
                                ])
                            ]),
                            JSONTreeElementNode(type: "p", children: [
                                JSONTreeElementNode(type: "tn", children: [
                                    JSONTreeTextNode(value: "5678")
                                ])
                            ])
                        ])
                    ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — d1 splits using editByPath with splitLevel=1
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.editByPath([0, 0, 0, 2], [0, 0, 0, 2], nil, 1)
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both documents converge
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — d1 splits at the second level
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — still converged
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }

    // Ports: "Can sync editByPath merge with other clients"
    @MainActor
    func test_can_sync_editByPath_merge_with_other_clients() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given — nested tree with two text-nodes in the same <p>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "tc", children: [
                            JSONTreeElementNode(type: "p", children: [
                                JSONTreeElementNode(type: "tn", children: [
                                    JSONTreeTextNode(value: "1234")
                                ]),
                                JSONTreeElementNode(type: "tn", children: [
                                    JSONTreeTextNode(value: "5678")
                                ])
                            ])
                        ])
                    ])
                )
            }

            try await c1.sync()
            try await c2.sync()

            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())

            // when — d1 merges using editByPath (cross-boundary merge of two <tn>s)
            try d1.update { root, _ in
                try (root.t as? JSONTree)?.editByPath([0, 0, 0, 4], [0, 0, 1, 0])
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both documents converge
            XCTAssertEqual(d1.toSortedJSON(), d2.toSortedJSON())
        }
    }
}
