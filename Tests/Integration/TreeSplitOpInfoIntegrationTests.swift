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

// Ports: packages/sdk/test/integration/tree_split_opinfo_test.ts (yorkie-js-sdk#1455).
// Requires a running yorkie server at http://localhost:8080.

import XCTest
@testable @preconcurrency import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// The editor shape the bug was found in: alice keeps typing at the end of an inline element
/// while bob presses Enter there. Bob's Enter is a split of the inline element's text followed
/// by a split of the paragraph. Alice's concurrent text stays on the left of the split, so the
/// split alice is told about has to be after it.
final class TreeSplitOpInfoIntegrationTests: XCTestCase {
    private final class OpBox {
        var ops = [TreeEditOpInfo]()
    }

    @MainActor
    func test_reports_the_split_after_text_the_receiver_typed_at_the_boundary() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // given: <doc><p><t>가나다0123</t></p></doc> on both.
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "t", children: [JSONTreeTextNode(value: "가나다0123")])
                    ])
                ]))
            }
            try await c1.sync()
            try await c2.sync()

            // when: alice (d1) types "4", "5" at the end while bob (d2) presses Enter at the end,
            // the way the editor sends it.
            try d1.update { root, _ in
                _ = try (root.t as? JSONTree)?.editByPath([0, 0, 7], [0, 0, 7], JSONTreeTextNode(value: "4"))
            }
            try d1.update { root, _ in
                _ = try (root.t as? JSONTree)?.editByPath([0, 0, 8], [0, 0, 8], JSONTreeTextNode(value: "5"))
            }
            try d2.update { root, _ in
                let tree = root.t as? JSONTree
                _ = try tree?.editByPath([0, 0, 7], [0, 0, 7], nil, 1)
                try tree?.splitByPath([0, 1])
            }

            let box = OpBox()
            d1.subscribe { event, _ in
                guard let event = event as? RemoteChangeEvent else { return }
                for op in event.value.operations {
                    if let treeEdit = op as? TreeEditOpInfo {
                        box.ops.append(treeEdit)
                    }
                }
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then: alice's tree keeps "45" left of the split, and the split she is told about is
            // at offset 9, after it.
            let xml1 = (d1.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(xml1, (d2.getRoot().t as? JSONTree)?.toXML())
            XCTAssertEqual(xml1, "<doc><p><t>가나다012345</t></p><p><t></t></p></doc>")
            XCTAssertEqual(box.ops.map(\.fromPath), [[0, 0, 9], [0, 1]])
            XCTAssertEqual(box.ops.map(\.toPath), [[0, 0, 9], [0, 1]])
        }
    }
}
