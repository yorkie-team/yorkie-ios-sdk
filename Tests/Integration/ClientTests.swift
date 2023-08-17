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

class ClientTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func test_activate_and_deactivate_client_with_key() async throws {
        let clientKey = "\(self.description)-\(Date().description)"
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions(key: clientKey)
        let target: Client
        var status = ClientStatus.deactivated

        target = Client(rpcAddress: rpcAddress, options: options)

        target.eventStream.sink { event in
            switch event {
            case let event as StatusChangedEvent:
                status = event.value
            default:
                break
            }
        }.store(in: &self.cancellables)

        do {
            try await target.activate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        var isActive = await target.isActive

        XCTAssertTrue(isActive)
        XCTAssertEqual(target.key, clientKey)
        XCTAssert(status == .activated)

        do {
            try await target.deactivate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        isActive = await target.isActive

        XCTAssertFalse(isActive)
        XCTAssert(status == .deactivated)
    }

    func test_activate_and_deactivate_client_without_key() async throws {
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions()
        let target: Client
        var status = ClientStatus.deactivated

        target = Client(rpcAddress: rpcAddress, options: options)

        target.eventStream.sink { event in
            switch event {
            case let event as StatusChangedEvent:
                status = event.value
            default:
                break
            }
        }.store(in: &self.cancellables)

        try await target.activate()

        var isActive = await target.isActive

        XCTAssertTrue(isActive)
        XCTAssertFalse(target.key.isEmpty)
        XCTAssert(status == .activated)

        try await target.deactivate()

        isActive = await target.isActive

        XCTAssertFalse(isActive)
        XCTAssert(status == .deactivated)
    }

    func test_attach_detach_document_with_key() async throws {
        let clientId = UUID().uuidString
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions(key: clientId)
        let target: Client
        var status = ClientStatus.deactivated

        target = Client(rpcAddress: rpcAddress, options: options)

        target.eventStream.sink { event in
            print("#### \(event)")
            switch event {
            case let event as StatusChangedEvent:
                status = event.value
            default:
                break
            }
        }.store(in: &self.cancellables)

        do {
            try await target.activate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        var isActive = await target.isActive

        XCTAssertTrue(isActive)
        XCTAssertEqual(target.key, clientId)
        XCTAssert(status == .activated)

        let doc = Document(key: "doc1")

        do {
            try await target.attach(doc)
        } catch {
            XCTFail(error.localizedDescription)
        }

        do {
            try await target.detach(doc)
        } catch {
            XCTFail(error.localizedDescription)
        }

        do {
            try await target.deactivate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        isActive = await target.isActive

        XCTAssertFalse(isActive)
        XCTAssert(status == .deactivated)
    }

    func test_sync_option_with_multiple_clients() async throws {
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c3 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        try await c1.activate()
        try await c2.activate()
        try await c3.activate()

        // 01. c1, c2, c3 attach to the same document.
        let d1 = Document(key: docKey)
        try await c1.attach(d1, false)
        let d2 = Document(key: docKey)
        try await c2.attach(d2, false)
        let d3 = Document(key: docKey)
        try await c3.attach(d3, false)

        // 02. c1, c2 sync with push-pull mode.
        try await d1.update { root in
            root.c1 = Int64(0)
        }

        try await d2.update { root in
            root.c2 = Int64(0)
        }

        try await c1.sync()
        try await c2.sync()
        try await c1.sync()

        var result1 = await d1.getRoot().debugDescription
        var result2 = await d2.getRoot().debugDescription

        XCTAssertEqual(result1, result2)

        // 03. c1 and c2 sync with push-only mode. So, the changes of c1 and c2
        // are not reflected to each other.
        // But, c3 can get the changes of c1 and c2, because c3 sync with pull-pull mode.
        try await d1.update { root in
            root.c1 = Int64(1)
        }

        try await d2.update { root in
            root.c2 = Int64(1)
        }

        try await c1.sync(d1, .pushOnly)
        try await c2.sync(d2, .pushOnly)
        try await c3.sync()

        result1 = await d1.getRoot().debugDescription
        result2 = await d2.getRoot().debugDescription

        XCTAssertNotEqual(result1, result2)

        let result3 = await d3.getRoot().debugDescription

        XCTAssertEqual(result3, "{\"c1\":1,\"c2\":1}")

        // 04. c1 and c2 sync with push-pull mode.
        try await c1.sync()
        try await c2.sync()

        result1 = await d1.getRoot().debugDescription
        result2 = await d2.getRoot().debugDescription

        XCTAssertEqual(result1, result3)
        XCTAssertEqual(result2, result3)

        try await c1.detach(d1)
        try await c2.detach(d2)
        try await c3.detach(d3)

        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }

    func test_sync_option_with_mixed_mode() async throws {
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        try await c1.activate()

        // 01. cli attach to the same document having counter.
        let d1 = Document(key: docKey)
        try await c1.attach(d1, false)

        // 02. cli update the document with creating a counter
        //     and sync with push-pull mode: CP(0, 0) -> CP(1, 1)
        try await d1.update { root in
            root.counter = JSONCounter(value: Int64(0))
        }

        var checkpoint = await d1.checkpoint
        XCTAssertEqual(Checkpoint(serverSeq: 0, clientSeq: 0), checkpoint)

        try await c1.sync()

        checkpoint = await d1.checkpoint
        XCTAssertEqual(Checkpoint(serverSeq: 1, clientSeq: 1), checkpoint)

        // 03. cli update the document with increasing the counter(0 -> 1)
        //     and sync with push-only mode: CP(1, 1) -> CP(2, 1)
        try await d1.update { root in
            (root.counter as? JSONCounter<Int64>)!.increase(value: 1)
        }

        var changePack = await d1.createChangePack()

        XCTAssertEqual(changePack.getChanges().count, 1)

        try await c1.sync(d1, .pushOnly)

        checkpoint = await d1.checkpoint
        XCTAssertEqual(Checkpoint(serverSeq: 1, clientSeq: 2), checkpoint)

        // 04. cli update the document with increasing the counter(1 -> 2)
        //     and sync with push-pull mode. CP(2, 1) -> CP(3, 3)
        try await d1.update { root in
            (root.counter as? JSONCounter<Int64>)!.increase(value: 1)
        }

        // The previous increase(0 -> 1) is already pushed to the server,
        // so the ChangePack of the request only has the increase(1 -> 2).
        changePack = await d1.createChangePack()

        XCTAssertEqual(changePack.getChanges().count, 1)

        try await c1.sync()

        checkpoint = await d1.checkpoint
        XCTAssertEqual(Checkpoint(serverSeq: 3, clientSeq: 3), checkpoint)

        let counter = await(d1.getRoot().get(key: "counter") as? JSONCounter<Int64>)!

        XCTAssertEqual(2, counter.value)
    }
}
