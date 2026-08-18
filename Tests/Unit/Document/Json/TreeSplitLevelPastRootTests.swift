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

/// Ports: "Can edit with splitLevel walking past root without throwing" from
/// `packages/sdk/test/integration/tree_test.ts` at yorkie-js-sdk v0.7.13
/// (yorkie-js-sdk#1289 "Prevent panic when splitLevel walks past the tree
/// root").
///
/// `CRDTTree.applySplitLevel` walks up from the edit position, splitting one
/// ancestor per level. When `splitLevel` is deep enough that the walk reaches
/// the tree root, the old code called `parent.split(...)` *before* checking
/// whether `parent.parent` was nil, so splitting the root dereferenced its
/// nil parent. The fix moves the "no parent left to walk to" guard before the
/// split call. This test exercises every insertion position in a handful of
/// shallow trees with `splitLevel` 1 and 2 (levels than can plausibly reach or
/// exceed the root) and asserts the edit both completes without throwing and
/// actually inserts the requested content.
final class TreeSplitLevelPastRootTests: XCTestCase {
    private struct Seed {
        let name: String
        let tree: JSONTreeElementNode
        let length: Int
    }

    @MainActor
    func test_can_edit_with_splitLevel_walking_past_root_without_throwing() throws {
        // given — a handful of shallow trees whose root can be reached (or
        // walked past) by a splitLevel of 1 or 2 from any insertion position.
        let seeds: [Seed] = [
            // <doc><p>x</p></doc>
            Seed(
                name: "shallow",
                tree: JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "x")])
                ]),
                length: 3
            ),
            // <doc><p>x</p><p>y</p></doc>
            Seed(
                name: "twoP",
                tree: JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "x")]),
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "y")])
                ]),
                length: 6
            ),
            // <doc><p><b>x</b></p></doc>
            Seed(
                name: "deep",
                tree: JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "b", children: [JSONTreeTextNode(value: "x")])
                    ])
                ]),
                length: 5
            ),
            // <doc><p></p></doc>
            Seed(
                name: "emptyP",
                tree: JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [])
                ]),
                length: 2
            )
        ]

        for seed in seeds {
            for pos in 0 ... seed.length {
                for splitLevel: Int32 in [1, 2] {
                    let label = "\(seed.name) pos=\(pos) sl=\(splitLevel)"

                    // given — a fresh document per (seed, pos, splitLevel) combination,
                    // matching the JS test's isolation-per-step.
                    let doc = Document(key: "split-level-past-root-\(seed.name)-\(pos)-\(splitLevel)")
                    try doc.update { root, _ in
                        root.t = JSONTree(initialRoot: seed.tree)
                    }

                    let sizeBefore = try (doc.getRoot().t as? JSONTree)?.getSize() ?? 0

                    // when — insert "a" at every position with a splitLevel deep
                    // enough to walk up to (or past) the tree root.
                    XCTAssertNoThrow(
                        try doc.update { root, _ in
                            _ = try (root.t as? JSONTree)?.edit(pos, pos, JSONTreeTextNode(value: "a"), splitLevel)
                        },
                        label
                    )

                    // then — the edit must not just avoid throwing, it must produce a
                    // valid tree that actually contains the inserted text.
                    let tree = doc.getRoot().t as? JSONTree
                    let sizeAfter = try tree?.getSize() ?? 0
                    XCTAssertGreaterThan(sizeAfter, sizeBefore, label)
                    XCTAssertTrue((tree?.toXML() ?? "").contains("a"), label)
                }
            }
        }
    }
}
