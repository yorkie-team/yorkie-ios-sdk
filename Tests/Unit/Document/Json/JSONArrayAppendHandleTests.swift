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

/// `JSONArray` used to insert a deep copy of an appended Text, Counter or Tree but push the
/// ORIGINAL element, which the user's handle is bound to, as the operation payload. Edits made
/// through the handle in the same update then also landed in the payload: the replica built the
/// element from the already-edited payload and replayed the edit on top of it. The handle must be
/// bound to the element that is inserted, and the operation must carry a copy (as
/// `JSONObject.set` does and as yorkie-js-sdk's `ArrayProxy.insertAfterInternal` does).
final class JSONArrayAppendHandleTests: XCTestCase {
    /// Ships `origin`'s pending changes through the wire converter into a fresh replica.
    @MainActor
    private func replica(of origin: Document, key: String) throws -> Document {
        let pack = origin.createChangePack()
        let shipped = try Converter.fromChanges(Converter.toChanges(pack.getChanges()))

        let peer = Document(key: key)
        peer.setActor("000000000000000000000002")
        try peer.applyChanges(shipped, source: .remote)
        return peer
    }

    @MainActor
    private func origin(key: String) -> Document {
        let doc = Document(key: key)
        doc.setActor("000000000000000000000001")
        return doc
    }

    @MainActor
    func test_an_appended_text_edited_through_its_handle_is_not_applied_twice() throws {
        // given
        let key = "append-text-handle"
        let doc = self.origin(key: key)

        // when
        try doc.update { root, _ in
            root.arr = [Any]()
            let text = JSONText()
            (root.arr as? JSONArray)?.append(text)
            text.edit(0, 0, "abc")
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[[{\"val\":\"abc\"}]]}")
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON())
        let peer = try self.replica(of: doc, key: key)
        XCTAssertEqual(peer.toSortedJSON(), doc.toSortedJSON())
    }

    @MainActor
    func test_an_appended_int32_counter_increased_through_its_handle_counts_once() throws {
        // given
        let key = "append-counter32-handle"
        let doc = self.origin(key: key)

        // when
        try doc.update { root, _ in
            root.arr = [Any]()
            let counter = JSONCounter(value: Int32(1))
            (root.arr as? JSONArray)?.append(counter)
            counter.increase(value: 5)
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[6]}")
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON())
        let peer = try self.replica(of: doc, key: key)
        XCTAssertEqual(peer.toSortedJSON(), "{\"arr\":[6]}")
    }

    @MainActor
    func test_an_appended_int64_counter_increased_through_its_handle_counts_once() throws {
        // given
        let key = "append-counter64-handle"
        let doc = self.origin(key: key)

        // when
        try doc.update { root, _ in
            root.arr = [Any]()
            let counter = JSONCounter(value: Int64(1))
            (root.arr as? JSONArray)?.append(counter)
            counter.increase(value: 5)
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[6]}")
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON())
        let peer = try self.replica(of: doc, key: key)
        XCTAssertEqual(peer.toSortedJSON(), "{\"arr\":[6]}")
    }

    @MainActor
    func test_an_appended_dedup_counter_added_through_its_handle_counts_once() throws {
        // given
        let key = "append-dedup-handle"
        let doc = self.origin(key: key)

        // when
        try doc.update { root, _ in
            root.arr = [Any]()
            let counter = JSONDedupCounter()
            (root.arr as? JSONArray)?.append(counter)
            try counter.add("actor-1")
            try counter.add("actor-2")
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[2]}")
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON())
        let peer = try self.replica(of: doc, key: key)
        XCTAssertEqual(peer.toSortedJSON(), doc.toSortedJSON())
    }

    @MainActor
    func test_an_appended_tree_edited_through_its_handle_is_not_applied_twice() throws {
        // given
        let key = "append-tree-handle"
        let doc = self.origin(key: key)

        // when
        try doc.update { root, _ in
            root.arr = [Any]()
            let tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
            ]))
            (root.arr as? JSONArray)?.append(tree)
            _ = try tree.edit(1, 1, JSONTreeTextNode(value: "X"))
        }

        // then
        let local = try XCTUnwrap(((doc.getRoot().arr as? JSONArray)?[0]) as? JSONTree)
        XCTAssertEqual(local.toXML(), "<doc><p>Xab</p></doc>")
        let peer = try self.replica(of: doc, key: key)
        let remote = try XCTUnwrap(((peer.getRoot().arr as? JSONArray)?[0]) as? JSONTree)
        XCTAssertEqual(remote.toXML(), "<doc><p>Xab</p></doc>")
        XCTAssertEqual(peer.toSortedJSON(), doc.toSortedJSON())
    }
}
