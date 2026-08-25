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

//
// Ports: packages/sdk/test/integration/history_tree_concurrent_test.ts
// ("Tree History - concurrent overlapping undo after GC", added in
// yorkie-js-sdk#1315).
//
// Convergence of concurrent OVERLAPPING undo/redo once the deleted nodes have
// been GC-purged (so `restore` takes the recreate path). The existing
// `TreeHistoryIntegrationTests` reconcile cases undo before GC runs and so never
// exercise this; these settle enough rounds to let GC purge the tombstones
// first. Regression for the multi-user tree undo corruption seen in wafflebase
// docs: split-aware restore/retombstone that isolates each piece at the span
// boundaries so all replicas converge on the same text-node segmentation.
//

// MARK: - Helpers

/// `settle` runs several push/pull rounds on both clients so their changes are
/// fully exchanged and each replica's min-synced version vector advances far
/// enough for GC to purge the tombstones. Two `settle` calls back to back are
/// used before an undo to guarantee the deleted nodes are actually purged, so
/// `restore` exercises the recreate path.
@MainActor
private func settle(_ c1: Client, _ c2: Client) async throws {
    for _ in 0 ..< 3 {
        try await c1.sync()
        try await c2.sync()
    }
}

/// `initFlat` seeds `doc` with `<doc><p>0123456789</p></doc>`.
@MainActor
private func initFlat(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeTextNode(value: "0123456789")
                ])
            ])
        )
    }
}

/// Returns the XML of the `t` field in the document root.
///
/// Unwraps rather than defaulting to `""`: a broken document model would
/// otherwise let every comparison pass vacuously as `"" == ""`.
@MainActor
private func flatXML(_ doc: Document) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree, "root.t is not a JSONTree").toXML()
}

/// Asserts the two replicas converged, reporting both trees when they have not.
@MainActor
private func assertConverged(_ d1: Document, _ d2: Document, _ label: String) throws {
    let x1 = try flatXML(d1)
    let x2 = try flatXML(d2)
    XCTAssertEqual(d1.toSortedJSON(),
                   d2.toSortedJSON(),
                   "\(label) DIVERGED\n  d1=\(x1)\n  d2=\(x2)")
}

/// One undo range on `d1` versus one on `d2`, covering every overlap
/// relationship between the two deletes.
private struct OverlapCase {
    let name: String
    let r1: (Int, Int)
    let r2: (Int, Int)
}

private let overlapCases: [OverlapCase] = [
    OverlapCase(name: "contained_by", r1: (5, 7), r2: (3, 9)),
    OverlapCase(name: "contains", r1: (3, 9), r2: (5, 7)),
    OverlapCase(name: "overlap_start", r1: (5, 9), r2: (3, 7)),
    OverlapCase(name: "overlap_end", r1: (3, 7), r2: (5, 9)),
    OverlapCase(name: "identical", r1: (3, 7), r2: (3, 7)),
    OverlapCase(name: "adjacent", r1: (3, 5), r2: (5, 7))
]

// MARK: - Tests

final class TreeHistoryConcurrentUndoAfterGCTests: XCTestCase {
    // MARK: - converges on undo of overlapping deletes

    // Ports: "converges on undo of overlapping deletes: contained_by"
    @MainActor
    func test_converges_on_undo_of_overlapping_deletes_contained_by() async throws {
        try await self.runUndoCase("contained_by")
    }

    // Ports: "converges on undo of overlapping deletes: contains"
    @MainActor
    func test_converges_on_undo_of_overlapping_deletes_contains() async throws {
        try await self.runUndoCase("contains")
    }

    // Ports: "converges on undo of overlapping deletes: overlap_start"
    @MainActor
    func test_converges_on_undo_of_overlapping_deletes_overlap_start() async throws {
        try await self.runUndoCase("overlap_start")
    }

    // Ports: "converges on undo of overlapping deletes: overlap_end"
    @MainActor
    func test_converges_on_undo_of_overlapping_deletes_overlap_end() async throws {
        try await self.runUndoCase("overlap_end")
    }

