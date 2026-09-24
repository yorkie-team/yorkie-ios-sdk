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

/// A move abandons the element's old position node. `MoveOperation` registers it as a GC pair
/// against the root; the proxy has to register it against the clone, or the two disagree on
/// `docSize` -- and the clone's is what ``Document/update(_:_:)`` measures against
/// `maxSizeLimit`.
///
/// All four public move entry points are covered because only one of them was fixed the first
/// time: they route through one helper now, and this is what stops them drifting apart again.
final class ArrayMoveCloneParityTests: XCTestCase {
    @MainActor
    func test_every_move_keeps_the_clone_in_step_with_the_root() throws {
        for name in ["after", "before", "front", "last"] {
            // given
            let doc = Document(key: "array-move-\(name)")
            try doc.update { root, _ in root.arr = [0, 1, 2] }
            let crdt = try XCTUnwrap(doc.getRootObject().get(key: "arr") as? CRDTArray)
            let ids = crdt.map { $0.createdAt }

            // when
            try doc.update { root, _ in
                guard let arr = root.arr as? JSONArray else { return }
                switch name {
                case "after": try arr.moveAfter(previousID: ids[2], id: ids[0])
                case "before": try arr.moveBefore(nextID: ids[0], id: ids[2])
                case "front": try arr.moveFront(id: ids[2])
                default: try arr.moveLast(id: ids[0])
                }
            }

            // then
            XCTAssertEqual(doc.cloned.root.getDocSize(), doc.getDocSize(),
                           "\(name): the clone and the root disagree on docSize after the move")
            XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON(), name)
        }
    }
}
