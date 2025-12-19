/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

// `getNodeLength` returns the number of nodes in the given tree.
func getNodeLength(_ root: CRDTTreeNode?) -> Int {
    guard let root else {
        return -1
    }

    var size = 0

    size += root.innerChildren.count

    if root.innerChildren.isEmpty == false {
        for child in root.innerChildren {
            size += getNodeLength(child)
        }
    }

    return size
}

final class GCTests: XCTestCase {
    func test_should_collect_garbage() async throws {
        let doc = Document(key: "test-doc")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
        }, "set 1, 2, 3")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"1\":1,\"2\":[1,2,3],\"3\":3}", result)

        try await doc.update({ root, _ in
            root.remove(key: "2")
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"1\":1,\"3\":3}", result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(4, len)
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(4, len)
        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)
    }

    func test_should_not_collect_garbage_if_disabled() async throws {
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
        let actors = await [doc.changeID.getActorID()].compactMap { $0 }
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: actors))
        XCTAssertEqual(0, len)
        len = await doc.getGarbageLength()
        XCTAssertEqual(4, len)
    }

    func test_should_collect_garbage_for_big_array() async throws {
        let size = 10000
        let doc = Document(key: "test-doc")

        try await doc.update({ root, _ in
            root["1"] = Array(Int64(0) ..< Int64(size))
        }, "set big array")

        try await doc.update({ root, _ in
            root.remove(key: "1")
        }, "deltes the array")

        let len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(size + 1, len)
    }

    func test_should_collect_garbage_for_nested_elements() async throws {
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
        let actors = await [doc.changeID.getActorID()].compactMap { $0 }
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: actors))
        XCTAssertEqual(1, len)
        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)

        let root = await(doc.getRootObject().get(key: "list") as? CRDTArray)?.getElements().toTestString
        let clone = await(doc.getCloneRoot()?.get(key: "list") as? CRDTArray)?.getElements().toTestString

        XCTAssertEqual(root, clone)
    }

    func test_should_collect_garbage_for_text_node() async throws {
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
        await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
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

    func test_should_return_correct_gc_count_with_already_removed_text_node() async throws {
        let doc = Document(key: "test-doc")

        var result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update({ root, _ in
            root.k1 = JSONText()
            (root.k1 as? JSONText)?.edit(0, 0, "ab")
            (root.k1 as? JSONText)?.edit(0, 1, "c")
        }, "edit text k1")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"k1\":[{\"val\":\"c\"},{\"val\":\"b\"}]}", result)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(1, len)

        try await doc.update({ root, _ in
            if let text = root.k1 as? JSONText {
                text.edit(1, 2, "d")
            } else {
                assertionFailure("No Text.")
            }
        }, "deletes 2")

        result = await doc.toSortedJSON()
        XCTAssertEqual("{\"k1\":[{\"val\":\"c\"},{\"val\":\"d\"}]}", result)

        len = await doc.getGarbageLength()
        XCTAssertEqual(2, len)
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(2, len)

        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)
    }

    func test_should_collect_garbage_for_text_node_with_attributes() async throws {
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
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(expectedGarbageLen, len)

        len = await doc.getGarbageLength()
        XCTAssertEqual(0, len)
    }

    func test_should_collect_garbage_for_tree_node() async throws {
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
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], JSONTreeTextNode(value: "gh"))
            } catch {
                assertionFailure("Can't editByPath")
            }

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p><tn>gh</tn><tn>cd</tn></p></doc>")
        }

        // [text(a), text(b)]
        var nodeLengthBeforeGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(len, 2)
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        var nodeLengthAfterGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        XCTAssertEqual(nodeLengthBeforeGC - nodeLengthAfterGC, 2)

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], JSONTreeTextNode(value: "cv"))
            } catch {
                assertionFailure("Can't editByPath")
            }

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p><tn>cv</tn><tn>cd</tn></p></doc>")
        }

        // [text(cd)]
        nodeLengthBeforeGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 1)
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(len, 1)
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        nodeLengthAfterGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        XCTAssertEqual(nodeLengthBeforeGC - nodeLengthAfterGC, 1)

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0], [1],
                                                      JSONTreeElementNode(type: "p",
                                                                          children: [
                                                                              JSONTreeElementNode(type: "tn",
                                                                                                  children: [JSONTreeTextNode(value: "ab")])
                                                                          ]))
            } catch {
                assertionFailure("Can't editByPath")
            }

            XCTAssertEqual((root.t as? JSONTree)?.toXML(), "<doc><p><tn>ab</tn></p></doc>")
        }

        // [p, tn, tn, text(cv), text(cd)]
        nodeLengthBeforeGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 5)
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(len, 5)
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        nodeLengthAfterGC = try await getNodeLength((doc.getRoot().t as? JSONTree)?.getIndexTree().root)

        XCTAssertEqual(nodeLengthBeforeGC - nodeLengthAfterGC, 5)
    }

    func test_should_return_correct_gc_count_with_already_removed_tree_node() async throws {
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
                                                                                                                   JSONTreeTextNode(value: "abc")
                                                                                                               ])
                                                                                       ])
                                                               ])
            )
        }

        var xml = await(doc.getRoot().t as? JSONTree)!.toXML()
        XCTAssertEqual(xml, "<doc><p><tn>abc</tn></p></doc>")
        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.edit(3, 4)
            } catch {
                assertionFailure("Can't editByPath")
            }
        }

        xml = await(doc.getRoot().t as? JSONTree)!.toXML()
        XCTAssertEqual(xml, "<doc><p><tn>ac</tn></p></doc>")
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc.update { root, _ in
            do {
                try (root.t as? JSONTree)?.edit(2, 4)
            } catch {
                assertionFailure("Can't editByPath")
            }
        }

        xml = await(doc.getRoot().t as? JSONTree)!.toXML()
        XCTAssertEqual(xml, "<doc><p><tn></tn></p></doc>")
        len = await doc.getGarbageLength()
        XCTAssertEqual(len, 3)
    }

    func test_should_collect_garbage_for_nested_object() async throws {
        let doc = Document(key: "test-doc")

        try await doc.update { root, _ in
            root.shape = ["point": ["x": Int64(0), "y": Int64(0)]]
            root.remove(key: "shape")
        }

        let len = await doc.getGarbageLength()
        XCTAssertEqual(len, 4)

        let nodeCount = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(nodeCount, 4)
    }
}

