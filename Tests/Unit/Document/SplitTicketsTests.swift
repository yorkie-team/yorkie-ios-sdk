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

/// Ported from yorkie-js-sdk v0.7.16:
/// `packages/sdk/test/unit/document/split_ticket_test.ts`
/// (yorkie-js-sdk#1319 "Stop undo and element splits from reusing a node's
/// identity").
///
/// The tickets an element split consumes are carried by the operation rather
/// than reconstructed from it: a reconstruction advancing by the number of
/// top-level contents cannot account for the ticket each descendant also
/// took.
final class SplitTicketsTests: XCTestCase {
    /// Returns the ids that name more than one node in the document's "t" tree.
    @MainActor
    private func duplicatedIDs(_ doc: Document) -> [String] {
        guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree else {
            return []
        }
        var counts = [String: Int]()
        tree.indexTree.traverseAll { node, _ in
            counts[node.toIDString, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { $0.key }
    }

    @MainActor
    func test_does_not_land_on_the_content_the_same_edit_inserts() throws {
        // given
        let doc = Document(key: "split-tickets-doc")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
            ]))
        }

        // when — two edits within the SAME change: an element split (issues a
        // split ticket), then an insert at a position the delimiter
        // simulation could otherwise collide with.
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "q"), 1)
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "z"), 0)
        }

        // then
        XCTAssertEqual(self.duplicatedIDs(doc), [])
    }

    @MainActor
    func test_survives_the_round_trip_to_the_wire() throws {
        // given
        let doc = Document(key: "split-tickets-wire-doc")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
            ]))
        }
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "q"), 1)
        }

        // when
        let pack = doc.createChangePack()
        let pbPack = Converter.toChangePack(pack: pack)
        let restored = try Converter.fromChangePack(pbPack)

        let sent = pack.getChanges()
            .flatMap { $0.operations }
            .compactMap { $0 as? TreeEditOperation }
            .flatMap { $0.getSplitTickets() }
        let received = restored.getChanges()
            .flatMap { $0.operations }
            .compactMap { $0 as? TreeEditOperation }
            .flatMap { $0.getSplitTickets() }

        // then
        XCTAssertFalse(sent.isEmpty, "the edit split an element, so it issued tickets")
        XCTAssertEqual(
            received.map { $0.toTestString },
            sent.map { $0.toTestString },
            "a replica reads back the tickets the originator issued"
        )
    }
}
