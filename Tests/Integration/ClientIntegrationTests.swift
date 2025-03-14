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
import Connect
import XCTest
@testable import Yorkie

final class ClientIntegrationTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    let rpcAddress = "http://localhost:8080"

    func test_can_be_activated_decativated() async throws {
        var options = ClientOptions()
        let clientKey = "\(self.description)-\(Date().description)"
        options.key = clientKey
        options.syncLoopDuration = 50
        options.reconnectStreamDelay = 1000

        let clientWithKey = Client(self.rpcAddress, options)

        var boolResult = await clientWithKey.isActive
        XCTAssertFalse(boolResult)
        try await clientWithKey.activate()
        boolResult = await clientWithKey.isActive
        XCTAssertTrue(boolResult)
        var key = clientWithKey.key
        XCTAssertEqual(key, clientKey)
        try await clientWithKey.deactivate()
        boolResult = await clientWithKey.isActive
        XCTAssertFalse(boolResult)

        let clientWithoutKey = Client(self.rpcAddress)

        boolResult = await clientWithoutKey.isActive
        XCTAssertFalse(boolResult)
        try await clientWithoutKey.activate()
        boolResult = await clientWithoutKey.isActive
        XCTAssertTrue(boolResult)
        key = clientWithoutKey.key
        XCTAssertEqual(key.count, 36)
        try await clientWithoutKey.deactivate()
        boolResult = await clientWithoutKey.isActive
        XCTAssertFalse(boolResult)
    }

    func test_can_attach_detach_document() async throws {
        let client = Client(rpcAddress)
        try await client.activate()
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)

        try await client.attach(doc)
        do {
            try await client.attach(doc)
        } catch {
            guard let code = toYorkieErrorCode(from: error) else {
                XCTFail("error should be ConnectError, but \(type(of: error))")
                return
            }
            XCTAssert(code == YorkieError.Code.errDocumentNotDetached)
        }

        try await client.detach(doc)
        do {
            try await client.detach(doc)
        } catch {
            guard let code = toYorkieErrorCode(from: error) else {
                XCTFail("error should be ConnectError, but \(type(of: error))")
                return
            }
            XCTAssert(code == YorkieError.Code.errDocumentNotAttached)
        }

        try await client.deactivate()
        try await client.deactivate()
    }

    func test_can_handle_sync() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = "v1"
            }

            try await c1.sync()
            try await c2.sync()

            var d1JSON = await d1.toSortedJSON()
            var d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                root.k2 = "v2"
            }

            try await c1.sync()
            try await c2.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)

            try await d1.update { root, _ in
                root.k3 = "v3"
            }

            try await c1.sync()
            try await c2.sync()

            d1JSON = await d1.toSortedJSON()
            d2JSON = await d2.toSortedJSON()

            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    /*
     func test_can_recover_from_temporary_disconnect_realtime_sync() async throws {
         let c1 = Client(rpcAddress)
         let c2 = Client(rpcAddress)
         try await c1.activate()
         try await c2.activate()

         let docKey = "\(self.description)-\(Date().description)".toDocKey
         let d1 = Document(key: docKey)
         let d2 = Document(key: docKey)

         try await c1.attach(d1)
         try await c2.attach(d2)

         let d1Exp = self.expectation(description: "D1 exp 1")
         let d2Exp = self.expectation(description: "D2 exp 1")

         var d1EventCount = 0
         var d2EventCount = 0

         await d1.subscribe { event, _ in
             d1EventCount += 1

             if event is RemoteChangeEvent {
                 d1Exp.fulfill()
             }
         }

         await d2.subscribe { event, _ in
             d2EventCount += 1

             if event is LocalChangeEvent {
                 d2Exp.fulfill()
             }
         }

         // Normal Condition
         try await d2.update { root, _ in
             root.k1 = "undefined"
         }

         await fulfillment(of: [d1Exp, d2Exp], timeout: 5)

         var d1JSON = await d1.toSortedJSON()
         var d2JSON = await d2.toSortedJSON()

         XCTAssertEqual(d1JSON, d2JSON)
     }
     */

    func test_can_change_sync_mode_realtime_manual() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        // 01. c1 and c2 attach the doc with manual sync mode.
        //     c1 updates the doc, but c2 does't get until call sync manually.
        try await c1.attach(d1, [:], .manual)
        try await c2.attach(d2, [:], .manual)

        try await d1.update { root, _ in
            root.version = "v1"
        }

        var d1JSON = await d1.toSortedJSON()
        var d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"version\":\"v1\"}")
        XCTAssertEqual(d2JSON, "{}")

        try await c1.sync()
        try await c2.sync()

        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d2JSON, "{\"version\":\"v1\"}")

        // 02. c2 changes the sync mode to realtime sync mode.
        let c2Exp1 = expectation(description: "C2 Exp")

        await d2.subscribeSync { event, _ in
            if let event = event as? SyncStatusChangedEvent, event.value == .synced {
                c2Exp1.fulfill()
            }
        }

        try await c2.changeSyncMode(d2, .realtime)
        await fulfillment(of: [c2Exp1], timeout: 5) // sync occurs when resuming

        await d2.unsubscribeSync()

        let c2Exp2 = expectation(description: "C2 Exp 2")

        await d2.subscribeSync { event, _ in
            if let event = event as? SyncStatusChangedEvent, event.value == .synced {
                c2Exp2.fulfill()
            }
        }

        try await d1.update { root, _ in
            root.version = "v2"
        }

        try await c1.sync()

        await fulfillment(of: [c2Exp2], timeout: 5)

        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"version\":\"v2\"}")
        XCTAssertEqual(d2JSON, "{\"version\":\"v2\"}")

        await d2.unsubscribeSync()

        // 03. c2 changes the sync mode to manual sync mode again.
        try await c2.changeSyncMode(d2, .manual)
        try await d1.update { root, _ in
            root.version = "v3"
        }
        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"version\":\"v3\"}")
        XCTAssertEqual(d2JSON, "{\"version\":\"v2\"}")

        try await c1.sync()
        try await c2.sync()
        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d2JSON, "{\"version\":\"v3\"}")

        try await c1.deactivate()
        try await c2.deactivate()
    }

    // swiftlint: disable function_body_length
    func test_can_change_sync_mode_in_realtime() async throws {
        // |    | Step1    | Step2    | Step3    | Step4    |
        // | c1 | PushPull | PushOnly | SyncOff  | PushPull |
        // | c2 | PushPull | SyncOff  | PushOnly | PushPull |
        // | c3 | PushPull | PushPull | PushPull | PushPull |

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        let c3 = Client(rpcAddress)
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

        let expectedEvents1: [DocEventType] = [.localChange, .remoteChange, .remoteChange, .localChange, .localChange, .remoteChange, .remoteChange, .remoteChange, .remoteChange]
        let expectedEvents2: [DocEventType] = [.localChange, .remoteChange, .remoteChange, .localChange, .localChange, .remoteChange, .remoteChange, .remoteChange, .remoteChange]
        let expectedEvents3: [DocEventType] = [.localChange, .remoteChange, .remoteChange, .localChange, .remoteChange, .localChange, .remoteChange, .remoteChange, .remoteChange]
        let d1Exp1 = expectation(description: "D1 Exp 1")
        let d2Exp1 = expectation(description: "D2 Exp 1")
        let d3Exp1 = expectation(description: "D3 Exp 1")
        let d1Exp2 = expectation(description: "D1 Exp 2")
        let d2Exp2 = expectation(description: "D2 Exp 2")
        let d3Exp2 = expectation(description: "D3 Exp 2")
        let d1Exp3 = expectation(description: "D1 Exp 3")
        let d2Exp3 = expectation(description: "D2 Exp 3")
        let d3Exp3 = expectation(description: "D3 Exp 3")
        let d1Exp4 = expectation(description: "D1 Exp 4")
        let d2Exp4 = expectation(description: "D2 Exp 4")
        let d3Exp4 = expectation(description: "D3 Exp 4")

        var d1EventCount = 0
        var d2EventCount = 0
        var d3EventCount = 0

        await d1.subscribe { event, _ in
            guard event is ChangeEvent else {
                return
            }
            XCTAssertEqual(event.type, expectedEvents1[d1EventCount])
            d1EventCount += 1

            if d1EventCount == 3 {
                d1Exp1.fulfill()
            }
            if d1EventCount == 4 {
                d1Exp2.fulfill()
            }
            if d1EventCount == 5 {
                d1Exp3.fulfill()
            }
            if d1EventCount == 9 {
                d1Exp4.fulfill()
            }
        }

        await d2.subscribe { event, _ in
            guard event is ChangeEvent else {
                return
            }

            XCTAssertEqual(event.type, expectedEvents2[d2EventCount])
            d2EventCount += 1

            if d2EventCount == 3 {
                d2Exp1.fulfill()
            }
            if d2EventCount == 4 {
                d2Exp2.fulfill()
            }
            if d2EventCount == 5 {
                d2Exp3.fulfill()
            }
            if d2EventCount == 9 {
                d2Exp4.fulfill()
            }
        }

        await d3.subscribe { event, _ in
            guard event is ChangeEvent else {
                return
            }

            XCTAssertEqual(event.type, expectedEvents3[d3EventCount])
            d3EventCount += 1

            if d3EventCount == 3 {
                d3Exp1.fulfill()
            }
            if d3EventCount == 5 {
                d3Exp2.fulfill()
            }
            if d3EventCount == 8 {
                d3Exp3.fulfill()
            }
            if d3EventCount == 9 {
                d3Exp4.fulfill()
            }
        }

        // 02. [Step1] c1, c2, c3 sync in realtime.
        try await d1.update { root, _ in
            root.c1 = Int64(0)
        }
        try await d2.update { root, _ in
            root.c2 = Int64(0)
        }
        try await d3.update { root, _ in
            root.c3 = Int64(0)
        }

        await fulfillment(of: [d1Exp1, d2Exp1, d3Exp1], timeout: 5)

        var d1JSON = await d1.toSortedJSON()
        var d2JSON = await d2.toSortedJSON()
        var d3JSON = await d3.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"c1\":0,\"c2\":0,\"c3\":0}")
        XCTAssertEqual(d2JSON, "{\"c1\":0,\"c2\":0,\"c3\":0}")
        XCTAssertEqual(d3JSON, "{\"c1\":0,\"c2\":0,\"c3\":0}")

        // 03. [Step2] c1 sync with push-only mode, c2 sync with sync-off mode.
        // c3 can get the changes of c1 and c2, because c3 sync with push-pull mode.
        try await c1.changeSyncMode(d1, .realtimePushOnly)
        try await c2.changeSyncMode(d2, .realtimeSyncOff)
        try await d1.update { root, _ in
            root.c1 = Int64(1)
        }
        try await d2.update { root, _ in
            root.c2 = Int64(1)
        }
        try await d3.update { root, _ in
            root.c3 = Int64(1)
        }

        await fulfillment(of: [d1Exp2, d2Exp2, d3Exp2], timeout: 5)

        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        d3JSON = await d3.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"c1\":1,\"c2\":0,\"c3\":0}")
        XCTAssertEqual(d2JSON, "{\"c1\":0,\"c2\":1,\"c3\":0}")
        XCTAssertEqual(d3JSON, "{\"c1\":1,\"c2\":0,\"c3\":1}")

        // 04. [Step3] c1 sync with sync-off mode, c2 sync with push-only mode.
        try await c1.changeSyncMode(d1, .realtimeSyncOff)
        try await c2.changeSyncMode(d2, .realtimePushOnly)
        try await d1.update { root, _ in
            root.c1 = Int64(2)
        }
        try await d2.update { root, _ in
            root.c2 = Int64(2)
        }
        try await d3.update { root, _ in
            root.c3 = Int64(2)
        }

        await fulfillment(of: [d1Exp3, d2Exp3, d3Exp3], timeout: 5)

        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        d3JSON = await d3.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"c1\":2,\"c2\":0,\"c3\":0}")
        XCTAssertEqual(d2JSON, "{\"c1\":0,\"c2\":2,\"c3\":0}")
        XCTAssertEqual(d3JSON, "{\"c1\":1,\"c2\":2,\"c3\":2}")

        // 05. [Step4] c1 and c2 sync with push-pull mode.
        try await c1.changeSyncMode(d1, .realtime)
        try await c2.changeSyncMode(d2, .realtime)

        await fulfillment(of: [d1Exp4, d2Exp4, d3Exp4], timeout: 5)

        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        d3JSON = await d3.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"c1\":2,\"c2\":2,\"c3\":2}")
        XCTAssertEqual(d2JSON, "{\"c1\":2,\"c2\":2,\"c3\":2}")
        XCTAssertEqual(d3JSON, "{\"c1\":2,\"c2\":2,\"c3\":2}")

        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }

    // swiftlint: enable function_body_length

    func test_should_apply_previous_changes_when_switching_to_realtime_sync() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        let exp1 = expectation(description: "exp 1")
        await d2.subscribeSync { event, _ in
            if let event = event as? SyncStatusChangedEvent, event.value == .synced {
                exp1.fulfill()
            }
        }

        // 01. c2 attach the doc with realtime sync mode at first.
        try await c1.attach(d1, [:], .manual)
        try await c2.attach(d2)

        try await d1.update { root, _ in
            root.version = "v1"
        }

        try await c1.sync()

        var d1JSON = await d1.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"version\":\"v1\"}")

        await fulfillment(of: [exp1], timeout: 5)

        var d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d2JSON, "{\"version\":\"v1\"}")

        // 02. c2 is changed to manual sync. So, c2 doesn't get the changes of c1.
        try await c2.changeSyncMode(d2, .manual)
        try await d1.update { root, _ in
            root.version = "v2"
        }
        try await c1.sync()
        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"version\":\"v2\"}")
        XCTAssertEqual(d2JSON, "{\"version\":\"v1\"}")

        // 03. c2 is changed to realtime sync.
        // c2 should be able to apply changes made to the document while c2 is not in realtime sync.
        await d2.unsubscribeSync()

        let exp2 = expectation(description: "exp 2")

        await d2.subscribeSync { event, _ in
            if let event = event as? SyncStatusChangedEvent, event.value == .synced {
                exp2.fulfill()
            }
        }

        try await c2.changeSyncMode(d2, .realtime)

        await fulfillment(of: [exp2], timeout: 5)

        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d2JSON, "{\"version\":\"v2\"}")

        // 04. c2 should automatically synchronize changes.
        await d2.unsubscribeSync()

        let exp3 = expectation(description: "exp 3")

        await d2.subscribeSync { event, _ in
            if let event = event as? SyncStatusChangedEvent, event.value == .synced {
                exp3.fulfill()
            }
        }

        try await d1.update { root, _ in
            root.version = "v3"
        }
        try await c1.sync()

        await fulfillment(of: [exp3], timeout: 5)

        d1JSON = await d1.toSortedJSON()
        d2JSON = await d2.toSortedJSON()
        XCTAssertEqual(d1JSON, "{\"version\":\"v3\"}")
        XCTAssertEqual(d2JSON, "{\"version\":\"v3\"}")

        await d2.unsubscribeSync()

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_should_not_include_changes_applied_in_push_only_mode_when_switching_to_realtime_sync() async throws {
        let c1 = Client(rpcAddress)
        try await c1.activate()

        let docKey = "\(Date().description)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)

        try await c1.attach(d1, [:], .manual)

        // 02. cli update the document with creating a counter
        //     and sync with push-pull mode: CP(1, 1) -> CP(2, 2)
        try await d1.update { root, _ in
            root.counter = JSONCounter(value: Int64(0))
        }

        var checkpoint = await d1.checkpoint
        XCTAssertEqual(checkpoint.getClientSeq(), 1)
        XCTAssertEqual(checkpoint.getServerSeq(), 1)

        try await c1.sync()
        checkpoint = await d1.checkpoint
        XCTAssertEqual(checkpoint.getClientSeq(), 2)
        XCTAssertEqual(checkpoint.getServerSeq(), 2)

        // 03. cli update the document with increasing the counter(0 -> 1)
        //     and sync with push-only mode: CP(2, 2) -> CP(3, 2)
        let exp1 = expectation(description: "exp 1")
        await d1.subscribeSync { event, _ in
            if let event = event as? SyncStatusChangedEvent, event.value == .synced {
                exp1.fulfill()
            }
        }

        try await d1.update { root, _ in
            (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
        }

        var changePack = await d1.createChangePack()
        XCTAssertEqual(changePack.getChangeSize(), 1)

        try await c1.changeSyncMode(d1, .realtimePushOnly)
        await fulfillment(of: [exp1], timeout: 5)

        await d1.unsubscribeSync()

        checkpoint = await d1.checkpoint
        XCTAssertEqual(checkpoint.getClientSeq(), 3)
        XCTAssertEqual(checkpoint.getServerSeq(), 2)

        try await c1.changeSyncMode(d1, .manual)

        // 04. cli update the document with increasing the counter(1 -> 2)
        //     and sync with push-pull mode. CP(3, 2) -> CP(4, 4)
        try await d1.update { root, _ in
            (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
        }

        // The previous increase(0 -> 1) is already pushed to the server,
        // so the ChangePack of the request only has the increase(1 -> 2).
        changePack = await d1.createChangePack()
        XCTAssertEqual(changePack.getChangeSize(), 1)

        try await c1.sync()
        checkpoint = await d1.checkpoint
        XCTAssertEqual(checkpoint.getClientSeq(), 4)
        XCTAssertEqual(checkpoint.getServerSeq(), 4)

        let value = await(d1.getRoot().counter as? JSONCounter<Int64>)?.value
        XCTAssertEqual(value, 2)

        try await c1.deactivate()
    }

    func test_should_prevent_remote_changes_in_push_only_mode() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let docKey = "\(Date().description)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        // 01. c2 attach the doc with realtime sync mode at first.
        try await c1.attach(d1)
        try await c2.attach(d2)

        let exp1 = expectation(description: "exp 1")
        let exp2 = expectation(description: "exp 2")
        var eventCount1 = 0

        await d1.subscribe { event, _ in
            eventCount1 += 1
            if event.type == .remoteChange, eventCount1 == 6 {
                exp1.fulfill()
            }
        }

        await d2.subscribe { event, _ in
            if event.type == .remoteChange {
                exp2.fulfill()
            }
        }

        try await d1.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "12")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "34")])
            ]))
        }

        await fulfillment(of: [exp2], timeout: 5)

        await d2.unsubscribe()

        var d1JSON = await(d1.getRoot().tree as? JSONTree)?.toXML()
        var d2JSON = await(d2.getRoot().tree as? JSONTree)?.toXML()
        XCTAssertEqual(d1JSON, "<doc><p>12</p><p>34</p></doc>")
        XCTAssertEqual(d2JSON, "<doc><p>12</p><p>34</p></doc>")

        try await d1.update { root, _ in
            try (root.tree as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "a"))
        }
        try await c1.sync()

        // Simulate the situation in the runSyncLoop where a pushpull request has been sent
        // but a response has not yet been received.
        try await c2.sync()

        // In push-only mode, remote-change events should not occur.
        try await c2.changeSyncMode(d2, .realtimePushOnly)
        var remoteChangeOccured = false

        await d2.subscribe { event, _ in
            if event.type == .remoteChange {
                remoteChangeOccured = true
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertFalse(remoteChangeOccured)

        try await c2.changeSyncMode(d2, .realtime)

        try await d2.update { root, _ in
            try (root.tree as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "b"))
        }

        await fulfillment(of: [exp1], timeout: 5)

        d1JSON = await(d1.getRoot().tree as? JSONTree)?.toXML()
        d2JSON = await(d2.getRoot().tree as? JSONTree)?.toXML()
        XCTAssertEqual(d1JSON, "<doc><p>1ba2</p><p>34</p></doc>")
        XCTAssertEqual(d2JSON, "<doc><p>1ba2</p><p>34</p></doc>")

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_should_avoid_unnecessary_syncs_in_push_only_mode() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let docKey = "\(Date().description)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        try await c1.attach(d1)
        try await c2.attach(d2)

        let exp1 = expectation(description: "exp 1")
        var exp2 = expectation(description: "exp 2")

        await d2.subscribeSync { _, _ in
            exp2.fulfill()
        }

        try await d1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
        }

        await fulfillment(of: [exp2], timeout: 5)
        exp2 = expectation(description: "exp 2")

        var d1JSON = await(d1.getRoot().t as? JSONText)?.toString
        var d2JSON = await(d2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(d1JSON, "a")
        XCTAssertEqual(d2JSON, "a")

        await d1.subscribeSync { _, _ in
            exp1.fulfill()
        }

        try await c1.changeSyncMode(d1, .realtimePushOnly)

        try await d2.update { root, _ in
            (root.t as? JSONText)?.edit(1, 1, "b")
        }

        await fulfillment(of: [exp2], timeout: 5)
        exp2 = expectation(description: "exp 2")

        try await d2.update { root, _ in
            (root.t as? JSONText)?.edit(2, 2, "c")
        }

        await fulfillment(of: [exp2], timeout: 5)

        try await c1.changeSyncMode(d1, .realtime)

        await fulfillment(of: [exp1], timeout: 5)

        d1JSON = await(d1.getRoot().t as? JSONText)?.toString
        d2JSON = await(d2.getRoot().t as? JSONText)?.toString
        XCTAssertEqual(d1JSON, "abc")
        XCTAssertEqual(d2JSON, "abc")

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_should_handle_each_request_one_by_one() async throws {
        for index in 0 ..< 10 {
            let client = Client(rpcAddress)
            try await client.activate()

            let docKey = "\(Date().description)-\(self.description)-\(index)".toDocKey
            let doc = Document(key: docKey)

            do {
                try await client.attach(doc)
                try await client.deactivate()
            } catch {
                XCTFail("\(error.localizedDescription)")
            }
        }
    }

    func test_duplicated_local_changes_not_sent_to_server() async throws {
        try await withTwoClientsAndDocuments(self.description, detachDocuments: false) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc",
                                        children: [
                                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "12")]),
                                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "34")])
                                        ])
                )
            }

            try await c1.sync()
            try await c1.sync()
            try await c1.sync()
            try await c1.detach(d1)

            try await Task.sleep(nanoseconds: 3_000_000_000)

            try await c2.sync()

            let d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
            let d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
            XCTAssertEqual(d1XML, /* html */ "<doc><p>12</p><p>34</p></doc>")
            XCTAssertEqual(d2XML, /* html */ "<doc><p>12</p><p>34</p></doc>")

            try await c2.detach(d2)

            try await c1.deactivate()
            try await c2.deactivate()
        }
    }

    func test_should_handle_local_changes_correctly_when_receiving_snapshot() async throws {
        try await withTwoClientsAndDocuments(self.description, detachDocuments: false) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.counter = JSONCounter(value: Int64(0))
            }

            try await c1.sync()
            try await c2.sync()

            // 01. c1 increases the counter for creating snapshot.
            for _ in 0 ..< 500 {
                try await d1.update { root, _ in
                    (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
                }
            }

            try await c1.sync()

            // 02. c2 receives the snapshot and increases the counter simultaneously.
            Task {
                try await c2.sync()
            }
            try await d2.update { root, _ in
                (root.counter as? JSONCounter<Int64>)?.increase(value: 1)
            }

            try await c2.sync()
            try await c1.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    @MainActor
    func test_should_retry_on_network_failure_and_eventually_succeed() async throws {
        let c1 = Client(rpcAddress, isMockingEnabled: true)
        try await c1.activate()

        let docKey = "\(Date().description)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        try await c1.attach(d1)

        c1.setMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges,
                        error: connectError(from: .unknown))

        try d1.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "a")
        }

        XCTAssertTrue(c1.getCondition(.syncLoop))

        c1.setMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges,
                        error: connectError(from: .failedPrecondition))

        let exp = expectation(description: "Sync loop should end")
        Task {
            while c1.getCondition(.syncLoop) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5)

        XCTAssertFalse(c1.getCondition(.syncLoop))
    }

    func test_should_successfully_broadcast_serializeable_payload() async throws {
        let c1 = Client(rpcAddress)
        try await c1.activate()

        let docKey = "\(Date().description)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        try await c1.attach(d1)

        let topic = "test"
        let payload = Payload([
            "a": 1,
            "b": "2"
        ])

        let errorHandler = { (error: Error) in
            XCTFail("broadcast failed \(error)")
        }

        await d1.broadcast(topic: topic, payload: payload, error: errorHandler)

        try await sleep(milliseconds: 300)

        try await c1.deactivate()
    }

    func test_should_throw_error_when_broadcasting_unserializeable_payload() async throws {
        let c1 = Client(rpcAddress)
        try await c1.activate()

        let docKey = "\(Date().description)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        try await c1.attach(d1)

        let eventCollector = EventCollector<String>(doc: d1)

        // broadcast unserializable payload
        let topic = "test"
        struct UnserializablePayload: Codable {
            let data: String
        }

        let payload = Payload([
            "a": UnserializablePayload(data: "")
        ])

        let errorHandler = { (error: Error) in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("error should be YorkieError, but \(type(of: error))")
                return
            }
            eventCollector.add(event: yorkieError.message)
        }

        await d1.broadcast(topic: topic, payload: payload, error: errorHandler)

        try await sleep(milliseconds: 300)

        await eventCollector.verifyNthValue(at: 1, isEqualTo: "payload is not serializable")

        try await c1.deactivate()
    }

    func test_should_trigger_the_handler_for_a_subscribed_broadcast_event() async throws {
        try await withTwoClientsAndDocuments(self.description, syncMode: .realtime) { _, d1, _, d2 in
            let eventCollector = EventCollector<BroadcastExpectValue>(doc: d2)
            let expectValue = BroadcastExpectValue(topic: "test", payload: Payload([
                "a": 1,
                "b": "2"
            ]))

            await d2.subscribeBroadcast { event, _ in
                guard let broadcastEvent = event as? BroadcastEvent else {
                    return
                }
                let topic = broadcastEvent.value.topic
                let payload = broadcastEvent.value.payload

                if topic == expectValue.topic {
                    eventCollector.add(event: BroadcastExpectValue(topic: topic, payload: payload))
                }
            }

            await d1.broadcast(topic: expectValue.topic, payload: expectValue.payload)

            try await sleep(milliseconds: 300)

            await eventCollector.verifyNthValue(at: 1, isEqualTo: expectValue)

            XCTAssertEqual(eventCollector.count, 1)

            await d2.unsubscribeBroadcast()
        }
    }

    func test_should_not_trigger_the_handler_for_an_unsubscribed_broadcast_event() async throws {
        try await withTwoClientsAndDocuments(self.description, syncMode: .realtime) { _, d1, _, d2 in
            let eventCollector = EventCollector<BroadcastExpectValue>(doc: d2)
            let expectValue1 = BroadcastExpectValue(topic: "test1", payload: Payload([
                "a": 1,
                "b": "2"
            ]))
            let expectValue2 = BroadcastExpectValue(topic: "test2", payload: Payload([
                "a": 1,
                "b": "2"
            ]))

            await d2.subscribeBroadcast { event, _ in
                guard let broadcastEvent = event as? BroadcastEvent else {
                    return
                }
                let topic = broadcastEvent.value.topic
                let payload = broadcastEvent.value.payload

                if topic == expectValue1.topic {
                    eventCollector.add(event: BroadcastExpectValue(topic: topic, payload: payload))
                } else if topic == expectValue2.topic {
                    eventCollector.add(event: BroadcastExpectValue(topic: topic, payload: payload))
                }
            }

            await d1.broadcast(topic: expectValue1.topic, payload: expectValue1.payload)

            try await sleep(milliseconds: 300)

            await eventCollector.verifyNthValue(at: 1, isEqualTo: expectValue1)

            XCTAssertEqual(eventCollector.values.count, 1)

            await d2.unsubscribeBroadcast()
        }
    }

    func test_should_not_trigger_the_handler_for_a_broadcast_event_after_unsubscribing() async throws {
        try await withTwoClientsAndDocuments(self.description, syncMode: .realtime) { _, d1, _, d2 in
            let eventCollector = EventCollector<BroadcastExpectValue>(doc: d2)
            let expectValue = BroadcastExpectValue(topic: "test1", payload: Payload([
                "a": 1,
                "b": "2"
            ]))

            await d2.subscribeBroadcast { event, _ in
                guard let broadcastEvent = event as? BroadcastEvent else {
                    return
                }
                let topic = broadcastEvent.value.topic
                let payload = broadcastEvent.value.payload

                if topic == expectValue.topic {
                    eventCollector.add(event: BroadcastExpectValue(topic: topic, payload: payload))
                }
            }

            await d1.broadcast(topic: expectValue.topic, payload: expectValue.payload)

            try await sleep(milliseconds: 300)

            await eventCollector.verifyNthValue(at: 1, isEqualTo: expectValue)

            await d2.unsubscribeBroadcast()

            await d1.broadcast(topic: expectValue.topic, payload: expectValue.payload)

            try await sleep(milliseconds: 300)

            XCTAssertEqual(eventCollector.values.count, 1)
        }
    }

    func test_should_not_trigger_the_handler_for_a_broadcast_event_sent_by_the_publisher_to_itself() async throws {
        try await withTwoClientsAndDocuments(self.description, syncMode: .realtime) { _, d1, _, d2 in
            let eventCollector1 = EventCollector<BroadcastExpectValue>(doc: d1)
            let eventCollector2 = EventCollector<BroadcastExpectValue>(doc: d2)
            let expectValue = BroadcastExpectValue(topic: "test", payload: Payload([
                "a": 1,
                "b": "2"
            ]))

            await d1.subscribeBroadcast { event, _ in
                guard let broadcastEvent = event as? BroadcastEvent else {
                    return
                }
                let topic = broadcastEvent.value.topic
                let payload = broadcastEvent.value.payload

                if topic == expectValue.topic {
                    eventCollector1.add(event: BroadcastExpectValue(topic: topic, payload: payload))
                }
            }

            await d2.subscribeBroadcast { event, _ in
                guard let broadcastEvent = event as? BroadcastEvent else {
                    return
                }

                let topic = broadcastEvent.value.topic
                let payload = broadcastEvent.value.payload

                if topic == expectValue.topic {
                    eventCollector2.add(event: BroadcastExpectValue(topic: topic, payload: payload))
                }
            }

            await d1.broadcast(topic: expectValue.topic, payload: expectValue.payload)

            // Assuming that D2 takes longer to receive the broadcast event compared to D1
            try await sleep(milliseconds: 300)

            await eventCollector2.verifyNthValue(at: 1, isEqualTo: expectValue)

            await d1.unsubscribeBroadcast()
            await d2.unsubscribeBroadcast()

            XCTAssertEqual(eventCollector1.count, 0)
            XCTAssertEqual(eventCollector2.count, 1)
        }
    }
}
