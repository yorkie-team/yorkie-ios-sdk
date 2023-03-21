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

    func test_can_handle_sync() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        self.d1 = Document(key: docKey)
        try await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        self.d2 = Document(key: docKey)
        try await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, false)
        try await self.c2.attach(self.d2, false)

        try await self.d1.update { root in
            root.k1 = "v1"
        }

        try await self.c1.sync()
        try await self.c2.sync()

        var result = await d2.getRoot().get(key: "k1") as? String
        XCTAssert(result == "v1")

        try await self.d1.update { root in
            root.k2 = "v2"
        }

        try await self.c1.sync()
        try await self.c2.sync()

        result = await self.d2.getRoot().get(key: "k2") as? String
        XCTAssert(result == "v2")

        try await self.d1.update { root in
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

    func test_can_handle_sync_auto() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        self.d1 = Document(key: docKey)
        try await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        self.d2 = Document(key: docKey)
        try await self.d1.update { root in
            root.k1 = ""
            root.k2 = ""
            root.k3 = ""
        }

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, true)
        try await self.c2.attach(self.d2, true)

        try await self.d1.update { root in
            root.k1 = "v1"
            root.k2 = "v2"
            root.k3 = "v3"
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        var result = await d2.getRoot().get(key: "k1") as? String
        XCTAssert(result == "v1")
        result = await self.d2.getRoot().get(key: "k2") as? String
        XCTAssert(result == "v2")
        result = await self.d2.getRoot().get(key: "k3") as? String
        XCTAssert(result == "v3")

        try await self.d1.update { root in
            root.integer = Int32.max
            root.long = Int64.max
            root.double = Double.pi
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let resultInteger = await self.d2.getRoot().get(key: "integer") as? Int32
        XCTAssert(resultInteger == Int32.max)
        let resultLong = await self.d2.getRoot().get(key: "long") as? Int64
        XCTAssert(resultLong == Int64.max)
        let resultDouble = await self.d2.getRoot().get(key: "double") as? Double
        XCTAssert(resultDouble == Double.pi)

        let curr = Date()

        try await self.d1.update { root in
            root.true = true
            root.false = false
            root.date = curr
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let resultTrue = await self.d2.getRoot().get(key: "true") as? Bool
        XCTAssert(resultTrue == true)
        let resultFalse = await self.d2.getRoot().get(key: "false") as? Bool
        XCTAssert(resultFalse == false)
        let resultDate = await self.d2.getRoot().get(key: "date") as? Date
        XCTAssert(resultDate?.trimedLessThanMilliseconds == curr.trimedLessThanMilliseconds)

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func skip_test_stream_connection_evnts() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        let connectedExpectation = XCTestExpectation(description: "connected")
        let disconnectedExpectation = XCTestExpectation(description: "disconnected")

        var eventCount = 0

        c1.eventStream.sink { event in
            switch event {
            case let event as StreamConnectionStatusChangedEvent:
                eventCount += 1
                switch event.value {
                case .connected:
                    connectedExpectation.fulfill()
                case .disconnected:
                    disconnectedExpectation.fulfill()
                }
            default:
                break
            }
        }.store(in: &self.cancellables)

        try await c1.activate()

        let d1 = Document(key: docKey)

        try await c1.attach(d1)

        wait(for: [connectedExpectation], timeout: 2)

        try await c1.detach(d1)
        try await c1.deactivate()

        wait(for: [disconnectedExpectation], timeout: 2)

        XCTAssertEqual(eventCount, 2)
    }

    // swiftlint: disable force_cast
    func test_send_peer_changed_event_to_the_user_who_updated_presence() async throws {
        struct Cursor: Codable {
            // swiftlint: disable identifier_name
            var x: Int
            var y: Int
        }

        struct PresenceType: Codable {
            var name: String
            var cursor: Cursor
        }

        var option = ClientOptions()
        option.presence = PresenceType(name: "c1", cursor: Cursor(x: 0, y: 0)).createdDictionary

        let c1 = Client(rpcAddress: rpcAddress, options: option)

        option.presence = PresenceType(name: "c2", cursor: Cursor(x: 1, y: 1)).createdDictionary

        let c2 = Client(rpcAddress: rpcAddress, options: option)

        try await c1.activate()
        try await c2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1ActorID = await c1.id!
        let c2ActorID = await c2.id!

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        var c1Name = "c1"
        var c2Name = "c2"

        var c1NumberOfEvents = 0
        var c2NumberOfEvents = 0
        let c1ExpectedValues = [
            PeersChangedValue(type: .initialized, peers: [docKey: [c1ActorID: PresenceType(name: "c1", cursor: Cursor(x: 0, y: 0)).createdDictionary]]),
            PeersChangedValue(type: .watched, peers: [docKey: [c2ActorID: PresenceType(name: "c2", cursor: Cursor(x: 1, y: 1)).createdDictionary]]),
            PeersChangedValue(type: .presenceChanged, peers: [docKey: [c1ActorID: PresenceType(name: "c1+", cursor: Cursor(x: 0, y: 0)).createdDictionary]]),
            PeersChangedValue(type: .presenceChanged, peers: [docKey: [c2ActorID: PresenceType(name: "c2+", cursor: Cursor(x: 1, y: 1)).createdDictionary]])
        ]
        let c2ExpectedValues = [
            PeersChangedValue(type: .initialized, peers: [docKey: [c1ActorID: PresenceType(name: "c1", cursor: Cursor(x: 0, y: 0)).createdDictionary,
                                                                   c2ActorID: PresenceType(name: "c2", cursor: Cursor(x: 1, y: 1)).createdDictionary]]),
            PeersChangedValue(type: .presenceChanged, peers: [docKey: [c1ActorID: PresenceType(name: "c1+", cursor: Cursor(x: 0, y: 0)).createdDictionary]]),
            PeersChangedValue(type: .presenceChanged, peers: [docKey: [c2ActorID: PresenceType(name: "c2+", cursor: Cursor(x: 1, y: 1)).createdDictionary]]),
            PeersChangedValue(type: .unwatched, peers: [docKey: [c1ActorID: PresenceType(name: "c1+", cursor: Cursor(x: 0, y: 0)).createdDictionary]])
        ]

        c1.eventStream.sink { event in
            switch event {
            case let event as PeerChangedEvent:
                print("#### c1 \(event)")
                XCTAssertEqual(event.value, c1ExpectedValues[c1NumberOfEvents])
                c1NumberOfEvents += 1
            default:
                break
            }
        }.store(in: &self.cancellables)

        c2.eventStream.sink { event in
            switch event {
            case let event as PeerChangedEvent:
                print("#### c2 \(event)")
                XCTAssertEqual(event.value, c2ExpectedValues[c2NumberOfEvents])
                c2NumberOfEvents += 1

            default:
                break
            }
        }.store(in: &self.cancellables)

        try await c1.attach(d1)
        try await c2.attach(d2)

        c1Name = "c1+"
        try await c1.updatePresence("name", c1Name)

        try await c1.sync()
        try await c2.sync()

        let presence1: PresenceType = self.decodePresence(await c2.getPeers(key: d2.getKey())[c1.id!]!)!

        XCTAssert(c1Name == presence1.name)

        c2Name = "c2+"
        try await c2.updatePresence("name", c2Name)

        try await c2.sync()
        try await c1.sync()

        let presence2: PresenceType = self.decodePresence(await c1.getPeers(key: d1.getKey())[c2.id!]!)!

        XCTAssert(c2Name == presence2.name)

        let c1Peer = await c1.getPeers(key: d1.getKey()) as NSDictionary
        let c2Peer = (await c2.getPeers(key: d2.getKey()) as NSDictionary) as! [AnyHashable: Any]

        XCTAssert(c1Peer.isEqual(to: c2Peer))

        try await c1.detach(d1)

        // Keep the watchLoop of c2 for catch the detach event of c1.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        try await c2.detach(d2)

        try await c1.deactivate()
        try await c2.deactivate()
    }

    private func decodePresence<T: Decodable>(_ dictionary: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }
}
