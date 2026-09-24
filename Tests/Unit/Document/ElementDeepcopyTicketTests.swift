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

/// A deepcopy has to carry `movedAt` and `removedAt` across, as `object.ts`, `array.ts`,
/// `text.ts` and `tree.ts` all do.
///
/// `movedAt` became load-bearing in v0.7.22: `ElementRHT.set` stamps it and LWW resolves on
/// `getPositionedAt()`. A copy that drops it reports `positionedAt == createdAt`, so after a
/// clone reset a concurrent remote `set` can win on the clone and lose on the root. Both
/// tickets are also charged to the element's meta size, so dropping either makes the copy
/// measure smaller than its source.
final class ElementDeepcopyTicketTests: XCTestCase {
    private let moved = TimeTicket(lamport: 7, delimiter: 0, actorID: "000000000000000000000001")
    private let removed = TimeTicket(lamport: 9, delimiter: 0, actorID: "000000000000000000000001")

    private func assertTicketsSurvive(_ element: CRDTElement, _ label: String) {
        element.setMovedAt(self.moved)
        element.remove(self.removed)
        let copy = element.deepcopy()

        XCTAssertEqual(copy.movedAt, self.moved, "\(label): the copy dropped movedAt, so it resolves LWW differently")
        XCTAssertEqual(copy.removedAt, self.removed, "\(label): the copy dropped removedAt")
        XCTAssertEqual(copy.getDataSize(), element.getDataSize(), "\(label): the copy measures differently")
    }

    func test_a_copied_text_keeps_its_position_and_removal_tickets() {
        let createdAt = TimeTicket(lamport: 1, delimiter: 0, actorID: "000000000000000000000001")
        self.assertTicketsSurvive(CRDTText(rgaTreeSplit: RGATreeSplit<CRDTTextValue>(), createdAt: createdAt), "text")
    }

    func test_a_copied_tree_keeps_its_position_and_removal_tickets() {
        let createdAt = TimeTicket(lamport: 1, delimiter: 0, actorID: "000000000000000000000001")
        let root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: createdAt, offset: 0), type: "doc")
        self.assertTicketsSurvive(CRDTTree(root: root, createdAt: createdAt), "tree")
    }

    func test_a_copied_object_keeps_its_position_and_removal_tickets() {
        let createdAt = TimeTicket(lamport: 1, delimiter: 0, actorID: "000000000000000000000001")
        self.assertTicketsSurvive(CRDTObject(createdAt: createdAt), "object")
    }

    func test_a_copied_array_keeps_its_position_and_removal_tickets() {
        let createdAt = TimeTicket(lamport: 1, delimiter: 0, actorID: "000000000000000000000001")
        self.assertTicketsSurvive(CRDTArray(createdAt: createdAt), "array")
    }
}
