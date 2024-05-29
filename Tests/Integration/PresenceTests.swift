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
    let rpcAddress = "http://localhost:8080"

    func test_can_be_built_from_a_snapshot() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, [:], .manual)
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, [:], .manual)

        let snapshotThreshold = 500

        for index in 0 ..< snapshotThreshold {
            try await doc1.update { _, presence in
                presence.set(["key": index])
            }
        }

        var presence = await doc1.getPresenceForTest(c1.id!)?["key"] as? Int
        XCTAssertEqual(presence, snapshotThreshold - 1)

        try await c1.sync()
        try await c2.sync()

        presence = await doc2.getPresenceForTest(c1.id!)?["key"] as? Int
        XCTAssertEqual(presence, snapshotThreshold - 1)
    }

    func test_can_be_set_initial_value_in_attach_and_be_removed_in_detach() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["key": "key1"], .manual)
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["key": "key2"], .manual)

        var presence = await doc1.getPresenceForTest(c1.id!)?["key"] as? String
        XCTAssertEqual(presence, "key1")
        presence = await doc1.getPresenceForTest(c2.id!)?["key"] as? String
        XCTAssertEqual(presence, nil)
        presence = await doc2.getPresenceForTest(c2.id!)?["key"] as? String
        XCTAssertEqual(presence, "key2")
        presence = await doc2.getPresenceForTest(c1.id!)?["key"] as? String
        XCTAssertEqual(presence, "key1")

        try await c1.sync()
        presence = await doc1.getPresenceForTest(c2.id!)?["key"] as? String
        XCTAssertEqual(presence, "key2")

        try await c2.detach(doc2)
        try await c1.sync()

        let hasPresence = await doc1.hasPresence(c2.id!)
        XCTAssertFalse(hasPresence)
    }

    func test_should_be_initialized_as_an_empty_object_if_no_initial_value_is_set_during_attach() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, [:], .manual)
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, [:], .manual)

        var presence = await doc1.getPresenceForTest(c1.id!)
        XCTAssertTrue(presence!.isEmpty)
        presence = await doc1.getPresenceForTest(c2.id!)
        XCTAssertTrue(presence == nil)
        presence = await doc2.getPresenceForTest(c2.id!)
        XCTAssertTrue(presence!.isEmpty)
        presence = await doc2.getPresenceForTest(c1.id!)
        XCTAssertTrue(presence!.isEmpty)

        try await c1.sync()

        presence = await doc2.getPresenceForTest(c1.id!)
        XCTAssertTrue(presence!.isEmpty)
    }

    func test_can_be_updated_partially_by_doc_update_function() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["key": "key1", "cursor": ["x": 0, "y": 0]])

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["key": "key2", "cursor": ["x": 0, "y": 0]])

        try await doc1.update { _, presence in
            presence.set(["cursor": ["x": 1, "y": 1]])
        }

        var presence = await doc1.getPresenceForTest(c1.id!)
        XCTAssertEqual(presence?["key"] as? String, "key1")
        XCTAssertEqual(presence?["cursor"] as? [String: Int], ["x": 1, "y": 1])

        try await c1.sync()
        try await c2.sync()

        presence = await doc2.getPresenceForTest(c1.id!)
        XCTAssertEqual(presence?["key"] as? String, "key1")
        XCTAssertEqual(presence?["cursor"] as? [String: Int], ["x": 1, "y": 1])
    }

    func test_should_return_only_online_clients() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        let c3 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        try await c3.activate()
        let c1ID = await c1.id!
        let c2ID = await c2.id!
        let c3ID = await c3.id!

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        var eventCount1 = 0
        let expect1 = expectation(description: "sub 1")
        let expect2 = expectation(description: "sub 2")
        let expect3 = expectation(description: "sub 3")

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["name": "a1", "cursor": ["x": 0, "y": 0]])

        await doc1.subscribePresence { event, _ in
            eventCount1 += 1

            if eventCount1 == 1, event.type == .watched {
                expect1.fulfill()
            }
            if eventCount1 == 2, event.type == .unwatched {
                expect2.fulfill()
            }
            if eventCount1 == 3, event.type == .watched {
                expect3.fulfill()
            }
        }

        // 01. c2 attaches doc in realtime sync, and c3 attached doc in manual sync.
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b1", "cursor": ["x": 0, "y": 0]])
        let doc3 = Document(key: docKey)
        try await c3.attach(doc3, ["name": "c1", "cursor": ["x": 0, "y": 0]], .manual)

        await fulfillment(of: [expect1], timeout: 5)

        var resultPresences1 = await doc1.getPresences()
        var doc1Presence = (await doc1.getMyPresence())!
        let doc2Presence = (await doc2.getMyPresence())!

        XCTAssert(resultPresences1.first { $0.clientID == c1ID }!.presence == doc1Presence)
        XCTAssert(resultPresences1.first { $0.clientID == c2ID }!.presence == doc2Presence)
        XCTAssert(resultPresences1.first { $0.clientID == c3ID } == nil)

        // 02. c2 is changed to manual sync, while c3 is changed to realtime sync.
        try await c2.changeSyncMode(doc2, .manual)
        await fulfillment(of: [expect2], timeout: 5) // c2 unwatched
        try await c3.changeSyncMode(doc3, .realtime)
        await fulfillment(of: [expect3], timeout: 5) // c3 watched

        resultPresences1 = await doc1.getPresences()
        doc1Presence = (await doc1.getMyPresence())!
        let doc3Presence = (await doc3.getMyPresence())!

        XCTAssert(resultPresences1.first { $0.clientID == c1ID }!.presence == doc1Presence)
        XCTAssert(resultPresences1.first { $0.clientID == c3ID }!.presence == doc3Presence)
        XCTAssert(resultPresences1.first { $0.clientID == c2ID } == nil)

        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }

    func test_can_get_presence_value_using_p_get_within_doc_update_function() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        let c1ID = await c1.id!

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["counter": 0], .manual)

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["counter": 0], .manual)

        try await doc1.update { _, presence in
            if let counter: Int = presence.get("counter") {
                presence.set(["counter": counter + 1])
            }
        }

        var result = await doc1.getPresenceForTest(c1ID)?["counter"] as? Int
        XCTAssertEqual(result, 1)

        try await c1.sync()
        try await c2.sync()

        result = await doc1.getPresenceForTest(c1ID)?["counter"] as? Int
        XCTAssertEqual(result, 1)
    }
}

