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

final class DocumentIntegrationTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    var c1: Client!
    var c2: Client!
    var d1: Document!
    var d2: Document!
    var d3: Document!

    func test_single_client_document_deletion() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)

        self.d1 = Document(key: docKey)

        // 01. client is not activated.
        do {
            try await self.c1.remove(self.d1)
        } catch {
            if case YorkieError.clientNotActive(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        // 02. document is not attached.
        do {
            try await self.c1.activate()
            try await self.c1.remove(self.d1)
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
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
            try await self.d1.update { root in
                root.k1 = String("v1")
            }
        } catch {
            if case YorkieError.documentRemoved = error {
            } else {
                XCTAssert(false)
            }
        }

        // 05. try to attach a removed document.
        do {
            try await self.c1.attach(self.d1)
        } catch {
            if case YorkieError.documentNotDetached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        try await self.c1.deactivate()
    }

    func test_removed_document_creation() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 create d1 and remove it.
        try await self.d1.update { root in
            root.k1 = "v1"
        }

        try await self.c1.attach(self.d1)
        try await self.c1.detach(self.d1) // remove(self.d1)

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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 creates d1 and c2 syncs.
        try await self.d1.update { root in
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
        try await self.d1.update { root in
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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 creates d1 and c2 syncs.
        try await self.d1.update { root in
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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)

        // 01. c1 creates d1 and c2 syncs.
        try await self.d1.update { root in
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
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)

        try await self.c1.activate()

        // 01. abnormal behavior on  detached state
        self.d1 = Document(key: docKey)

        do {
            try await self.c1.detach(self.d1)
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.sync()
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.remove(self.d1)
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        // 02. abnormal behavior on attached state
        try await self.c1.attach(self.d1)

        do {
            try await self.c1.attach(self.d1)
        } catch {
            if case YorkieError.documentNotDetached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        // 03. abnormal behavior on removed state
        try await self.c1.remove(self.d1)

        do {
            try await self.c1.remove(self.d1)
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.sync()
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        do {
            try await self.c1.detach(self.d1)
        } catch {
            if case YorkieError.documentNotAttached(message:) = error {
            } else {
                XCTAssert(false)
            }
        }

        try await self.c1.deactivate()
    }

    func test_specify_the_topic_to_subscribe_to() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        try await self.c1.activate()
        try await self.c2.activate()

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.attach(self.d1)
        try await self.c2.attach(self.d2)

        var d1Events = [any OperationInfo]()
        var d2Events = [any OperationInfo]()
        var d3Events = [any OperationInfo]()

        await self.d1.subscribe { event in
            d1Events.append(contentsOf: (event as? ChangeEvent)?.value.operations ?? [])
        }

        await self.d1.subscribe("$.todos") { event in
            d2Events.append(contentsOf: (event as? ChangeEvent)?.value.operations ?? [])
        }

        await self.d1.subscribe("$.counter") { event in
            d3Events.append(contentsOf: (event as? ChangeEvent)?.value.operations ?? [])
        }

        try await self.d2.update { root in
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

        try await self.d2.update { root in
            (root.counter as? JSONCounter<Int32>)?.increase(value: 10)
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? IncreaseOpInfo, IncreaseOpInfo(path: "$.counter", value: 10))
        XCTAssertEqual(d3Events[0] as? IncreaseOpInfo, IncreaseOpInfo(path: "$.counter", value: 10))

        d1Events = []
        d3Events = []

        try await self.d2.update { root in
            (root.todos as? JSONArray)?.append("todo3")
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 2))
        XCTAssertEqual(d2Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 2))

        d1Events = []
        d2Events = []

        await self.d1.unsubscribe("$.todos")

        try await self.d2.update { root in
            (root.todos as? JSONArray)?.append("todo4")
        }

        // Wait sync.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(d1Events[0] as? AddOpInfo, AddOpInfo(path: "$.todos", index: 3))
        XCTAssertTrue(d2Events.isEmpty)

        d1Events = []

        await self.d1.unsubscribe("$.counter")

        try await self.d2.update { root in
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
}
