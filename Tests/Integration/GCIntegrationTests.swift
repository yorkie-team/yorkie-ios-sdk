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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// swiftlint:disable function_body_length type_body_length
class GCIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    // getGarbageLen should return the actual number of elements garbage-collected
    @MainActor
    func test_getGarbageLength_should_return_the_actual_number_of_elements_garbage_collected() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

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
        doc1Len = await doc1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [client1.id, client2.id]))
        doc2Len = await doc2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [client1.id, client2.id]))

        XCTAssertEqual(doc1Len, gcNodeLen)
        XCTAssertEqual(doc2Len, gcNodeLen)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // Can handle tree garbage collection for multi client
    @MainActor
    func test_can_handle_tree_garbage_collection_for_multi_client() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()

        try await c1.attach(d1, [:], .manual)
        await assertTrue(versionVector: d1.getVersionVector(),
                         actorDatas: [])

        try await c2.attach(d2, [:], .manual)
        await assertTrue(versionVector: d2.getVersionVector(),
                         actorDatas: [])

        try await d1.update { root, _ in
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

        await assertTrue(versionVector: d1.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1)
        ])

        var len = await d1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await c1.sync()
        await assertTrue(versionVector: d1.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1)
        ])

        try await c2.sync()
        await assertTrue(versionVector: d2.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1),
            ActorData(actor: c2.id!, lamport: 2)
        ])

        try await d2.update({ root, _ in
            do {
                try (root.t as? JSONTree)?.editByPath([0, 0, 0], [0, 0, 2], JSONTreeTextNode(value: "gh"))
            } catch {
                assertionFailure("Can't editByPath")
            }
        }, "removes 2")

        await assertTrue(versionVector: d2.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1),
            ActorData(actor: c2.id!, lamport: 3)
        ])

        len = await d1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await c2.sync()
        await assertTrue(versionVector: d2.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1),
            ActorData(actor: c2.id!, lamport: 3)
        ])

        len = await d1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await c1.sync()
        await assertTrue(versionVector: d1.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 4),
            ActorData(actor: c2.id!, lamport: 3)
        ])

        len = await d1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await c2.sync()
        await assertTrue(versionVector: d2.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1),
            ActorData(actor: c2.id!, lamport: 3)
        ])

        len = await d1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await c1.sync()
        await assertTrue(versionVector: d1.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 4),
            ActorData(actor: c2.id!, lamport: 3)
        ])

        len = await d1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await c2.sync()
        await assertTrue(versionVector: d2.getVersionVector(), actorDatas: [
            ActorData(actor: c1.id!, lamport: 1),
            ActorData(actor: c2.id!, lamport: 3)
        ])

        len = await d1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await d2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await c1.detach(d1)
        try await c2.detach(d2)

        try await c1.deactivate()
        try await c2.deactivate()
    }

    @MainActor
    func test_can_handle_garbage_collection_for_container_type() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
        }, "set 1, 2,3")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            root.remove(key: "2")
        }, "removes 2")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client1.sync()
        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.detach(doc1)
        try await client2.detach(doc2)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    @MainActor
    func test_can_handle_garbage_collection_for_text_type() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "Hello World")
            root.textWithAttr = JSONText()
            (root.textWithAttr as? JSONText)?.edit(0, 0, "Hello World")
        }, "sets text")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            (root.text as? JSONText)?.edit(0, 1, "a")
            (root.text as? JSONText)?.edit(1, 2, "b")
            (root.textWithAttr as? JSONText)?.edit(0, 1, "a", ["b": "1"])

        }, "edit text type elements")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.detach(doc1)
        try await client2.detach(doc2)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // Can handle garbage collection with detached document test
    @MainActor
    func test_can_handle_garbage_collection_with_detached_document_test() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root["1"] = Int64(1)
            root["2"] = [Int64(1), Int64(2), Int64(3)]
            root["3"] = Int64(3)
            root["4"] = JSONText()
            (root["4"] as? JSONText)?.edit(0, 0, "hi")
            root["5"] = JSONText()
            (root["5"] as? JSONText)?.edit(0, 0, "hi")
        }, "sets 1, 2, 3, 4, 5")

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc1.update({ root, _ in
            root.remove(key: "2")
            (root["4"] as? JSONText)?.edit(0, 1, "h")
            (root["5"] as? JSONText)?.edit(0, 1, "h", ["b": "1"])
        }, "removes 2 and edit text type elements")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client2.detach(doc2)

        try await client2.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 6)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 6)

        try await client1.detach(doc1)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // Can collect removed elements from both root and clone
    @MainActor
    func test_can_collect_removed_elements_from_both_root_and_clone() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc = Document(key: docKey)

        let client = Client(rpcAddress)

        try await client.activate()

        try await client.attach(doc, [:], .manual)
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [])

        try await doc.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [
            ActorData(actor: client.id!, lamport: 1)
        ])

        try await doc.update { root, _ in
            root.point = ["x": Int64(1), "y": Int64(1)]
        }
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [
            ActorData(actor: client.id!, lamport: 2)
        ])

        try await doc.update { root, _ in
            root.point = ["x": Int64(2), "y": Int64(2)]
        }
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [
            ActorData(actor: client.id!, lamport: 3)
        ])

        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 6)
        len = await doc.getGarbageLengthFromClone()
        XCTAssertEqual(len, 6)
    }

    // Can collect removed elements from both root and clone for nested array
    @MainActor
    func test_can_collect_removed_elements_from_both_root_and_clone_for_nested_array() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc = Document(key: docKey)

        let client = Client(rpcAddress)

        try await client.activate()
        try await client.attach(doc, [:], .manual)
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [])

        try await doc.update { root, _ in
            root.list = [Int(0), Int(1), Int(2)]
            (root.list as? JSONArray)?.push([Int(3), Int(4), Int(5)])
        }
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [
            ActorData(actor: client.id!, lamport: 1)
        ])

        var expectedJson = await doc.toJSON()
        XCTAssertEqual("{\"list\":[0,1,2,[3,4,5]]}", expectedJson)

        try await doc.update { root, _ in
            (root.list as? JSONArray)?.remove(index: 1)
        }
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [
            ActorData(actor: client.id!, lamport: 2)
        ])

        expectedJson = await doc.toJSON()
        XCTAssertEqual("{\"list\":[0,2,[3,4,5]]}", expectedJson)

        try await doc.update { root, _ in
            ((root.list as? JSONArray)?[2] as? JSONArray)?.remove(index: 1)
        }
        await assertTrue(versionVector: doc.getVersionVector(), actorDatas: [
            ActorData(actor: client.id!, lamport: 3)
        ])

        expectedJson = await doc.toJSON()
        XCTAssertEqual("{\"list\":[0,2,[3,5]]}", expectedJson)

        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 2)

        len = await doc.getGarbageLengthFromClone()
        XCTAssertEqual(len, 2)

        try await client.deactivate()
    }

    // Can purges removed elements after peers can not access them
    @MainActor
    func test_can_purges_removed_elements_after_peers_can_not_access_them() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await doc1.update { root, _ in
            root.point = ["x": Int64(0), "y": Int64(0)]
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await doc1.update { root, _ in
            (root.point as? JSONObject)?.x = Int64(1)
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await client1.sync()

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc2.update { root, _ in
            (root.point as? JSONObject)?.x = Int64(2)
        }
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await doc1.update { root, _ in
            root.point = ["x": Int64(3), "y": Int64(3)]
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client1.sync()
        await assertTrue(versionVector: await doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client1.sync()
        await assertTrue(versionVector: await doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 3)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 3),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 3)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client2.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 4)

        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client2.sync()
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // garbage collection test for nested object
    @MainActor
    func test_garbage_collection_test_for_nested_object() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc = Document(key: docKey)

        let client = Client(rpcAddress)

        try await client.activate()

        try await doc.update { root, _ in
            root.shape = JSONObject()
            (root.shape as? JSONObject)?.point = JSONObject()
            ((root.shape as? JSONObject)?.point as? JSONObject)?.set(key: "x", value: Int32(0))
            ((root.shape as? JSONObject)?.point as? JSONObject)?.set(key: "y", value: Int32(0))
            root.remove(key: "shape")
        }

        var len = await doc.getGarbageLength()
        XCTAssertEqual(len, 4)

        let actorID = await doc.changeID.getActorID() ?? ""
        len = await doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorID]))
        XCTAssertEqual(len, 4) // The number of GC nodes must also be 4.
    }

    // Should work properly when there are multiple nodes to be collected in text type
    @MainActor
    func test_should_work_properly_when_there_are_multiple_nodes_to_be_collected_in_text_type() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "z")
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(0, 1, "a")
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(1, 1, "b")
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 3)
        ])

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(2, 2, "d")
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        var strDoc1 = await(doc1.getRoot().t as? JSONText)?.toString
        var strDoc2 = await(doc2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc1, "abd")
        XCTAssertEqual(strDoc2, "abd")
        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        strDoc1 = await(doc1.getRoot().t as? JSONText)?.toString
        strDoc2 = await(doc2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc1, "abcd")
        XCTAssertEqual(strDoc2, "abcd")

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        strDoc1 = await(doc1.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc1, "ad")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2) // b,c

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 7)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        try await client2.sync()
        strDoc2 = await(doc2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(strDoc2, "ad")

        try await client1.sync()
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // Should work properly when there are multiple nodes to be collected in tree type
    @MainActor
    func test_should_work_properly_when_there_are_multiple_nodes_to_be_collected_in_tree_type() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "r",
                                    children: [
                                        JSONTreeTextNode(value: "z")
                                    ])
            )
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([0], [1], JSONTreeTextNode(value: "a"))
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([1], [1], JSONTreeTextNode(value: "b"))
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 3)
        ])

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([2], [2], JSONTreeTextNode(value: "d"))
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        var strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        var strDoc2 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>abd</r>")
        XCTAssertEqual(strDoc2, "<r>abd</r>")
        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 1)

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([2], [2], JSONTreeTextNode(value: "c"))
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        strDoc2 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>abcd</r>")
        XCTAssertEqual(strDoc2, "<r>abcd</r>")

        try await doc1.update { root, _ in
            try (root.t as? JSONTree)?.editByPath([1], [3])
        }
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>ad</r>")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2) // b, c

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 7)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        strDoc2 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc2, "<r>ad</r>")
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 7)
        ])

        strDoc2 = await(doc2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc2, "<r>ad</r>")
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6)
        ])

        strDoc1 = await(doc1.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(strDoc1, "<r>ad</r>")
        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // concurrent garbage collection test
    @MainActor
    func test_concurrent_garbage_collection_test() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
            (root.t as? JSONText)?.edit(1, 1, "b")
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "sets text")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "insert c")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await doc1.update({ root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }, "delete bd")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "1")
        }, "insert 1")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // concurrent garbage collection test(with pushonly
    @MainActor
    func test_concurrent_garbage_collection_test_with_pushonly() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
            (root.t as? JSONText)?.edit(1, 1, "b")
        }, "insert ab")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "d")
        }, "insert d")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "insert c")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        try await doc1.update({ root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }, "remove ac")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        // Sync with PushOnly
        try await client2.changeSyncMode(doc2, .realtimePushOnly)
        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "1")
        }, "insert 1 (pushonly)")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 7),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        var len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "2")
        }, "insert 2 (pushonly)")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        try await client2.changeSyncMode(doc2, .manual)
        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5),
            ActorData(actor: client2.id!, lamport: 7)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 8),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 2)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 5),
            ActorData(actor: client2.id!, lamport: 7)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 2)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 8),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        len = await doc1.getGarbageLength()
        XCTAssertEqual(len, 0)
        len = await doc2.getGarbageLength()
        XCTAssertEqual(len, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // gc targeting nodes made by deactivated client
    @MainActor
    func test_gc_targeting_nodes_made_by_deactivated_client() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
            (root.t as? JSONText)?.edit(1, 1, "b")
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "sets text")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "insert c")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await doc1.update({ root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }, "delete bd")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await client1.sync()
        try await client2.sync()

        try await client1.deactivate()

        let garbageLength1 = await doc2.getGarbageLength()
        let getVersionVector1 = await doc2.getVersionVector().size()

        XCTAssertEqual(garbageLength1, 2)
        XCTAssertEqual(getVersionVector1, 2)

        try await client2.sync()
        let garbageLength2 = await doc2.getGarbageLength()
        let getVersionVector2 = await doc2.getVersionVector().size()

        XCTAssertEqual(garbageLength2, 0)
        XCTAssertEqual(getVersionVector2, 2)
    }

    // attach > pushpull > detach lifecycle version vector test (run gc at last client detaches document, but no tombstone exsits)
    @MainActor
    func test_gc_attach_pushpull_detach_lifecycle_version_vector_no_tombstone_exsits() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
            (root.t as? JSONText)?.edit(1, 1, "b")
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "sets text")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "insert c")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await doc1.update({ root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }, "delete bd")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        let doc1Garbage1 = await doc1.getGarbageLength()
        let doc2Garbage1 = await doc2.getGarbageLength()

        XCTAssertEqual(doc1Garbage1, 2)
        XCTAssertEqual(doc2Garbage1, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        let doc1Garbage2 = await doc1.getGarbageLength()
        let doc2Garbage2 = await doc2.getGarbageLength()

        XCTAssertEqual(doc1Garbage2, 2)
        XCTAssertEqual(doc2Garbage2, 2)

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "1")
        }, "insert 1")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        let doc1Garbage3 = await doc1.getGarbageLength()
        let doc2Garbage3 = await doc2.getGarbageLength()

        XCTAssertEqual(doc1Garbage3, 2)
        XCTAssertEqual(doc2Garbage3, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client1.detach(doc1)
        try await client2.sync()

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(0, 3, "")
        }, "delete all")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        let doc2Garbage4 = await doc2.getGarbageLength()
        XCTAssertEqual(doc2Garbage4, 3)

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        let doc2Garbage5 = await doc2.getGarbageLength()
        XCTAssertEqual(doc2Garbage5, 0)

        try await client2.detach(doc2)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // attach > pushpull > detach lifecycle version vector test (run gc at last client detaches document)
    @MainActor
    func test_gc_attach_pushpull_detach_lifecycle_version_vector() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()

        try await client1.attach(doc1, [:], .manual)
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        try await client2.attach(doc2, [:], .manual)
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
            (root.t as? JSONText)?.edit(1, 1, "b")
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "sets text")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "insert c")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 3)
        ])

        try await doc1.update({ root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }, "delete bd")
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        let doc1Garbage1 = await doc1.getGarbageLength()
        let doc2Garbage1 = await doc2.getGarbageLength()

        XCTAssertEqual(doc1Garbage1, 2)
        XCTAssertEqual(doc2Garbage1, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        let doc1Garbage2 = await doc1.getGarbageLength()
        let doc2Garbage2 = await doc2.getGarbageLength()

        XCTAssertEqual(doc1Garbage2, 2)
        XCTAssertEqual(doc2Garbage2, 2)

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(2, 2, "1")
        }, "insert 1")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client2.sync()
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        let doc1Garbage3 = await doc1.getGarbageLength()
        let doc2Garbage3 = await doc2.getGarbageLength()

        XCTAssertEqual(doc1Garbage3, 2)
        XCTAssertEqual(doc2Garbage3, 0)

        try await client1.sync()
        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await client1.detach(doc1)
        try await client2.sync()

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 5)
        ])

        try await doc2.update({ root, _ in
            (root.t as? JSONText)?.edit(0, 3, "")
        }, "delete all")
        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 2),
            ActorData(actor: client2.id!, lamport: 6)
        ])

        let doc2Garbage4 = await doc2.getGarbageLength()
        XCTAssertEqual(doc2Garbage4, 3)

        try await client2.detach(doc2)

        let doc2Garbage5 = await doc2.getGarbageLength()
        XCTAssertEqual(doc2Garbage5, 0)

        try await client1.deactivate()
        try await client2.deactivate()
    }

    // detach gc test
    @MainActor
    func test_detach_gc() async throws {
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)
        let doc3 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)
        let client3 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()
        try await client3.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)
        try await client3.attach(doc3, [:], .manual)

        try await client1.sync()
        try await client2.sync()
        try await client3.sync()

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [])

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [])

        await assertTrue(versionVector: doc3.getVersionVector(), actorDatas: [])

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
            (root.t as? JSONText)?.edit(1, 1, "b")
            (root.t as? JSONText)?.edit(2, 2, "c")
        }, "sets text")

        try await client1.sync()
        try await client2.sync()
        try await client3.sync()

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        await assertTrue(versionVector: doc3.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client3.id!, lamport: 2)
        ])

        // doc3 update
        try await doc3.update { root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }

        // doc1 update
        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "1")
        }

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "2")
        }

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "3")
        }

        // doc2 update
        try await doc2.update { root, _ in
            (root.t as? JSONText)?.edit(3, 3, "x")
        }

        try await doc2.update { root, _ in
            (root.t as? JSONText)?.edit(4, 4, "y")
        }

        // sync
        try await client1.sync()
        try await client2.sync()
        try await client1.sync()

        let doc1Expected = await doc1.toJSON()
        let doc2Expected = await doc1.toJSON()

        let doc1JSON = """
        {"t":[{"val":"3"},{"val":"2"},{"val":"1"},{"val":"a"},{"val":"b"},{"val":"c"},{"val":"x"},{"val":"y"}]}
        """

        let doc2JSON = """
        {"t":[{"val":"3"},{"val":"2"},{"val":"1"},{"val":"a"},{"val":"b"},{"val":"c"},{"val":"x"},{"val":"y"}]}
        """
        XCTAssertEqual(doc1JSON, doc1Expected)
        XCTAssertEqual(doc2JSON, doc2Expected)

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 6),
            ActorData(actor: client2.id!, lamport: 4)
        ])

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 7)
        ])

        await assertTrue(versionVector: doc3.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client3.id!, lamport: 3)
        ])

        try await client3.detach(doc3)

        try await doc2.update { root, _ in
            (root.t as? JSONText)?.edit(5, 5, "z")
        }

        try await client1.sync()

        let len1 = await doc1.getGarbageLength()
        XCTAssertEqual(len1, 2)

        try await client1.sync()

        let len2 = await doc1.getGarbageLength()
        XCTAssertEqual(len2, 2)

        // client 2 sync
        try await client2.sync()
        try await client1.sync()

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 9),
            ActorData(actor: client2.id!, lamport: 8),
            ActorData(actor: client3.id!, lamport: 3)
        ])

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 4),
            ActorData(actor: client2.id!, lamport: 9),
            ActorData(actor: client3.id!, lamport: 3)
        ])

        let doc3Expected = await doc1.toJSON()
        let doc4Expected = await doc1.toJSON()
        let doc3JSON = """
        {"t":[{"val":"3"},{"val":"2"},{"val":"1"},{"val":"a"},{"val":"z"},{"val":"x"},{"val":"y"}]}
        """
        let doc4JSON = """
        {"t":[{"val":"3"},{"val":"2"},{"val":"1"},{"val":"a"},{"val":"z"},{"val":"x"},{"val":"y"}]}
        """
        XCTAssertEqual(doc3JSON, doc3Expected)
        XCTAssertEqual(doc4JSON, doc4Expected)

        let len3 = await doc1.getGarbageLength()
        XCTAssertEqual(len3, 2)

        let len4 = await doc2.getGarbageLength()
        XCTAssertEqual(len4, 2)

        // client 2 sync
        try await client2.sync()
        try await client1.sync()

        let len5 = await doc1.getGarbageLength()
        XCTAssertEqual(len5, 0)

        let len6 = await doc2.getGarbageLength()
        XCTAssertEqual(len6, 0)

        try await client1.deactivate()
        try await client2.deactivate()
        try await client1.deactivate()
    }

    // snapshot version vector test
    @MainActor
    func test_snapshot_version_vector() async throws {
        let docKey = "\(#function)-\(Date().timeIntervalSince1970)".toDocKey
        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)
        let doc3 = Document(key: docKey)

        let client1 = Client(rpcAddress)
        let client2 = Client(rpcAddress)
        let client3 = Client(rpcAddress)

        try await client1.activate()
        try await client2.activate()
        try await client3.activate()

        try await client1.attach(doc1, [:], .manual)
        try await client2.attach(doc2, [:], .manual)
        try await client3.attach(doc3, [:], .manual)

        try await doc1.update({ root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
        }, "sets text")

        try await client1.sync()
        try await client2.sync()
        try await client3.sync()

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1)
        ])

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client2.id!, lamport: 2)
        ])

        await assertTrue(versionVector: doc3.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client3.id!, lamport: 2)
        ])

        // 01. Updates changes over snapshot threshold.
        for idx in 0 ..< (defaultSnapshotThreshold / 2) {
            try await doc1.update { root, _ in
                (root.t as? JSONText)?.edit(0, 0, "\(idx % 10)")
            }

            try await client1.sync()
            try await client2.sync()

            try await doc2.update { root, _ in
                (root.t as? JSONText)?.edit(0, 0, "\(idx % 10)")
            }

            try await client2.sync()
            try await client1.sync()
        }

        await assertTrue(versionVector: doc1.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1001),
            ActorData(actor: client2.id!, lamport: 1000)
        ])

        await assertTrue(versionVector: doc2.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 998),
            ActorData(actor: client2.id!, lamport: 1000)
        ])

        await assertTrue(versionVector: doc3.getVersionVector(), actorDatas: [
            ActorData(actor: client1.id!, lamport: 1),
            ActorData(actor: client3.id!, lamport: 2)
        ])

        // 02. Makes local changes then pull a snapshot from the server.
        try await doc3.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "c")
        }

        try await client3.sync()

        let vectors = await doc3.getVersionVector()
        await assertTrue(versionVector: vectors, actorDatas: [
            ActorData(actor: client1.id!, lamport: 998),
            ActorData(actor: client2.id!, lamport: 1000),
            ActorData(actor: ActorIDs.initial, lamport: 1002),
            ActorData(actor: client3.id!, lamport: 1003)
        ])

        try await client3.sync()

        var json3Count = (await doc3.getRoot().t as? JSONText)?.length ?? 0
        XCTAssertEqual(defaultSnapshotThreshold + 2, json3Count)

        // PASSED
        // 03. Delete text after receiving the snapshot.
        try await doc3.update { root, _ in
            (root.t as? JSONText)?.edit(1, 3, "")
        }

        json3Count = (await doc3.getRoot().t as? JSONText)?.length ?? 0

        XCTAssertEqual(defaultSnapshotThreshold, json3Count)

        try await client3.sync()
        try await client2.sync()
        try await client1.sync()

        let json2Count = (await doc2.getRoot().t as? JSONText)?.length ?? 0
        XCTAssertEqual(defaultSnapshotThreshold, json2Count)

        let json1Count = (await doc1.getRoot().t as? JSONText)?.length ?? 0
        XCTAssertEqual(defaultSnapshotThreshold, json1Count)

        try await client3.deactivate()
        try await client2.deactivate()
        try await client1.deactivate()
    }
}

// swiftlint:enable function_body_length type_body_length