    // Ports: "converges on undo of overlapping deletes: identical"
    @MainActor
    func test_converges_on_undo_of_overlapping_deletes_identical() async throws {
        try await self.runUndoCase("identical")
    }

    // Ports: "converges on undo of overlapping deletes: adjacent"
    @MainActor
    func test_converges_on_undo_of_overlapping_deletes_adjacent() async throws {
        try await self.runUndoCase("adjacent")
    }

    // MARK: - converges on undo+redo of overlapping deletes

    // Ports: "converges on undo+redo of overlapping deletes: contained_by"
    @MainActor
    func test_converges_on_undo_redo_of_overlapping_deletes_contained_by() async throws {
        try await self.runUndoRedoCase("contained_by")
    }

    // Ports: "converges on undo+redo of overlapping deletes: contains"
    @MainActor
    func test_converges_on_undo_redo_of_overlapping_deletes_contains() async throws {
        try await self.runUndoRedoCase("contains")
    }

    // Ports: "converges on undo+redo of overlapping deletes: overlap_start"
    @MainActor
    func test_converges_on_undo_redo_of_overlapping_deletes_overlap_start() async throws {
        try await self.runUndoRedoCase("overlap_start")
    }

    // Ports: "converges on undo+redo of overlapping deletes: overlap_end"
    @MainActor
    func test_converges_on_undo_redo_of_overlapping_deletes_overlap_end() async throws {
        try await self.runUndoRedoCase("overlap_end")
    }

    // Ports: "converges on undo+redo of overlapping deletes: identical"
    @MainActor
    func test_converges_on_undo_redo_of_overlapping_deletes_identical() async throws {
        try await self.runUndoRedoCase("identical")
    }

    // Ports: "converges on undo+redo of overlapping deletes: adjacent"
    @MainActor
    func test_converges_on_undo_redo_of_overlapping_deletes_adjacent() async throws {
        try await self.runUndoRedoCase("adjacent")
    }

    // MARK: - Known limitations (skipped, mirroring JS `it.skip`)

