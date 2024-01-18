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

// `getNodeLength` returns the number of nodes in the given tree.
func getNodeLength(_ root: CRDTTreeNode?) -> Int {
    guard let root else {
        return -1
    }

    var size = 0

    size += root.innerChildren.count

    if root.innerChildren.isEmpty == false {
        root.innerChildren.forEach { child in
            size += getNodeLength(child)
        }
    }

    return size
}

class GCTests: XCTestCase {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    func test_garbage_collection_test() async throws {
        let doc = Document(key: "test-doc")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
        }, "set 1, 2, 3")

        try await doc.update({ root, _ in
            root.remove(key: "2")
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"1\":1,\"3\":3}", result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(4, len)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(4, len)
        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)
    }

    func test_disable_GC_test() async throws {
        let doc = Document(key: "test-doc", opts: DocumentOptions(disableGC: true))

        try await doc.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
        }, "set 1, 2, 3")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{\"1\":1,\"2\":[1,2,3],\"3\":3}", result)

        try await doc.update({ root, _ in
            root.remove(key: "2")
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"1\":1,\"3\":3}", result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(4, len)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(0, len)
        len = await doc.getGarbageLength()
        XCTAssertEqual(4, len)
    }

    func test_garbage_collection_test2() async throws {
        let size = 10000
        let doc = Document(key: "test-doc")

        try await doc.update({ root, _ in
            root["1"] = Array(Int64(0) ..< Int64(size))
        }, "set big array")

        try await doc.update({ root, _ in
            root.remove(key: "1")
        }, "deltes the array")

        let len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(size + 1, len)
    }

    func test_garbage_collection_test3() async throws {
        let doc = Document(key: "test-doc")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update({ root, _ in
            root["list"] = [Int64(1), Int64(2), Int64(3)]
        }, "set 1, 2, 3")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"list\":[1,2,3]}", result)

        try await doc.update({ root, _ in
            (root["list"] as? JSONArray)?.remove(at: 1)
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"list\":[1,3]}", result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(1, len)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(1, len)
        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)

        let root = await(doc.getRootObject().get(key: "list") as? CRDTArray)?.getElements().toTestString
        let clone = await(doc.getCloneRoot()?.get(key: "list") as? CRDTArray)?.getElements().toTestString

        XCTAssertEqual(root, clone)
    }

    func test_getGarbageLength_should_return_the_actual_number_of_elements_garbage_collected() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress: rpcAddress, options: options)
        let client2 = Client(rpcAddress: rpcAddress, options: options)

        try await client1.activate()
        try await client2.activate()

        // 1. initial state
        try await client1.attach(doc1, [:], false)

        try await doc1.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }

        try await client1.sync()
        try await client2.attach(doc2, [:], false)

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
        XCTAssertEqual(len, 1)  // x

        try await client1.sync()
        try await client2.sync()
        try await client1.sync()

        let gcNodeLen = 3   // point x, y
        var doc1Len = await doc1.getGarbageLength()
        var doc2Len = await doc2.getGarbageLength()
        XCTAssertEqual(doc1Len, gcNodeLen)
        XCTAssertEqual(doc2Len, gcNodeLen)

        // Actual garbage-collected nodes
        doc1Len = await doc1.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        doc2Len = await doc2.garbageCollect(lessThanOrEqualTo: TimeTicket.max)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_text_garbage_collection_test() async throws {
        let doc = Document(key: "test-doc")

        try await doc.update { root, _ in
            root.text = JSONText()
        }
        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(0, 0, "ABCD")
        }
        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(0, 2, "12")
        }

        var result = (await doc.getRoot().text as? JSONText)?.toTestString
        XCTAssertEqual("[0:00:0:0 ][3:00:1:0 12]{2:00:1:0 AB}[2:00:1:2 CD]", result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(1, len)
        await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)

        result = (await doc.getRoot().text as? JSONText)?.toTestString
        XCTAssertEqual("[0:00:0:0 ][3:00:1:0 12][2:00:1:2 CD]", result)

        try await doc.update { root, _ in
            (root.text as? JSONText)?.edit(2, 4, "")
        }

        result = (await doc.getRoot().text as? JSONText)?.toTestString
        XCTAssertEqual("[0:00:0:0 ][3:00:1:0 12]{2:00:1:2 CD}", result)
    }

    func test_garbage_collection_test_for_text() async throws {
        let doc = Document(key: "test-doc")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        var expectedMessage = "{\"k1\":[{\"val\":\"Hello \"},{\"val\":\"mario\"}]}"

        try await doc.update({ root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "Hello world")
            (root.k1 as? JSONText)?.edit(6, 11, "mario")

            XCTAssertEqual(expectedMessage, root.toJSON())
        }, "edit text k1")

        result = await doc.toSortedJSON()
        XCTAssertEqual(expectedMessage, result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(1, len)

        expectedMessage = "{\"k1\":[{\"val\":\"Hi\"},{\"val\":\" \"},{\"val\":\"j\"},{\"val\":\"ane\"}]}"

        try await doc.update({ root, _ in
            if let text = root.k1 as? JSONText {
                text.edit(0, 5, "Hi")
                text.edit(3, 4, "j")
                text.edit(4, 8, "ane")
            } else {
                assertionFailure("No Text.")
            }
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual(expectedMessage, result)

        let expectedGarbageLen = 4

        len = await doc.getGarbageLength()
        XCTAssertEqual(expectedGarbageLen, len)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(expectedGarbageLen, len)

        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)
    }

    func test_garbage_collection_test_for_text_with_attributes() async throws {
        let doc = Document(key: "test-doc")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        var expectedMessage = "{\"k1\":[{\"attrs\":{\"b\":\"1\"},\"val\":\"Hello \"},{\"val\":\"mario\"}]}"

        try await doc.update({ root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "Hello world", ["b": "1"])
            (root.k1 as? JSONText)?.edit(6, 11, "mario")

            XCTAssertEqual(expectedMessage, root.toJSON())
        }, "edit text k1")

        result = await doc.toSortedJSON()
        XCTAssertEqual(expectedMessage, result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(1, len)

        expectedMessage = "{\"k1\":[{\"attrs\":{\"b\":\"1\"},\"val\":\"Hi\"},{\"attrs\":{\"b\":\"1\"},\"val\":\" \"},{\"val\":\"j\"},{\"attrs\":{\"b\":\"1\"},\"val\":\"ane\"}]}"

        try await doc.update({ root, _ in
            if let text = root.k1 as? JSONText {
                text.edit(0, 5, "Hi", ["b": "1"])
                text.edit(3, 4, "j")
                text.edit(4, 8, "ane", ["b": "1"])
            } else {
                assertionFailure("No Text.")
            }
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual(expectedMessage, result)

        let expectedGarbageLen = 4

        len = await doc.getGarbageLength()
        XCTAssertEqual(expectedGarbageLen, len)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(expectedGarbageLen, len)

        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)
    }

    func test_garbage_collection_test_for_tree() async throws {
        let doc = Document(key: "test-doc")

        let result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc",
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

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], [JSONTreeTextNode(value: "gh")])
            } catch {
                assertionFailure("Can't editByPath")
            }

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p><tn>gh</tn><tn>cd</tn></p></doc>")
        }

        // [text(a), text(b)]
        var nodeLengthBeforeGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(len, 2)
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        var nodeLengthAfterGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        XCTAssertEqual(nodeLengthBeforeGC - nodeLengthAfterGC, 2)

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], [JSONTreeTextNode(value: "cv")])
            } catch {
                assertionFailure("Can't editByPath")
            }

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p><tn>cv</tn><tn>cd</tn></p></doc>")
        }

        // [text(cd)]
        nodeLengthBeforeGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 1)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(len, 1)
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        nodeLengthAfterGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        XCTAssertEqual(nodeLengthBeforeGC - nodeLengthAfterGC, 1)

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0], [1],
                                                      [JSONTreeElementNode(type: "p",
                                                                           children: [
                                                                               JSONTreeElementNode(type: "tn",
                                                                                                   children: [JSONTreeTextNode(value: "ab")])
                                                                           ])])
            } catch {
                assertionFailure("Can't editByPath")
            }

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p><tn>ab</tn></p></doc>")
        }

        // [p, tn, tn, text(cv), text(cd)]
        nodeLengthBeforeGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 5)
        len = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
        XCTAssertEqual(len, 5)
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        nodeLengthAfterGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        XCTAssertEqual(nodeLengthBeforeGC - nodeLengthAfterGC, 5)
    }

    func test_can_handle_tree_garbage_collection_for_multi_client() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress: rpcAddress, options: options)
        let client2 = Client(rpcAddress: rpcAddress, options: options)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], false)
        try await client2.attach(doc2, [:], false)

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
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], [JSONTreeTextNode(value: "gh")])
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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress: rpcAddress, options: options)
        let client2 = Client(rpcAddress: rpcAddress, options: options)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], false)
        try await client2.attach(doc2, [:], false)

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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress: rpcAddress, options: options)
        let client2 = Client(rpcAddress: rpcAddress, options: options)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], false)
        try await client2.attach(doc2, [:], false)

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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress: rpcAddress, options: options)
        let client2 = Client(rpcAddress: rpcAddress, options: options)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], false)
        try await client2.attach(doc2, [:], false)

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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc = Document(key: docKey)

        let client = Client(rpcAddress: rpcAddress, options: options)

        try await client.activate()

        try await client.attach(doc, [:], false)

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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress: rpcAddress, options: options)
        let client2 = Client(rpcAddress: rpcAddress, options: options)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], false)

        try await doc1.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }

        try await doc1.update { root, _ in
            (root.point as? JSONObject)?.x = Int64(1)
        }

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await client1.sync()

        try await client2.attach(doc2, [:], false)

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
}
