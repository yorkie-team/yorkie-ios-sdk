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

final class PresenceTests: XCTestCase {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

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

        for index in 0 ..< snapshotThreshold {
            try await doc1.update { _, presence in
                presence.set(["key": index])
            }
        }

        var presence = await doc1.getPresence(c1.id!)?["key"] as? Int
        XCTAssertEqual(presence, snapshotThreshold - 1)

        try await c1.sync()
        try await c2.sync()

        presence = await doc2.getPresence(c1.id!)?["key"] as? Int
        XCTAssertEqual(presence, snapshotThreshold - 1)
    }

    func test_can_be_set_initial_value_in_attach_and_be_removed_in_detach() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["key": "key1"], false)
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["key": "key2"], false)

        var presence = await doc1.getPresence(c1.id!)?["key"] as? String
        XCTAssertEqual(presence, "key1")
        presence = await doc1.getPresence(c2.id!)?["key"] as? String
        XCTAssertEqual(presence, nil)
        presence = await doc2.getPresence(c2.id!)?["key"] as? String
        XCTAssertEqual(presence, "key2")
        presence = await doc2.getPresence(c1.id!)?["key"] as? String
        XCTAssertEqual(presence, "key1")

        try await c1.sync()
        presence = await doc1.getPresence(c2.id!)?["key"] as? String
        XCTAssertEqual(presence, "key2")

        try await c2.detach(doc2)
        try await c1.sync()

        let hasPresence = await doc1.hasPresence(c2.id!)
        XCTAssertFalse(hasPresence)
    }

    func test_should_be_initialized_as_an_empty_object_if_no_initial_value_is_set_during_attach() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())

        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, [:], false)
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, [:], false)

        var presence = await doc1.getPresence(c1.id!)
        XCTAssertTrue(presence!.isEmpty)
        presence = await doc1.getPresence(c2.id!)
        XCTAssertTrue(presence == nil)
        presence = await doc2.getPresence(c2.id!)
        XCTAssertTrue(presence!.isEmpty)
        presence = await doc2.getPresence(c1.id!)
        XCTAssertTrue(presence!.isEmpty)

        try await c1.sync()

        presence = await doc2.getPresence(c1.id!)
        XCTAssertTrue(presence!.isEmpty)
    }

    func test_can_be_updated_partially_by_doc_update_function() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["key": "key1", "cursor": ["x": 0, "y": 0]])

        await doc1.subscribePeers { event in
            print("@@@@ event 1 \(event)")
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["key": "key2", "cursor": ["x": 0, "y": 0]])

        await doc2.subscribePeers { event in
            print("@@@@ event 2 \(event)")
        }

        try await doc1.update { _, presence in
            presence.set(["cursor": ["x": 1, "y": 1]])
        }

        var presence = await doc1.getPresence(c1.id!)
        XCTAssertEqual(presence?["key"] as? String, "key1")
        XCTAssertEqual(presence?["cursor"] as? [String: Int], ["x": 1, "y": 1])

        try await c1.sync()
        try await c2.sync()

        presence = await doc2.getPresence(c1.id!)
        XCTAssertEqual(presence?["key"] as? String, "key1")
        XCTAssertEqual(presence?["cursor"] as? [String: Int], ["x": 1, "y": 1])
    }
}

final class PresenceSubscribeTests: XCTestCase {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    struct EventResult: Equatable {
        let type: PeersChangedEventType
        var elements = [PeerElement]()

        init(_ event: PeersChangedEvent) {
            switch event.value {
            case .initialized(peers: let elements):
                self.type = .initialized
                self.elements.append(contentsOf: elements)
            case .presenceChanged(let element):
                self.type = .presenceChanged
                self.elements.append(element)
            case .watched(let element):
                self.type = .watched
                self.elements.append(element)
            case .unwatched(let element):
                self.type = .unwatched
                self.elements.append(element)
            }
        }

        init(_ type: PeersChangedEventType, _ elements: [PeerElement]) {
            self.type = type
            self.elements = elements
        }

        static func == (lhs: PresenceSubscribeTests.EventResult, rhs: PresenceSubscribeTests.EventResult) -> Bool {
            if lhs.type != rhs.type {
                return false
            }

            if lhs.elements.count != rhs.elements.count {
                return false
            }

            for (index, value) in lhs.elements.enumerated() {
                if value.clientID != rhs.elements[index].clientID {
                    return false
                }

                if !(value.presence == rhs.elements[index].presence) {
                    return false
                }
            }

            return true
        }
    }

    static func comparePresences(_ lhs: [PeerElement], _ rhs: [PeerElement]) -> Bool {
        if lhs.count != rhs.count {
            return false
        }

        for leftElement in lhs {
            if let rightElment = rhs.first { $0.clientID == leftElement.clientID }, leftElement.presence == rightElment.presence {
                continue
            } else {
                return false
            }
        }

        return true
    }

    func test_should_be_synced_eventually() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        try await c1.activate()
        try await c2.activate()
        let c1ID = await c1.id!
        let c2ID = await c2.id!
        var eventCount1 = 0
        var eventCount2 = 0

        let expect1 = expectation(description: "sub 1")
        let expect2 = expectation(description: "sub 2")

