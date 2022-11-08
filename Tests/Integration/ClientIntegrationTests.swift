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

    var c1: Client!
    var c2: Client!
    var d1: Document!
    var d2: Document!

    func skip_test_can_handle_sync() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)"

        do {
            self.c1 = try Client(rpcAddress: self.rpcAddress, options: options)
            self.c2 = try Client(rpcAddress: self.rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        self.d1 = Document(key: docKey)
        await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        self.d2 = Document(key: docKey)
        await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, true)
        try await self.c2.attach(self.d2, true)

        await self.d1.update { root in
            root.k1 = "v1"
        }

        try await self.c1.sync()
        try await self.c2.sync()

        var result = await d2.getRoot().get(key: "k1") as? String
        XCTAssert(result == "v1")

        await self.d1.update { root in
            root.k2 = "v2"
        }

        try await self.c1.sync()
        try await self.c2.sync()

        result = await self.d2.getRoot().get(key: "k2") as? String
        XCTAssert(result == "v2")

        await self.d1.update { root in
            root.k3 = "v3"
        }

        try await self.c1.sync()
        try await self.c2.sync()

        result = await self.d2.getRoot().get(key: "k3") as? String
        XCTAssert(result == "v3")

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func skip_test_can_handle_sync_auto() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)"

        do {
            self.c1 = try Client(rpcAddress: self.rpcAddress, options: options)
            self.c2 = try Client(rpcAddress: self.rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        self.d1 = Document(key: docKey)
        await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        self.d2 = Document(key: docKey)
        await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, false)
        try await self.c2.attach(self.d2, false)

        try await Task.sleep(nanoseconds: 5_000_000_000)

        await self.d1.update { root in
            root.k1 = "v1"
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        var result = await d2.getRoot().get(key: "k1") as? String
        XCTAssert(result == "v1")

        await self.d1.update { root in
            root.k2 = "v2"
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        result = await self.d2.getRoot().get(key: "k2") as? String
        XCTAssert(result == "v2")

        await self.d1.update { root in
            root.k3 = "v3"
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        result = await self.d2.getRoot().get(key: "k3") as? String
        XCTAssert(result == "v3")

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func skip_test_send_peer_changed_event_to_the_user_who_updated_presence() async throws {
        struct Cursor: Encodable {
            // swiftlint: disable identifier_name
            var x: Int
            var y: Int
        }

        struct PresenceType: Encodable {
            var name: String
            var cursor: Cursor
        }

        var option = ClientOptions()
        option.presence = PresenceType(name: "c1", cursor: Cursor(x: 0, y: 0)).createdDictionary

        let c1 = try Client(rpcAddress: rpcAddress, options: option)

        option.presence = PresenceType(name: "c2", cursor: Cursor(x: 1, y: 1)).createdDictionary

        let c2 = try Client(rpcAddress: rpcAddress, options: option)

        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)"

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        try await c1.attach(d1)
        try await c2.attach(d2)

        var c1Name = "c1"
        var c2Name = "c2"

        var c1EventResult: String?
        var c2EventResult: String?

        c1.eventStream.sink { _ in
        } receiveValue: { event in
            switch event {
            case let event as PeerChangedEvent:
                print("#### c1 \(event)")
                c1EventResult = c1.presence["name"] as? String
                XCTAssert(c1Name == c1EventResult)
            default:
                break
            }
        }.store(in: &self.cancellables)

        c2.eventStream.sink { _ in
        } receiveValue: { event in
            switch event {
            case let event as PeerChangedEvent:
                print("#### c2 \(event)")
                c2EventResult = c2.presence["name"] as? String
                XCTAssert(c2Name == c2EventResult)
            default:
                break
            }
        }.store(in: &self.cancellables)

        // Since attach's response doesn't wait for the watch ready,
        // We need to wait here until the threshold.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        c1Name = "c1+"
        try await c1.updatePresence("name", c1Name)

        c2Name = "c2+"
        try await c2.updatePresence("name", c2Name)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        // swiftlint: disable force_cast
        XCTAssert((c1.getPeers(key: d1.getKey()) as NSDictionary).isEqual(to: (c2.getPeers(key: d2.getKey()) as NSDictionary) as! [AnyHashable: Any]))

        try await c1.detach(d1)
        try await c2.detach(d2)

        try await c1.deactivate()
        try await c2.deactivate()
    }
}