    // Ports: "KNOWN: delete a whole <p> vs edit text inside it, both undo"
    //
    // When a whole element is deleted concurrently with a text edit INSIDE it and
    // both undo AFTER GC, the visible content converges but internal text-node
    // segmentation can differ (one replica un-tombstones the concurrent edit's
    // finer split, the other recreates the run monolithically from the element's
    // span) so `toSortedJSON` mismatches. Removing restore's straddle-break
    // (needed to fix the overlapping text-delete cases above) removed the
    // coincidental coarsening that made these converge. A sound fix needs the
    // child sub-restore's split points to survive a transiently-purged parent
    // (e.g. undo-stack-aware GC so restore un-tombstones in place).
    // Merge-normalizing segmentation was tried and rejected upstream
    // (non-commutative — broke GC/tombstone symmetry after redo).
    @MainActor
    func test_known_delete_whole_element_vs_edit_inside_both_undo() async throws {
        // `XCTSkipIf(true, …)` rather than a bare `throw`: the body below stays
        // compiled (so it cannot rot) and re-enabling is a one-line deletion,
        // matching how upstream keeps the scenario under `it.skip`.
        try XCTSkipIf(true, "KNOWN: element-delete vs inner text edit diverges on segmentation after GC — mirrors JS it.skip")

        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "hello")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "world")])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // d1 removes the whole first <p>; d2 replaces text inside it.
            try d1.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(0, 7)
            }
            try d2.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(3, 5, JSONTreeTextNode(value: "XY"))
            }
            try await settle(c1, c2)
            try assertConverged(d1, d2, "after ops")

            try d1.undo()
            try d2.undo()
            try await settle(c1, c2)
            try assertConverged(d1, d2, "after undo")
        }
    }

    // Ports: "KNOWN: delete two <p> vs edit inside first, both undo (segmentation)"
    //
    // Deleting MULTIPLE elements concurrently with an edit inside one of them,
    // then both undo after GC, converges on visible content but NOT on internal
    // text-node segmentation (d1: "a","aa","a"; d2: "aaaa") — so `toSortedJSON`
    // differs. Root cause: a child sub-restore is B1-skipped while its parent is
    // transiently purged, so the two replicas end with different split points;
    // the element-restore's span is monolithic and cannot re-introduce them.
    // Left skipped until undo-stack-aware GC lands.
    @MainActor
    func test_known_delete_two_elements_vs_edit_inside_first_both_undo() async throws {
        try XCTSkipIf(true, "KNOWN: multi-element delete vs inner text edit diverges on segmentation after GC — mirrors JS it.skip")

        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "aaaa")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "bbbb")]),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cccc")])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            try d1.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(0, 12)
            }
            try d2.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(2, 4, JSONTreeTextNode(value: "XY"))
            }
            try await settle(c1, c2)
            try await settle(c1, c2)

            try d1.undo()
            try d2.undo()
            try await settle(c1, c2)
            try assertConverged(d1, d2, "after undo")
        }
    }

    // MARK: - Shared runners

    /// Both undos revive both deleted runs by identity, restoring the pre-delete
    /// visible content on both replicas. (The internal text-node segmentation may
    /// be finer than the original — isolate splits at the span boundaries — but
    /// both replicas agree, which `assertConverged` checks.)
    @MainActor
    private func runUndoCase(_ name: String) async throws {
        let tc = try XCTUnwrap(overlapCases.first { $0.name == name })

        try await withTwoClientsAndDocuments("\(self.description)-\(name)") { c1, d1, c2, d2 in
            // given — a flat tree shared by both replicas
            try initFlat(d1)
            try await c1.sync()
            try await c2.sync()
            let initial = try flatXML(d1)

            // when — concurrent overlapping deletes, settled twice so GC purges
            try d1.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(tc.r1.0, tc.r1.1)
            }
            try d2.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(tc.r2.0, tc.r2.1)
            }
            try await settle(c1, c2)
            try await settle(c1, c2)
            try assertConverged(d1, d2, "after deletes")

            // when — both replicas undo their own delete
            try d1.undo()
            try d2.undo()
            try await settle(c1, c2)

            // then
            try assertConverged(d1, d2, "after undo")
            XCTAssertEqual(try flatXML(d1), initial, "undo restores the initial visible content")
        }
    }

    /// Both redos re-remove both runs by identity, back to the converged
    /// post-delete state.
    @MainActor
    private func runUndoRedoCase(_ name: String) async throws {
        let tc = try XCTUnwrap(overlapCases.first { $0.name == name })

        try await withTwoClientsAndDocuments("\(self.description)-\(name)") { c1, d1, c2, d2 in
            // given — a flat tree shared by both replicas
            try initFlat(d1)
            try await c1.sync()
            try await c2.sync()
            let initial = try flatXML(d1)

            // when — concurrent overlapping deletes, settled twice so GC purges
            try d1.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(tc.r1.0, tc.r1.1)
            }
            try d2.update { root, _ in
                try XCTUnwrap(root.t as? JSONTree).edit(tc.r2.0, tc.r2.1)
            }
            try await settle(c1, c2)
            try await settle(c1, c2)
            let afterDeletes = try flatXML(d1)

            // when — both undo
            try d1.undo()
            try d2.undo()
            try await settle(c1, c2)

            // then
            try assertConverged(d1, d2, "after undo")
            XCTAssertEqual(try flatXML(d1), initial, "undo restores the initial visible content")

            // when — both redo
            try d1.redo()
            try d2.redo()
            try await settle(c1, c2)

            // then
            try assertConverged(d1, d2, "after redo")
            XCTAssertEqual(try flatXML(d1), afterDeletes, "redo restores the post-delete visible content")
        }
    }
}
