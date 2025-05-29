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

import Combine
import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

final class DocumentIntegrationTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    let rpcAddress = "http://localhost:8080"

    var c1: Client!
    var c2: Client!
    var d1: Document!
    var d2: Document!
    var d3: Document!

    func test_single_client_document_deletion() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress, options)

        self.d1 = Document(key: docKey)

        // 01. client is not activated.
        do {
            try await self.c1.remove(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errClientNotActivated = error.code {
            } else {
                XCTAssert(false)
            }
        }

        // 02. document is not attached.
        do {
            try await self.c1.activate()
            try await self.c1.remove(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        // 03. document is attached.
        do {
            try await self.c1.attach(self.d1)
            try await self.c1.remove(self.d1)
        } catch {
            XCTAssert(false)
        }

        let docStatus = await self.d1.status

        XCTAssertEqual(docStatus, .removed)

        // 04. try to update a removed document.
        do {
            try await self.d1.update { root, _ in
                root.k1 = String("v1")
            }
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentRemoved = error.code {
            } else {
                XCTAssert(false)
            }
        }

        // 05. try to attach a removed document.
        do {
            try await self.c1.attach(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotDetached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        try await self.c1.deactivate()
    }

    func test_removed_document_creation() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 create d1 and remove it.
        try await self.d1.update { root, _ in
            root.k1 = "v1"
        }

        try await self.c1.attach(self.d1)
        try await self.c1.remove(self.d1)

        // 02. c2 creates d2 with the same key.
        self.d2 = Document(key: docKey)

        try await self.c2.attach(self.d2)

        // 03. c1 creates d3 with the same key.
        self.d3 = Document(key: docKey)
        try await self.c1.attach(self.d3)

        let doc2Content = await d2.toSortedJSON()
        let doc3Content = await d3.toSortedJSON()

        XCTAssertEqual(doc2Content, doc3Content)

        try await self.c1.detach(self.d2)
        try await self.c2.detach(self.d3)

        try await self.c1.deactivate()
        try await self.c1.deactivate()
    }

    func test_removed_document_pushpull() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 creates d1 and c2 syncs.
        try await self.d1.update { root, _ in
            root.k1 = "v1"
        }

        try await self.c1.attach(self.d1)

        self.d2 = Document(key: docKey)

        try await self.c2.attach(self.d2)

        try await self.c1.sync()
        try await self.c2.sync()

        let doc1Content = await d1.toSortedJSON()
        let doc2Content = await d2.toSortedJSON()

        XCTAssertEqual(doc1Content, doc2Content)

        // 02. c1 updates d1 and removes it.
        try await self.d1.update { root, _ in
            root.k1 = "v2"
        }

        try await self.c1.remove(self.d1)

        // 03. c2 syncs and checks that d2 is removed.
        try await self.c2.sync()

        let doc1Status = await d1.status
        let doc2Status = await d2.status

        XCTAssertEqual(doc1Status, doc2Status)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func test_removed_document_detachment() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 creates d1 and c2 syncs.
        try await self.d1.update { root, _ in
            root.k1 = "v1"
        }

        try await self.c1.attach(self.d1)

        self.d2 = Document(key: docKey)

        try await self.c2.attach(self.d2)

        try await self.c1.sync()
        try await self.c2.sync()

        let doc1Content = await d1.toSortedJSON()
        let doc2Content = await d2.toSortedJSON()

        XCTAssertEqual(doc1Content, doc2Content)

        // 02. c1 removes d1 and c1 detaches d2
        try await self.c1.remove(self.d1)
        try await self.c2.detach(self.d2)

        let doc1Status = await d1.status
        let doc2Status = await d2.status

        XCTAssertEqual(doc1Status, .removed)
        XCTAssertEqual(doc2Status, .removed)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func test_removed_document_removal() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 creates d1 and c2 syncs.
        try await self.d1.update { root, _ in
            root.k1 = "v1"
        }

        try await self.c1.attach(self.d1)

        self.d2 = Document(key: docKey)

        try await self.c2.attach(self.d2)

        try await self.c1.sync()
        try await self.c2.sync()

        let doc1Content = await d1.toSortedJSON()
        let doc2Content = await d2.toSortedJSON()

        XCTAssertEqual(doc1Content, doc2Content)

        // 02. c1 removes d1 and c1 removes d2
        try await self.c1.remove(self.d1)
        try await self.c2.remove(self.d2)

        let doc1Status = await d1.status
        let doc2Status = await d2.status

        XCTAssertEqual(doc1Status, .removed)
        XCTAssertEqual(doc2Status, .removed)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    // State transition of document
    // ┌──────────┐ Attach ┌──────────┐ Remove ┌─────────┐
    // │ Detached ├───────►│ Attached ├───────►│ Removed │
    // └──────────┘        └─┬─┬──────┘        └─────────┘
    //           ▲           │ │     ▲
    //           └───────────┘ └─────┘
    //              Detach     PushPull
    func test_document_state_transition() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)

        try await self.c1.activate()

        // 01. abnormal behavior on  detached state
        self.d1 = Document(key: docKey)

        do {
            try await self.c1.detach(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.sync()
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.remove(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        // 02. abnormal behavior on attached state
        try await self.c1.attach(self.d1)

        do {
            try await self.c1.attach(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotDetached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        // 03. abnormal behavior on removed state
        try await self.c1.remove(self.d1)

        do {
            try await self.c1.remove(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.sync()
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.detach(self.d1)
        } catch let error as YorkieError {
            if case YorkieError.Code.errDocumentNotAttached = error.code {
            } else {
                XCTAssert(false)
            }
        }

        try await self.c1.deactivate()
    }

    func test_specify_the_topic_to_subscribe_to() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.attach(self.d1)
        try await self.c2.attach(self.d2)

        var d1Events = [any OperationInfo]()
        var d2Events = [any OperationInfo]()
        var d3Events = [any OperationInfo]()

        await self.d1.subscribe { event, _ in
            d1Events.append(contentsOf: (event as? ChangeEvent)?.value.operations ?? [])
        }

        await self.d1.subscribe("$.todos") { event, _ in
            d2Events.append(contentsOf: (event as? ChangeEvent)?.value.operations ?? [])
        }

        await self.d1.subscribe("$.counter") { event, _ in
            d3Events.append(contentsOf: (event as? ChangeEvent)?.value.operations ?? [])
        }

        try await self.d2.update { root, _ in
            root.counter = JSONCounter(value: Int32(0))
            root.todos = ["todo1", "todo2"]
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? SetOpInfo, SetOpInfo(path: "$", key: "counter"))
        XCTAssertEqual(d1Events[1] as? SetOpInfo, SetOpInfo(path: "$", key: "todos"))
        XCTAssertEqual(d1Events[2] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 0))
        XCTAssertEqual(d1Events[3] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 1))
        XCTAssertEqual(d2Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 0))
        XCTAssertEqual(d2Events[1] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 1))

        d1Events = []
        d2Events = []

        try await self.d2.update { root, _ in
            (root.counter as? JSONCounter<Int32>)?.increase(value: 10)
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? IncreaseOpInfo, IncreaseOpInfo(path: "$.counter", value: 10))
        XCTAssertEqual(d3Events[0] as? IncreaseOpInfo, IncreaseOpInfo(path: "$.counter", value: 10))

        d1Events = []
        d3Events = []

        try await self.d2.update { root, _ in
            (root.todos as? JSONArray)?.append("todo3")
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 2))
        XCTAssertEqual(d2Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 2))

        d1Events = []
        d2Events = []

        await self.d1.unsubscribe("$.todos")

        try await self.d2.update { root, _ in
            (root.todos as? JSONArray)?.append("todo4")
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 3))
        XCTAssertTrue(d2Events.isEmpty)

        d1Events = []

        await self.d1.unsubscribe("$.counter")

        try await self.d2.update { root, _ in
            (root.counter as? JSONCounter<Int32>)?.increase(value: 10)
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? IncreaseOpInfo, IncreaseOpInfo(path: "$.counter", value: 10))
        XCTAssertTrue(d3Events.isEmpty)

        await self.d1.unsubscribe()

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func test_subscribe_document_status_changed_event() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        let eventCollectorD1 = EventCollector<DocStatus>(doc: d1)
        let eventCollectorD2 = EventCollector<DocStatus>(doc: d2)
        await eventCollectorD1.subscribeDocumentStatus()
        await eventCollectorD2.subscribeDocumentStatus()

        // 1. When the client attaches a document, it receives an attached event.
        try await c1.attach(d1)
        try await c2.attach(d2)

        // 2. When c1 detaches a document, it receives a detached event.
        try await c1.detach(d1)

        // 3. When c2 deactivates, it should also receive a detached event.
        try await c2.deactivate()

        await eventCollectorD1.verifyNthValue(at: 1, isEqualTo: .attached)
        await eventCollectorD1.verifyNthValue(at: 2, isEqualTo: .detached)

        await eventCollectorD2.verifyNthValue(at: 1, isEqualTo: .attached)
        await eventCollectorD2.verifyNthValue(at: 2, isEqualTo: .detached)

        // 4. When other document is attached, it receives an attached event.
        let docKey2 = "\(self.description)-\(Date().description)".toDocKey
        let d3 = Document(key: docKey2)
        let d4 = Document(key: docKey2)
        let eventCollectorD3 = EventCollector<DocStatus>(doc: d3)
        let eventCollectorD4 = EventCollector<DocStatus>(doc: d4)
        await eventCollectorD3.subscribeDocumentStatus()
        await eventCollectorD4.subscribeDocumentStatus()

        try await c1.attach(d3, [:], .manual)

        try await c2.activate()
        try await c2.attach(d4, [:], .manual)

        // 5. When c1 removes a document, it receives a removed event.
        try await c1.remove(d3)

        // 6. When c2 syncs, it should also receive a removed event.
        try await c2.sync()

        await eventCollectorD3.verifyNthValue(at: 1, isEqualTo: .attached)
        await eventCollectorD3.verifyNthValue(at: 2, isEqualTo: .removed)

        await eventCollectorD4.verifyNthValue(at: 1, isEqualTo: .attached)
        await eventCollectorD4.verifyNthValue(at: 2, isEqualTo: .removed)

        // 7. If the document is in the removed state, a detached event should not occur when deactivating.
        let eventCount3 = eventCollectorD3.count
        let eventCount4 = eventCollectorD4.count
        try await c1.deactivate()
        try await c2.deactivate()

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(eventCount3, eventCollectorD3.count)
        XCTAssertEqual(eventCount4, eventCollectorD4.count)
    }

    func test_document_status_changes_to_detached_when_deactivating() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        let eventCollectorD1 = EventCollector<DocStatus>(doc: d1)
        let eventCollectorD2 = EventCollector<DocStatus>(doc: d2)
        await eventCollectorD1.subscribeDocumentStatus()
        await eventCollectorD2.subscribeDocumentStatus()

        // 1. When the client attaches a document, it receives an attached event.
        try await c1.attach(d1, [:], .manual)
        try await c2.attach(d2, [:], .manual)

        await eventCollectorD1.verifyNthValue(at: 1, isEqualTo: .attached)
        await eventCollectorD2.verifyNthValue(at: 1, isEqualTo: .attached)

        // 2. When c1 removes a document, it receives a removed event.
        try await c1.remove(d1)
        await eventCollectorD1.verifyNthValue(at: 2, isEqualTo: .removed)

        // 3. When c2 deactivates, it should also receive a removed event.
        try await c2.deactivate()
        // NOTE: For now, document status changes to `Detached` when deactivating.
        // This behavior may change in the future.
        await eventCollectorD2.verifyNthValue(at: 2, isEqualTo: .detached)

        try await c1.deactivate()
    }

    func test_document_with_initialRoot() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        // 01. attach and initialize document
        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, initialRoot: [
            "counter": JSONCounter(value: Int32(0)),
            "content": [
                "x": Int32(1),
                "y": Int32(1)
            ]
        ])

        let doc1JSON = await doc1.toSortedJSON()
        XCTAssertEqual(doc1JSON, "{\"content\":{\"x\":1,\"y\":1},\"counter\":0}")

        try await c1.sync()

        // 02. attach and initialize document with new fields and if key already exists, it will be discarded
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, initialRoot: [
            "counter": JSONCounter(value: Int32(1)),
            "content": [
                "x": Int32(1),
                "y": Int32(2)
            ],
            "new": ["k": "v"]
        ])

        let doc2JSON = await doc2.toSortedJSON()
        XCTAssertEqual(doc2JSON, "{\"content\":{\"x\":1,\"y\":1},\"counter\":0,\"new\":{\"k\":\"v\"}}")

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_can_handle_concurrent_attach_with_initialRoot() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        // 01. user1 attach with initialRoot and client doesn't sync
        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, initialRoot: [
            "writer": "user1"
        ])
        var doc1JSON = await doc1.toSortedJSON()
        XCTAssertEqual(doc1JSON, "{\"writer\":\"user1\"}")

        // 02. user2 attach with initialRoot and client doesn't sync
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, initialRoot: [
            "writer": "user2"
        ])
        var doc2JSON = await doc2.toSortedJSON()
        XCTAssertEqual(doc2JSON, "{\"writer\":\"user2\"}")

        // 03. user1 sync first and user2 seconds
        try await c1.sync()
        try await c2.sync()

        // 04. user1's local document's writer was user1
        doc1JSON = await doc1.toSortedJSON()
        XCTAssertEqual(doc1JSON, "{\"writer\":\"user1\"}")
        doc2JSON = await doc2.toSortedJSON()
        XCTAssertEqual(doc2JSON, "{\"writer\":\"user2\"}")

        // 05. user1's local document's writer is overwritten by user2
        try await c1.sync()
        doc1JSON = await doc2.toSortedJSON()
        XCTAssertEqual(doc1JSON, "{\"writer\":\"user2\"}")

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_can_support_various_types() async throws {
        struct TestCase {
            let name: String
            let input: JSONValuable?
            let expectedJSON: String
        }

        let testCases: [TestCase] = [
            TestCase(name: "tree",
                     input:
                     JSONTree(initialRoot: JSONTreeElementNode(type: "doc",
                                                               children: [
                                                                   JSONTreeElementNode(type: "p", children: [
                                                                       JSONTreeTextNode(value: "ab")
                                                                   ])
                                                               ])),
                     expectedJSON: "{\"tree\":{\"children\":[{\"children\":[{\"type\":\"text\",\"value\":\"ab\"}],\"type\":\"p\"}],\"type\":\"doc\"}}"),
            TestCase(name: "text",
                     input: JSONText(),
                     expectedJSON: "{\"text\":[]}"),
            TestCase(name: "counter",
                     input: JSONCounter(value: Int32(1)),
                     expectedJSON: "{\"counter\":1}"),
            TestCase(name: "null",
                     input: nil,
                     expectedJSON: "{\"null\":null}"),
            TestCase(name: "boolean",
                     input: true,
                     expectedJSON: "{\"boolean\":true}"),
            TestCase(name: "number",
                     input: Int32(1),
                     expectedJSON: "{\"number\":1}"),
            TestCase(name: "long",
                     input: Int64.max,
                     expectedJSON: "{\"long\":9223372036854775807}"),
            TestCase(name: "object",
                     input: [
                         "k": "v"
                     ],
                     expectedJSON: "{\"object\":{\"k\":\"v\"}}"),
            TestCase(name: "array",
                     input: [Int32(1), Int32(2)],
                     expectedJSON: "{\"array\":[1,2]}"),
            // TODO(hackerwins): We need to consider the case where the value is
            // a byte array and a date.
            TestCase(name: "bytes",
                     input: Data([UInt8]([1, 2])),
                     expectedJSON: "{\"bytes\":[1,2]}")
        ]

        for testCase in testCases {
            let c1 = Client(rpcAddress)
            try await c1.activate()
            let docKey = "\(self.description)-\(Date().description)".toDocKey

            let doc = Document(key: docKey)
            try await c1.attach(doc, initialRoot: [
                testCase.name: testCase.input
            ])

            let docJSON = await doc.toSortedJSON()
            XCTAssertEqual(docJSON, testCase.expectedJSON)

            try await c1.deactivate()
        }
    }

    // This test was moved to the integration tests for the Yorkie server, but it remains a unit test in yorkie-js-sdk.
    func test_should_publish_snapshot_event_with_up_to_date_document() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            let eventCollector = EventCollector<Int32>(doc: d2)

            await d2.subscribe("$") { event, doc in
                if event.type == .snapshot {
                    if let value = (doc.getRoot().counter as? JSONCounter<Int32>)?.value as? Int32 {
                        eventCollector.add(event: value)
                    }
                }
            }

            try await d1.update { root, _ in
                root.counter = JSONCounter(value: Int32(0))
            }
            try await c1.sync()
            try await c2.sync()

            // 01. c1 increases the counter for creating snapshot.
            for _ in 1 ... defaultSnapshotThreshold {
                try await d1.update { root, _ in
                    (root.counter as? JSONCounter<Int32>)?.increase(value: 1)
                }
            }
            try await c1.sync()

            // 02. c2 receives the snapshot and increases the counter simultaneously.
            try await d2.update { root, _ in
                (root.counter as? JSONCounter<Int32>)?.increase(value: 1)
            }
            // should have a local change after receiving a snapshot event
            Task {
                try await c2.sync()
            }

            let targetValue = Int32(defaultSnapshotThreshold + 1)
            for await _ in eventCollector.waitStream(until: targetValue) {
                await eventCollector.verifyNthValue(at: 1, isEqualTo: targetValue)
            }
        }
    }
}
