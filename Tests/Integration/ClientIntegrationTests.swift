/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

final class ClientIntegrationTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    func test_can_handle_sync() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: self.rpcAddress, options: options)
        let c2 = Client(rpcAddress: self.rpcAddress, options: options)

        let d1 = Document(key: docKey)
        try await d1.update { root, _ in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        let d2 = Document(key: docKey)
        try await d1.update { root, _ in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        try await c1.activate()
        try await c2.activate()

        try await c1.attach(d1, [:], false)
        try await c2.attach(d2, [:], false)

        try await d1.update { root, _ in
            root.k1 = "v1"
        }

        try await c1.sync()
        try await c2.sync()

        var result = await d2.getRoot().get(key: "k1") as? String
        XCTAssert(result == "v1")

        try await d1.update { root, _ in
            root.k2 = "v2"
        }

        try await c1.sync()
        try await c2.sync()

        result = await d2.getRoot().get(key: "k2") as? String
        XCTAssert(result == "v2")

        try await d1.update { root, _ in
            root.k3 = "v3"
        }

        try await c1.sync()
        try await c2.sync()

        result = await d2.getRoot().get(key: "k3") as? String
        XCTAssert(result == "v3")

        try await c1.detach(d1)
        try await c2.detach(d2)

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_can_handle_sync_auto() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: self.rpcAddress, options: options)
        let c2 = Client(rpcAddress: self.rpcAddress, options: options)

        let d1 = Document(key: docKey)
        try await d1.update { root, _ in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        let d2 = Document(key: docKey)
        try await d1.update { root, _ in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        try await c1.activate()
        try await c2.activate()

        try await c1.attach(d1)
        try await c2.attach(d2)

        try await d1.update { root, _ in
            root.k1 = "v1"
            root.k2 = "v2"
            root.k3 = "v3"
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        var result = await d2.getRoot().get(key: "k1") as? String
        XCTAssert(result == "v1")
        result = await d2.getRoot().get(key: "k2") as? String
        XCTAssert(result == "v2")
        result = await d2.getRoot().get(key: "k3") as? String
        XCTAssert(result == "v3")

        try await d1.update { root, _ in
            root.integer = Int32.max
            root.long = Int64.max
            root.double = Double.pi
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let resultInteger = await d2.getRoot().get(key: "integer") as? Int32
        XCTAssert(resultInteger == Int32.max)
        let resultLong = await d2.getRoot().get(key: "long") as? Int64
        XCTAssert(resultLong == Int64.max)
        let resultDouble = await d2.getRoot().get(key: "double") as? Double
        XCTAssert(resultDouble == Double.pi)

        let curr = Date()

        try await d1.update { root, _ in
            root.true = true
            root.false = false
            root.date = curr
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let resultTrue = await d2.getRoot().get(key: "true") as? Bool
        XCTAssert(resultTrue == true)
        let resultFalse = await d2.getRoot().get(key: "false") as? Bool
        XCTAssert(resultFalse == false)
        let resultDate = await d2.getRoot().get(key: "date") as? Date
        XCTAssert(resultDate?.trimedLessThanMilliseconds == curr.trimedLessThanMilliseconds)

        try await c1.detach(d1)
        try await c2.detach(d2)

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_stream_connection_evnts() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        var eventCount = 0

        c1.eventStream.sink { event in
            switch event {
            case let event as StreamConnectionStatusChangedEvent:
                eventCount += 1
                switch event.value {
                case .connected:
                    XCTAssertEqual(eventCount, 1)
                case .disconnected:
                    XCTAssertEqual(eventCount, 2)
                }
            default:
                break
            }
        }.store(in: &self.cancellables)

        try await c1.activate()

        let d1 = Document(key: docKey)

        try await c1.attach(d1)

        try await c1.detach(d1)
        try await c1.deactivate()

        XCTAssertEqual(eventCount, 2)
    }

    func test_client_pause_resume() async throws {
        let c1 = Client(rpcAddress: self.rpcAddress, options: ClientOptions())

        try await c1.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let d1 = Document(key: docKey)

        var c1NumberOfEvents = 0
        let c1ExpectedValues = [
            StreamConnectionStatus.connected,
            StreamConnectionStatus.disconnected,
            StreamConnectionStatus.connected,
            StreamConnectionStatus.disconnected
        ]

        c1.eventStream.sink { event in
            switch event {
            case let event as StreamConnectionStatusChangedEvent:
                XCTAssertEqual(event.value, c1ExpectedValues[c1NumberOfEvents])
                c1NumberOfEvents += 1
            default:
                break
            }
        }.store(in: &self.cancellables)

        try await c1.attach(d1)

        try await c1.pause(d1)

        try await c1.resume(d1)

        try await c1.detach(d1)

        try await c1.deactivate()
    }

    func test_should_apply_previous_changes_when_resuming_document() async throws {
        let c1 = Client(rpcAddress: self.rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: self.rpcAddress, options: ClientOptions())

        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        let exps = [self.expectation(description: "Exp 1"), self.expectation(description: "Exp 2"), self.expectation(description: "Exp 3")]
        var expCount = 0

        c2.eventStream.sink { event in
            if event.type == .documentSynced {
                exps[safe: expCount]?.fulfill()
                expCount += 1
            }
        }.store(in: &self.cancellables)

        // 01. c2 attach the doc with realtime sync mode at first.
        try await c1.attach(d1, [:], false)
        try await c2.attach(d2)
        try await d1.update { root, _ in
            root.version = "v1"
        }
        try await c1.sync()
        await fulfillment(of: [exps[0]], timeout: 1.5)

        var d1Doc = await d1.toSortedJSON()
        var d2Doc = await d2.toSortedJSON()

        XCTAssertEqual(d1Doc, "{\"version\":\"v1\"}")
        XCTAssertEqual(d2Doc, "{\"version\":\"v1\"}")

        // 02. c2 pauses realtime sync mode. So, c2 doesn't get the changes of c1
        try await c2.pause(d2)
        try await d1.update { root, _ in
            root.version = "v2"
        }
        try await c1.sync()

        d1Doc = await d1.toSortedJSON()
        d2Doc = await d2.toSortedJSON()

        XCTAssertEqual(d1Doc, "{\"version\":\"v2\"}")
        XCTAssertEqual(d2Doc, "{\"version\":\"v1\"}")

        // 03. c2 resumes realtime sync mode.
        // c2 should be able to apply changes made to the document while c2 is not in realtime sync.
        try await c2.resume(d2)
        await fulfillment(of: [exps[1]], timeout: 1.5)

        d2Doc = await d2.toSortedJSON()
        XCTAssertEqual(d2Doc, "{\"version\":\"v2\"}")

        // 04. c2 should automatically synchronize changes.
        try await d1.update { root, _ in
            root.version = "v3"
        }
        try await c1.sync()
        await fulfillment(of: [exps[2]], timeout: 1.5)

        d1Doc = await d1.toSortedJSON()
        d2Doc = await d2.toSortedJSON()

        XCTAssertEqual(d1Doc, "{\"version\":\"v3\"}")
        XCTAssertEqual(d2Doc, "{\"version\":\"v3\"}")

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_can_change_sync_mode_in_realtime_sync() async throws {
        let c1 = Client(rpcAddress: self.rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: self.rpcAddress, options: ClientOptions())
        let c3 = Client(rpcAddress: self.rpcAddress, options: ClientOptions())

        try await c1.activate()
        try await c2.activate()
        try await c3.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)
        let d3 = Document(key: docKey)

        // 01. c1, c2, c3 attach to the same document in realtime sync.
        try await c1.attach(d1)
        try await c2.attach(d2)
        try await c3.attach(d3)

        // 02. c1, c2 sync in realtime.
        try await d1.update { root, _ in
            root.c1 = Int64(0)
        }

        try await d2.update { root, _ in
            root.c2 = Int64(0)
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        var d1Doc = await d1.toSortedJSON()
        var d2Doc = await d2.toSortedJSON()

        XCTAssertEqual(d1Doc, "{\"c1\":0,\"c2\":0}")
        XCTAssertEqual(d2Doc, "{\"c1\":0,\"c2\":0}")

        // 03. c1 and c2 sync with push-only mode. So, the changes of c1 and c2
        // are not reflected to each other.
        // But, c can get the changes of c1 and c2, because c3 sync with push-pull mode.
        try await c1.pauseRemoteChanges(d1)
        try await c2.pauseRemoteChanges(d2)

        try await d1.update { root, _ in
            root.c1 = Int64(1)
        }

        try await d2.update { root, _ in
            root.c2 = Int64(1)
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        d1Doc = await d1.toSortedJSON()
        d2Doc = await d2.toSortedJSON()
        let d3Doc = await d3.toSortedJSON()

        XCTAssertEqual(d1Doc, "{\"c1\":1,\"c2\":0}")
        XCTAssertEqual(d2Doc, "{\"c1\":0,\"c2\":1}")
        XCTAssertEqual(d3Doc, "{\"c1\":1,\"c2\":1}")

        // 04. c1 and c2 sync with push-pull mode.
        try await c1.resumeRemoteChanges(d1)
        try await c2.resumeRemoteChanges(d2)

        try await Task.sleep(nanoseconds: 1_500_000_000)

        d1Doc = await d1.toSortedJSON()
        d2Doc = await d2.toSortedJSON()

        XCTAssertEqual(d1Doc, "{\"c1\":1,\"c2\":1}")
        XCTAssertEqual(d2Doc, "{\"c1\":1,\"c2\":1}")

        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }

    func test_can_be_built_from_a_snapshot() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, [:], false)
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, [:], false)

        let snapshotThreshold = 500

        try await doc1.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")]))
            root.text = JSONText()
        }

        for index in 0 ..< snapshotThreshold {
            try await doc1.update { root, _ in
                try (root.tree as? JSONTree)?.edit(0, 0, JSONTreeTextNode(value: "\(index),"))
                (root.text as? JSONText)?.edit(0, 0, "\(index),")
            }
        }

        try await c1.sync()
        try await c2.sync()

        let result1 = await doc1.toSortedJSON()
        let result2 = await doc2.toSortedJSON()

        XCTAssertEqual(result1, result2)
    }
}