final class GCTestsForTree: XCTestCase {
    enum OpCode {
        case noOp
        case style
        case removeStyle
        case deleteNode
        case gc
    }

    struct Operation {
        let code: OpCode
        let key: String
        let val: String
    }

    struct Step {
        let op: Operation
        let garbageLen: Int
        let expectXML: String
    }

    struct TestCase {
        let desc: String
        let steps: [Step]
    }

    let tests: [TestCase] = [
        TestCase(desc: "style-style test",
                 steps: [
                     Step(op: Operation(code: .style, key: "b", val: "t"),
                          garbageLen: 0,
                          expectXML: "<r><p b=\"t\"></p></r>"),
                     Step(op: Operation(code: .style, key: "b", val: "f"),
                          garbageLen: 0,
                          expectXML: "<r><p b=\"f\"></p></r>")
                 ]),
        TestCase(desc: "style-remove test",
                 steps: [
                     Step(op: Operation(code: .style, key: "b", val: "t"),
                          garbageLen: 0,
                          expectXML: "<r><p b=\"t\"></p></r>"),
                     Step(op: Operation(code: .removeStyle, key: "b", val: ""),
                          garbageLen: 1,
                          expectXML: "<r><p></p></r>")
                 ]),
        TestCase(desc: "remove-style test",
                 steps: [
                     Step(op: Operation(code: .removeStyle, key: "b", val: ""),
                          garbageLen: 1,
                          expectXML: "<r><p></p></r>"),
                     Step(op: Operation(code: .style, key: "b", val: "t"),
                          garbageLen: 0,
                          expectXML: "<r><p b=\"t\"></p></r>")
                 ]),
        TestCase(desc: "remove-remove test",
                 steps: [
                     Step(op: Operation(code: .removeStyle, key: "b", val: ""),
                          garbageLen: 1,
                          expectXML: "<r><p></p></r>"),
                     Step(op: Operation(code: .removeStyle, key: "b", val: ""),
                          garbageLen: 1,
                          expectXML: "<r><p></p></r>")
                 ]),
        TestCase(desc: "style-delete test",
                 steps: [
                     Step(op: Operation(code: .style, key: "b", val: "t"),
                          garbageLen: 0,
                          expectXML: "<r><p b=\"t\"></p></r>"),
                     Step(op: Operation(code: .deleteNode, key: "", val: ""),
                          garbageLen: 1,
                          expectXML: "<r></r>")
                 ]),
        TestCase(desc: "remove-delete test",
                 steps: [
                     Step(op: Operation(code: .removeStyle, key: "b", val: ""),
                          garbageLen: 1,
                          expectXML: "<r><p></p></r>"),
                     Step(op: Operation(code: .deleteNode, key: "", val: ""),
                          garbageLen: 2,
                          expectXML: "<r></r>")
                 ]),
        TestCase(desc: "remove-gc-delete test",
                 steps: [
                     Step(op: Operation(code: .removeStyle, key: "b", val: ""),
                          garbageLen: 1,
                          expectXML: "<r><p></p></r>"),
                     Step(op: Operation(code: .gc, key: "", val: ""),
                          garbageLen: 0,
                          expectXML: "<r><p></p></r>"),
                     Step(op: Operation(code: .deleteNode, key: "", val: ""),
                          garbageLen: 1,
                          expectXML: "<r></r>")
                 ])
    ]

