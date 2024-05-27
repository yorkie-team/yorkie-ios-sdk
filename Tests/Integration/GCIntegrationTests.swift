/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

class GCTests: XCTestCase {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    func test_getGarbageLength_should_return_the_actual_number_of_elements_garbage_collected() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        // 1. initial state
        try await client1.attach(doc1, [:], .manual)

        try await doc1.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }

        try await client1.sync()
        try await client2.attach(doc2, [:], .manual)

        // 2. client1 updates doc
        try await doc1.update { root, _ in
            root.remove(key: "point")
        }

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)

        // 3. client2 updates doc
        try await doc2.update { root, _ in
            (root.point as? JSONObject)?.remove(key: "x")
        }

        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 1) // x

        try await client1.sync()
        try await client2.sync()
        try await client1.sync()

        let gcNodeLen = 3 // point x, y
        var doc1Len = await doc1.getGarbageLength()
        var doc2Len = await doc2.getGarbageLength()
        XCTAssertEqual(doc1Len, gcNodeLen)
        XCTAssertEqual(doc2Len, gcNodeLen)

        // Actual garbage-collected nodes
        doc1Len = await doc1.garbageCollect(TimeTicket.max)
        doc2Len = await doc2.garbageCollect(TimeTicket.max)

        XCTAssertEqual(doc1Len, gcNodeLen)
        XCTAssertEqual(doc2Len, gcNodeLen)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_can_handle_tree_garbage_collection_for_multi_client() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)

        try await doc1.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "doc",
                                    children: [
                                        JSONTreeElementNode(type: "p",
                                                            children: [
                                                                JSONTreeElementNode(type: "tn",
                                                                                    children: [
                                                                                        JSONTreeTextNode(value: "a"),
                                                                                        JSONTreeTextNode(value: "b")
                                                                                    ]),
                                                                JSONTreeElementNode(type: "tn",
                                                                                    children: [
                                                                                        JSONTreeTextNode(value: "cd")
                                                                                    ])
                                                            ])
                                    ])
            )
        }

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        // (0, 0) -> (1, 0): syncedseqs:(0, 0)
        try await client1.sync()

        // (1, 0) -> (1, 1): syncedseqs:(0, 0)
        try await client2.sync()

        try await doc2.update({ root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], JSONTreeTextNode(value: "gh"))
            } catch {
                assertionFailure("Can't editByPath")
            }
        }, "removes 2")

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        // (1, 1) -> (1, 2): syncedseqs:(0, 1)
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        // (1, 2) -> (2, 2): syncedseqs:(1, 1)
        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        // (2, 2) -> (2, 2): syncedseqs:(1, 2)
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        // (2, 2) -> (2, 2): syncedseqs:(2, 2): meet GC condition
        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        // (2, 2) -> (2, 2): syncedseqs:(2, 2): meet GC condition
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.detach(doc1)
        try await client2.detach(doc2)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_can_handle_garbage_collection_for_container_type() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)

        try await doc1.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
        }, "set 1, 2,3")

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        // (0, 0) -> (1, 0): syncedseqs:(0, 0)
        try await client1.sync()

        // (1, 0) -> (1, 1): syncedseqs:(0, 0)
        try await client2.sync()

        try await doc2.update({ root, _ in
            root.remove(key: "2")
        }, "removes 2")

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        // (1, 1) -> (1, 2): syncedseqs:(0, 1)
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        // (1, 2) -> (2, 2): syncedseqs:(1, 1)
        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        // (2, 2) -> (2, 2): syncedseqs:(1, 2)
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        // (2, 2) -> (2, 2): syncedseqs:(2, 2): meet GC condition
        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        // (2, 2) -> (2, 2): syncedseqs:(2, 2): meet GC condition
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.detach(doc1)
        try await client2.detach(doc2)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_can_handle_garbage_collection_for_text_type() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)

        try await doc1.update({ root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "Hello World")
            root.textWithAttr = JSONText()
            (root.textWithAttr as? JSONText)?.edit(0, 0, "Hello World")
        }, "sets text")

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        // (0, 0) -> (1, 0): syncedseqs:(0, 0)
        try await client1.sync()

        // (1, 0) -> (1, 1): syncedseqs:(0, 0)
        try await client2.sync()

        try await doc2.update({ root, _ in
            (root.text as? JSONText)?.edit(0, 1, "a")
            (root.text as? JSONText)?.edit(1, 2, "b")
            (root.textWithAttr as? JSONText)?.edit(0, 1, "a", ["b": "1"])

        }, "edit text type elements")

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        // (1, 1) -> (1, 2): syncedseqs:(0, 1)
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        // (1, 2) -> (2, 2): syncedseqs:(1, 1)
        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        // (2, 2) -> (2, 2): syncedseqs:(1, 2)
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        // (2, 2) -> (2, 2): syncedseqs:(2, 2): meet GC condition
        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        // (2, 2) -> (2, 2): syncedseqs:(2, 2): meet GC condition
        try await client2.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.detach(doc1)
        try await client2.detach(doc2)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_can_handle_garbage_collection_with_detached_document_test() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)

        try await doc1.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
            root["4"] = JSONText()
            (root["4"] as? JSONText)?.edit(0, 0, "hi")
            root["5"] = JSONText()
            (root["5"] as? JSONText)?.edit(0, 0, "hi")
        }, "sets 1, 2, 3, 4, 5")

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        // (0, 0) -> (1, 0): syncedseqs:(0, 0)
        try await client1.sync()

        // (1, 0) -> (1, 1): syncedseqs:(0, 0)
        try await client2.sync()

        try await doc1.update({ root, _ in
            root.remove(key: "2")
            (root["4"] as? JSONText)?.edit(0, 1, "h")
            (root["5"] as? JSONText)?.edit(0, 1, "h", ["b": "1"])
        }, "removes 2 and edit text type elements")

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        // (1, 1) -> (2, 1): syncedseqs:(1, 0)
        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client2.detach(doc2)

        // (2, 1) -> (2, 2): syncedseqs:(1, x)
        try await client2.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 6)

        // (2, 2) -> (2, 2): syncedseqs:(2, x): meet GC condition
        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 6)

        try await client1.detach(doc1)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_can_collect_removed_elements_from_both_root_and_clone() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc = Document(key: docKey)

        let client = Client(rpcAddress)

        try await client.activate()

        try await client.attach(doc, [:], .manual)

        try await doc.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }

        try await doc.update { root, _ in
            root.point = ["x": Int64(1), "y": Int64(1)]
        }

        try await doc.update { root, _ in
            root.point = ["x": Int64(2), "y": Int64(2)]
        }

        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc.getGarbageLengthFromClone()
        XCTAssertEqual(len, 6)
    }

    func test_can_purges_removed_elements_after_peers_can_not_access_them() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)

        try await doc1.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }

        try await doc1.update { root, _ in
            (root.point as? JSONObject)?.x = Int64(1)
        }

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await client1.sync()

        try await client2.attach(doc2, [:], .manual)

        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc2.update { root, _ in
            (root.point as? JSONObject)?.x = Int64(2)
        }

        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await doc1.update { root, _ in
            root.point = ["x": Int64(3), "y": Int64(3)]
        }

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)
        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client2.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)
        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 5)
        try await client2.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 5)
        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_should_work_properly_when_there_are_multiple_nodes_to_be_collected_in_text_type() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)

        try await doc1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "z")
        }
        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(0, 1, "a")
        }
        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(1, 1, "b")
        }
        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(2, 2, "d")
        }

        try await client1.sync()
        try await client2.sync()

        var strDoc1 = await(doc1.getRoot().t as? JSONText)?.toString
        var strDoc2 = await(doc2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc1, "abd")
        XCTAssertEqual(strDoc2, "abd")
        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }

        try await client1.sync()
        try await client2.sync()
        try await client2.sync()
        strDoc1 = await(doc1.getRoot().t as? JSONText)?.toString
        strDoc2 = await(doc2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc1, "abcd")
        XCTAssertEqual(strDoc2, "abcd")

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }

        try await client1.sync()
        strDoc1 = await(doc1.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc1, "ad")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2) // b,c

        try await client2.sync()
        try await client2.sync()
        try await client1.sync()
        strDoc2 = await(doc2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc2, "ad")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_should_work_properly_when_there_are_multiple_nodes_to_be_collected_in_tree_type() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)

        try await doc1.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "r",
                                    children: [
                                        JSONTreeTextNode(value: "z")
                                    ])
            )
        }
        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0], [1], JSONTreeTextNode(value: "a"))
        }
        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([1], [1], JSONTreeTextNode(value: "b"))
        }
        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([2], [2], JSONTreeTextNode(value: "d"))
        }
        try await client1.sync()
        try await client2.sync()
        var strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        var strDoc2 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>abd</r>")
        XCTAssertEqual(strDoc2, "<r>abd</r>")
        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([2], [2], JSONTreeTextNode(value: "c"))
        }
        try await client1.sync()
        try await client2.sync()
        try await client2.sync()
        strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        strDoc2 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>abcd</r>")
        XCTAssertEqual(strDoc2, "<r>abcd</r>")

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([1], [3])
        }
        try await client1.sync()
        strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>ad</r>")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2) // b, c

        try await client2.sync()
        try await client2.sync()
        try await client1.sync()
        strDoc1 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>ad</r>")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }
}