final class PresenceSubscribeTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    struct EventResult: Equatable {
        var type: DocEventType
        var elements = [PeerElement]()

        init(_ event: DocEvent) {
            if let event = event as? InitializedEvent {
                self.type = .initialized
                self.elements = event.value
            } else if let event = event as? WatchedEvent {
                self.type = .watched
                self.elements = [event.value]
            } else if let event = event as? UnwatchedEvent {
                self.type = .unwatched
                self.elements = [PeerElement(event.value)]
            } else if let event = event as? PresenceChangedEvent {
                self.type = .presenceChanged
                self.elements = [event.value]
            } else {
                self.type = .snapshot
            }
        }

        init(_ type: DocEventType, _ elements: [PeerElement]) {
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
            if let rightElment = rhs.first(where: { $0.clientID == leftElement.clientID }), leftElement.presence == rightElment.presence {
                continue
            } else {
                return false
            }
        }

        return true
    }

    func test_should_be_synced_eventually() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
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

        await doc1.subscribePresence { event, _ in
            eventCount1 += 1

            eventReceived1.append(EventResult(event))

            if eventCount1 == 3 {
                expect1.fulfill()
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b"])

        await doc2.subscribePresence { event, _ in
            eventCount2 += 1

            eventReceived2.append(EventResult(event))

            if eventCount2 == 2 {
                expect2.fulfill()
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

        let presence = await doc2.getPresences()
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

    func test_should_not_be_accessible_to_other_clients_presence_when_the_stream_is_disconnected() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        let c2ID = await c2.id!

        let doc1 = Document(key: docKey)

        try await c1.attach(doc1, ["name": "a"])

        let expect1 = expectation(description: "sub 1")

        await doc1.subscribePresence { event, _ in
            if let event = event as? WatchedEvent,
               event.value.clientID == c2ID
            {
                expect1.fulfill()
            }
        }

        let expect2 = expectation(description: "sub 2")

        await doc1.subscribeConnection { event, _ in
            if let event = event as? ConnectionChangedEvent,
               event.value == .disconnected
            {
                expect2.fulfill()
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b"])

        await fulfillment(of: [expect1], timeout: 5, enforceOrder: false)
        await doc1.unsubscribePresence()

        var presence = await doc1.getPresence(c2ID)

        XCTAssertEqual(presence?["name"] as? String, "b")

        try await c1.changeSyncMode(doc1, .manual)

        await fulfillment(of: [expect2], timeout: 5, enforceOrder: false)
        await doc1.unsubscribeConnection()

        presence = await doc1.getPresence(c2ID)

        XCTAssert(presence == nil)

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_should_receive_presence_changed_event_for_final_presence_if_there_are_multiple_presence_changes_within_doc_update() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
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

        await doc1.subscribePresence { event, _ in
            eventCount1 += 1

            eventReceived1.append(EventResult(event))

            if eventCount1 == 2 {
                expect1.fulfill()
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b", "cursor": ["x": 0, "y": 0]])

        await doc2.subscribePresence { event, _ in
            eventCount2 += 1

            eventReceived2.append(EventResult(event))

            if eventCount2 == 1 {
                expect2.fulfill()
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

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
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

        await doc1.subscribePresence { event, _ in
            eventCount1 += 1

            eventReceived1.append(EventResult(event))

            if eventCount1 == 1 {
                expect1.fulfill()
            }

            if eventCount1 == 2 {
                expect2.fulfill()
            }
        }

        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b"])

        await fulfillment(of: [expect1], timeout: 5, enforceOrder: true)

        try await c2.detach(doc2)

        await fulfillment(of: [expect2], timeout: 5, enforceOrder: true)

        let result1 = [
            EventResult(.watched, [PeerElement(c2ID, ["name": "b"])]),
            EventResult(.unwatched, [PeerElement(c2ID, ["name": "b"])])
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

    func test_can_receive_presence_related_event_only_when_using_realtime_sync() async throws {
        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        let c3 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        try await c3.activate()
        let c2ID = await c2.id!
        let c3ID = await c3.id!

        let docKey = "\(Date().description)-\(self.description)".toDocKey

        var eventCount1 = 0
        var eventReceived1 = [EventResult]()
        let expect1 = expectation(description: "sub 1")
        let expect2 = expectation(description: "sub 2")
        let expect3 = expectation(description: "sub 3")
        let expect5 = expectation(description: "sub 5")
        let expect6 = expectation(description: "sub 6")
        let expect7 = expectation(description: "sub 7")
        let expect8 = expectation(description: "sub 8")

        let doc1 = Document(key: docKey)
        try await c1.attach(doc1, ["name": "a1", "cursor": ["x": 0, "y": 0]])

        await doc1.subscribePresence { event, _ in
            eventCount1 += 1

            eventReceived1.append(EventResult(event))

            if eventCount1 == 1 {
                expect1.fulfill()
            }
            if eventCount1 == 2 {
                expect2.fulfill()
            }
            if eventCount1 == 3 {
                expect3.fulfill()
            }
            if eventCount1 == 5 {
                expect5.fulfill()
            }
            if eventCount1 == 6 {
                expect6.fulfill()
            }
            if eventCount1 == 7 {
                expect7.fulfill()
            }
            if eventCount1 == 8 {
                expect8.fulfill()
            }
        }

        // 01. c2 attaches doc in realtime sync, and c3 attached doc in manual sync.
        //     c1 receives the watched event from c2.
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2, ["name": "b1", "cursor": ["x": 0, "y": 0]])
        let doc3 = Document(key: docKey)
        try await c3.attach(doc3, ["name": "c1", "cursor": ["x": 0, "y": 0]], .manual)

        await fulfillment(of: [expect1], timeout: 5) // c2 watched

        // 02. c2 and c3 update the presence.
        //     c1 receives the presence-changed event from c2.
        try await doc2.update { _, presence in
            presence.set(["name": "b2"])
        }
        try await doc3.update { _, presence in
            presence.set(["name": "c2"])
        }

        await fulfillment(of: [expect2], timeout: 5) // c2 presence-changed

        // 03. c2 is changed to manual sync, c3 resumes the document (in realtime sync).
        //     c1 receives an unwatched event from c2 and a watched event from c3.
        try await c2.changeSyncMode(doc2, .manual)
        await fulfillment(of: [expect3], timeout: 5) // c2 unwatched
        try await c3.changeSyncMode(doc3, .realtime)
        await fulfillment(of: [expect5], timeout: 5) // c3 watched, c3 presence-changed

        // 04. c2 and c3 update the presence.
        //     c1 receives the presence-changed event from c3.
        try await doc2.update { _, presence in
            presence.set(["name": "b3"])
        }
        try await doc3.update { _, presence in
            presence.set(["name": "c3"])
        }

        await fulfillment(of: [expect6], timeout: 5) // c3 presence-changed

        // 05. c3 is changed to manual sync,
        //     c1 receives an unwatched event from c3.
        try await c3.changeSyncMode(doc3, .manual)
        await fulfillment(of: [expect7], timeout: 5) // c3 unwatched

        // 06. c2 performs manual sync and then resumes(switches to realtime sync).
        //     After applying all changes, only the watched event is triggered.

        // TODO(hackerwins): This is workaround for some non-deterministic behavior.
        // We need to fix this issue.
        try await c2.sync()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await c2.changeSyncMode(doc2, .realtime)
        await fulfillment(of: [expect8], timeout: 5) // c2 watched

        let result1 = [
            EventResult(.watched, [PeerElement(c2ID, ["name": "b1", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.presenceChanged, [PeerElement(c2ID, ["name": "b2", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.unwatched, [PeerElement(c2ID, ["name": "b2", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.watched, [PeerElement(c3ID, ["name": "c1", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.presenceChanged, [PeerElement(c3ID, ["name": "c2", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.presenceChanged, [PeerElement(c3ID, ["name": "c3", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.unwatched, [PeerElement(c3ID, ["name": "c3", "cursor": ["x": 0, "y": 0]])]),
            EventResult(.watched, [PeerElement(c2ID, ["name": "b3", "cursor": ["x": 0, "y": 0]])])
        ]

        for (index, value) in result1.enumerated() {
            XCTAssertEqual(value, eventReceived1[index])
        }

        try await c1.deactivate()
        try await c2.deactivate()
        try await c3.deactivate()
    }

    private func decodeDictionary(_ dictionary: Any?) -> CRDTTreePosStruct? {
        guard let dictionary = dictionary as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [])
        else {
            return nil
        }

        return try? JSONDecoder().decode(CRDTTreePosStruct.self, from: data)
    }
}