    func test_garbage_collection_test_for_tree() async throws {
        for test in self.tests {
            let doc = Document(key: "test-doc")

            var result = await doc.toSortedJSON()
            XCTAssertEqual("{}", result)

            try await doc.update { root, _ in
                root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                    JSONTreeElementNode(type: "p")
                ]))
            }

            result = await(doc.getRoot().t as? JSONTree)!.toXML()
            XCTAssertEqual("<r><p></p></r>", result)

            for step in test.steps {
                if step.op.code == .gc {
                    await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
                } else {
                    try await doc.update { root, _ in
                        switch step.op.code {
                        case .removeStyle:
                            try (root.t as? JSONTree)?.removeStyle(0, 1, [step.op.key])
                        case .style:
                            try (root.t as? JSONTree)?.style(0, 1, [step.op.key: step.op.val])
                        case .deleteNode:
                            try (root.t as? JSONTree)?.edit(0, 2)
                        default:
                            break
                        }
                    }
                }

                let result = await(doc.getRoot().t as? JSONTree)!.toXML()
                XCTAssertEqual(result, step.expectXML)

                let len = await doc.getGarbageLength()
                XCTAssertEqual(len, step.garbageLen, test.desc)
            }

            await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))

            let len = await doc.getGarbageLength()
            XCTAssertEqual(len, 0)
        }
    }
}

final class GCTestsForText: XCTestCase {
    enum OpCode {
        case noOp
        case style
        case deleteNode
        case gc
    }

    struct Operation {
        let code: OpCode
        let key: String
        let val: String
    }

    struct Step {
        let op: Operation
        let garbageLen: Int
        let expectXML: String
    }

    struct TestCase {
        let desc: String
        let steps: [Step]
    }