        var eventReceived1 = [EventResult]()
        var eventReceived2 = [EventResult]()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["name": "a"])

        await doc1.subscribePeers { event in
            print("@@@@ event 1 \(event)")

            if let event = event as? PeersChangedEvent {
                eventCount1 += 1

                eventReceived1.append(EventResult(event))

                if eventCount1 == 3 {
                    expect1.fulfill()
                }
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b"])

        await doc2.subscribePeers { event in
            print("@@@@ event 2 \(event)")

            if let event = event as? PeersChangedEvent {
                eventCount2 += 1

                eventReceived2.append(EventResult(event))

                if eventCount2 == 2 {
                    expect2.fulfill()
                }
            }
        }

        try await doc1.update { _, presence in
            presence.set(["name": "A"])
        }
        try await doc2.update { _, presence in
            presence.set(["name": "B"])
        }

        await fulfillment(of: [expect1, expect2], timeout: 5, enforceOrder: false)

        let result1 = [
            EventResult(.presenceChanged, [PeerElement(c1ID, ["name": "A"])]),
            EventResult(.watched, [PeerElement(c2ID, ["name": "b"])]),
            EventResult(.presenceChanged, [PeerElement(c2ID, ["name": "B"])])
        ]

        let result2 = [
            EventResult(.presenceChanged, [PeerElement(c2ID, ["name": "B"])]),
            EventResult(.presenceChanged, [PeerElement(c1ID, ["name": "A"])])
        ]

        var presence = await doc2.getPresences()
        XCTAssertEqual(presence.first { $0.clientID == c2ID }?.presence["name"] as? String, "B")
        XCTAssertEqual(presence.first { $0.clientID == c1ID }?.presence["name"] as? String, "A")

        for (index, value) in result1.enumerated() {
            XCTAssertEqual(value, eventReceived1[index])
        }

        for (index, value) in result2.enumerated() {
            XCTAssertEqual(value, eventReceived2[index])
        }

        let resultPresence1 = await doc1.getPresences()
        let resultPresence2 = await doc2.getPresences()

        XCTAssert(Self.comparePresences(resultPresence1, resultPresence2))

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_should_receive_PeersChangedEventType_PresenceChanged_event_for_final_presence_if_there_are_multiple_presence_changes_within_doc_update() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        try await c1.activate()
        try await c2.activate()
        let c1ID = await c1.id!
        let c2ID = await c2.id!
        var eventCount1 = 0
        var eventCount2 = 0

        let expect1 = expectation(description: "sub 1")
        let expect2 = expectation(description: "sub 2")

        var eventReceived1 = [EventResult]()
        var eventReceived2 = [EventResult]()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["name": "a", "cursor": ["x": 0, "y": 0]])

        await doc1.subscribePeers { event in
            print("@@@@ event 1 \(event)")

            if let event = event as? PeersChangedEvent {
                eventCount1 += 1

                eventReceived1.append(EventResult(event))

                if eventCount1 == 2 {
                    expect1.fulfill()
                }
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b", "cursor": ["x": 0, "y": 0]])

        await doc2.subscribePeers { event in
            print("@@@@ event 2 \(event)")

            if let event = event as? PeersChangedEvent {
                eventCount2 += 1

                eventReceived2.append(EventResult(event))

                if eventCount2 == 1 {
                    expect2.fulfill()
                }
            }
        }

        try await doc1.update { _, presence in
            presence.set(["name": "A"])
            presence.set(["cursor": ["x": 1, "y": 1]])
            presence.set(["name": "X"])
        }

        await fulfillment(of: [expect1, expect2], timeout: 5, enforceOrder: true)

        let result1 = [
            EventResult(.presenceChanged, [PeerElement(c1ID, ["name": "X", "cursor": ["x": 1, "y": 1]])]),
            EventResult(.watched, [PeerElement(c2ID, ["name": "b", "cursor": ["x": 0, "y": 0]])])
        ]

        let result2 = [EventResult(.presenceChanged, [PeerElement(c1ID, ["name": "X", "cursor": ["x": 1, "y": 1]])])]

        for (index, value) in result1.enumerated() {
            XCTAssertEqual(value, eventReceived1[index])
        }

        for (index, value) in result2.enumerated() {
            XCTAssertEqual(value, eventReceived2[index])
        }

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_can_receive_unwatched_event_when_a_client_detaches() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        let c2 = Client(rpcAddress: rpcAddress, options: ClientOptions())
        try await c1.activate()
        try await c2.activate()
        let c1ID = await c1.id!
        let c2ID = await c2.id!

        var eventCount1 = 0

        let expect1 = expectation(description: "sub 1-1")
        let expect2 = expectation(description: "sub 1-2")

        var eventReceived1 = [EventResult]()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["name": "a"])

        await doc1.subscribePeers { event in
            print("@@@@ event 1 \(event)")

            if let event = event as? PeersChangedEvent {
                eventCount1 += 1

                eventReceived1.append(EventResult(event))

                if eventCount1 == 1 {
                    expect1.fulfill()
                }

                if eventCount1 == 2 {
                    expect2.fulfill()
                }
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b"])

        await fulfillment(of: [expect1], timeout: 5, enforceOrder: true)

        try await c2.detach(doc2)

        await fulfillment(of: [expect2], timeout: 5, enforceOrder: true)

        let result1 = [
            EventResult(.watched, [PeerElement(c2ID, ["name": "b"])]),
            EventResult(.unwatched, [PeerElement(c2ID, [:])])
        ]

        for (index, value) in result1.enumerated() {
            XCTAssertEqual(value, eventReceived1[index])
        }

        let resultPresence1 = await doc1.getPresences()
        XCTAssertEqual(resultPresence1.first { $0.clientID == c1ID }?.presence["name"] as? String, "a")

        let resultPresence2 = await doc2.getPresences()

        XCTAssert(Self.comparePresences(resultPresence1, resultPresence2))

        try await c1.deactivate()
        try await c2.deactivate()
    }
}
