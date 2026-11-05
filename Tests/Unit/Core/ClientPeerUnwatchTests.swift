/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// Mirrors yorkie-js-sdk document_test.ts "should retain presence after an unwatch/watch cycle"
/// (#1501). The iOS unwatch handling lives in the client's watch-event handler, so the test drives
/// a real ``Client`` (mocking enabled) with doc events.
@MainActor
final class ClientPeerUnwatchTests: XCTestCase {
    private func docEvent(_ type: Yorkie_V1_DocEventType, publisher: String) -> WatchResponse {
        WatchResponse.with {
            $0.event = Yorkie_V1_WatchEvent.with {
                $0.docEvent = Yorkie_V1_DocWatchEvent.with {
                    $0.event = Yorkie_V1_DocEvent.with {
                        $0.type = type
                        $0.publisher = publisher
                    }
                }
            }
        }
    }

    func test_should_retain_presence_after_an_unwatch_watch_cycle() {
        // given - a peer that is online with a known presence
        let key = "unwatch-doc"
        let client = Client("http://localhost:1", ClientOptions(), isMockingEnabled: true)
        let doc = Document(key: key)
        client.adoptAttachment(
            Attachment(resource: doc, resourceID: "r", syncMode: .realtime),
            key: key,
            actorID: "000000000000000000000001"
        )
        let peerID = "peer-client-id"
        doc.setPresenceForTest(peerID, StringValueTypeDictionary.stringifyAttributes(["name": "Alice"]))
        doc.addOnlineClient(peerID)

        var events = [DocEvent]()
        doc.subscribePresence(.others) { event, _ in events.append(event) }

        // when - the peer's watch stream drops
        client.handleWatchDocumentsResponse(docKey: key, response: self.docEvent(.documentUnwatched, publisher: peerID))

        // then - hidden, an unwatched event carries the last presence, but the data is retained
        XCTAssertFalse(doc.getOthersPresences().contains { $0.clientID == peerID })
        XCTAssertNil(doc.getPresence(peerID))
        XCTAssertEqual(events.count, 1)
        let unwatched = events.first as? UnwatchedEvent
        XCTAssertNotNil(unwatched)
        XCTAssertEqual(unwatched?.value.clientID, peerID)
        XCTAssertEqual(unwatched?.value.presence["name"] as? String, "Alice")
        XCTAssertTrue(doc.hasPresence(peerID))

        // when - the peer's watch stream reconnects
        client.handleWatchDocumentsResponse(docKey: key, response: self.docEvent(.documentWatched, publisher: peerID))

        // then - visible again with the same presence and a watched event
        XCTAssertTrue(doc.getOthersPresences().contains { $0.clientID == peerID })
        XCTAssertEqual(doc.getPresence(peerID)?["name"] as? String, "Alice")
        XCTAssertEqual(events.count, 2)
        let watched = events.last as? WatchedEvent
        XCTAssertNotNil(watched)
        XCTAssertEqual(watched?.value.clientID, peerID)
        XCTAssertEqual(watched?.value.presence["name"] as? String, "Alice")
    }
}
