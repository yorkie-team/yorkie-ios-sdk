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

/// Ports `packages/sdk/test/unit/api/array_move_snapshot_test.ts` from
/// yorkie-js-sdk v0.7.18 as a PARITY/REGRESSION test — this is a proof that
/// iOS does NOT exhibit yorkie-js-sdk#1332 "Anchor RGATreeList.insert on
/// position identity", not a repro of a live bug.
///
/// Regression for yorkie#1948 upstream: when the last element of an array was
/// moved into its slot, appending more elements and then restoring the array
/// from a snapshot must preserve order.
///
/// The JS `RGATreeList.insert` anchored on the last node's ELEMENT createdAt
/// instead of its POSITION createdAt. For a moved last element those differ,
/// and the element createdAt resolved to the element's now-dead original
/// position node, so each appended element landed before the previous one —
/// reversing the appended run. `fromArray` was the only caller of `insert`, so
/// this surfaced solely as a replica diverging after a snapshot restore.
///
/// On iOS, `RGATreeList.insert(_ value:)` already anchors on
/// `self.last.positionCreatedAt` (position identity), so this scenario must
/// converge across a snapshot round trip.
final class ArrayMoveSnapshotTests: XCTestCase {
    @MainActor
    func test_preserves_order_of_a_moved_then_appended_array_across_a_snapshot() throws {
        // given
        let doc = Document(key: "test-doc")

        try doc.update { root, _ in
            root.list = [Int32(14), Int32(15)]
        }
        XCTAssertEqual(doc.toJSON(), "{\"list\":[14,15]}")

        // Two moves that leave two dead position nodes and a moved last element,
        // while restoring the original [14,15] order.
        try doc.update { root, _ in
            guard let array = root.list as? JSONArray,
                  let n14 = array.getElement(byIndex: 0) as? Primitive,
                  let n15 = array.getElement(byIndex: 1) as? Primitive
            else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }
            try? array.moveAfter(previousID: n15.createdAt, id: n14.createdAt)
        }
        XCTAssertEqual(doc.toJSON(), "{\"list\":[15,14]}")

        try doc.update { root, _ in
            guard let array = root.list as? JSONArray,
                  let n15 = array.getElement(byIndex: 0) as? Primitive,
                  let n14 = array.getElement(byIndex: 1) as? Primitive
            else {
                XCTFail("getElement(byIndex:) is nil.")
                return
            }
            try? array.moveAfter(previousID: n14.createdAt, id: n15.createdAt)
        }
        XCTAssertEqual(doc.toJSON(), "{\"list\":[14,15]}")

        // when — append after the moved last element
        try doc.update { root, _ in
            guard let array = root.list as? JSONArray else {
                XCTFail("root.list is not a JSONArray.")
                return
            }
            _ = array.push(Int32(26))
            _ = array.push(Int32(66))
        }
        XCTAssertEqual(doc.toJSON(), "{\"list\":[14,15,26,66]}")

        // then — the snapshot restore path rebuilds the list through `insert`.
        let bytes = try Converter.objectToBytes(obj: doc.getRootObject())
        let restored = try Converter.bytesToObject(bytes: bytes)
        XCTAssertEqual(
            restored.toSortedJSON(),
            doc.getRootObject().toSortedJSON(),
            "snapshot restore of a moved-then-appended array must preserve order"
        )
    }
}