    let tests: [TestCase] = [
        TestCase(desc: "style-style test",
                 steps: [
                     Step(op: Operation(code: .style, key: "b", val: "t"),
                          garbageLen: 0,
                          expectXML: "[{\"attrs\":{\"b\":\"t\"},\"val\":\"AB\"}]"),
                     Step(op: Operation(code: .style, key: "b", val: "f"),
                          garbageLen: 0,
                          expectXML: "[{\"attrs\":{\"b\":\"f\"},\"val\":\"AB\"}]")
                 ]),
        TestCase(desc: "style-delete test",
                 steps: [
                     Step(op: Operation(code: .style, key: "b", val: "t"),
                          garbageLen: 0,
                          expectXML: "[{\"attrs\":{\"b\":\"t\"},\"val\":\"AB\"}]"),
                     Step(op: Operation(code: .deleteNode, key: "", val: ""),
                          garbageLen: 1,
                          expectXML: "[]")
                 ])
    ]

    func test_garbage_collection_test_for_text() async throws {
        for test in self.tests {
            let doc = Document(key: "test-doc")

            var result = await doc.toSortedJSON()
            XCTAssertEqual("{}", result)

            try await doc.update { root, _ in
                root.t = JSONText()
                (root.t as? JSONText)?.edit(0, 0, "AB")
            }

            result = await(doc.getRoot().t as? JSONText)!.toSortedJSON()
            XCTAssertEqual("[{\"val\":\"AB\"}]", result)

            for step in test.steps {
                if step.op.code == .gc {
                    await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
                } else {
                    try await doc.update { root, _ in
                        switch step.op.code {
                        case .style:
                            (root.t as? JSONText)?.setStyle(0, 2, [step.op.key: step.op.val])
                        case .deleteNode:
                            (root.t as? JSONText)?.edit(0, 2, "")
                        default:
                            break
                        }
                    }
                }

                let result = await(doc.getRoot().t as? JSONText)!.toSortedJSON()
                XCTAssertEqual(step.expectXML, result)

                let len = await doc.getGarbageLength()
                XCTAssertEqual(len, step.garbageLen)
            }

            await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))

            let len = await doc.getGarbageLength()
            XCTAssertEqual(len, 0)
        }
    }
    
    // should update gc size correctly after text garbage collection
    func test_should_update_gc_size_correctly_after_text_garbage_collection() async throws {
        let doc = Document(key: "test-doc")
        
        func garbagelen() async -> Int {
            await doc.getGarbageLength()
        }
        
        let result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update { root, _ in
            root.t = JSONText()
        }
        var gc = await doc.getDocSize().gc
        XCTAssertEqual(gc, .init(data: 0, meta: 0))
        
        try await doc.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "Hello world")
            (root.t as? JSONText)?.edit(6, 11, "")
        }
        
        gc = await doc.getDocSize().gc
        var garbageLen = await garbagelen()
        XCTAssertEqual(gc, .init(data: 10, meta: 48))
        XCTAssertEqual(garbageLen, 1)
        
        let len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(len, 1)
        
        gc = await doc.getDocSize().gc
        XCTAssertEqual(gc, .init(data: 0, meta: 0))
        
        garbageLen = await garbagelen()
        XCTAssertEqual(garbageLen, 0)
    }
    
    // should update gc size correctly after multiple text operations and gc
    func test_should_update_gc_size_correctly_after_multiple_text_operations_and_gc() async throws {
        let doc = Document(key: "test-doc")
        
        let result = await doc.toSortedJSON()
        XCTAssertEqual("{}", result)

        try await doc.update { root, _ in
            root.t = JSONText()
        }
        
        try await doc.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "ABC")
            (root.t as? JSONText)?.edit(1, 2, "X")
            (root.t as? JSONText)?.edit(2, 3, "")
        }
        
        let sizeBeforeGC = await doc.getDocSize()
        var garbageLen = await doc.getGarbageLength()
        
        XCTAssertEqual(sizeBeforeGC.gc, .init(data: 4, meta: 96))
        XCTAssertEqual(garbageLen, 2)
        
        let collected = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        XCTAssertEqual(collected, garbageLen)
        
        let gc = await doc.getDocSize().gc
        XCTAssertEqual(gc, .init(data: 0, meta: 0))
        
        garbageLen = await doc.getGarbageLength()
        XCTAssertEqual(garbageLen, 0)
        
    }
}
