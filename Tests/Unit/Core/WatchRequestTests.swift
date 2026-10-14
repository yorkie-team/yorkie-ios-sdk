/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

@MainActor
final class WatchRequestTests: XCTestCase {
    func test_document_watch_request_declares_the_stable_actor() {
        let request = Client.makeDocumentWatchRequest(clientID: "session", actorID: "stable", documentID: "doc-1", heartbeatIntervalMs: 0)

        XCTAssertEqual(request.clientID, "session")
        XCTAssertEqual(request.actorID, "stable")
        XCTAssertEqual(request.resources.first?.document.documentID, "doc-1")
    }

    func test_document_watch_request_never_sends_the_session_id_as_the_actor() {
        let request = Client.makeDocumentWatchRequest(clientID: "session", actorID: nil, documentID: "doc-1", heartbeatIntervalMs: 0)

        XCTAssertEqual(request.clientID, "session")
        XCTAssertEqual(request.actorID, "")
    }

    func test_channel_watch_request_does_not_declare_an_actor() {
        // yorkie-js-sdk v0.7.25 createChannelWatchStream sends only clientId, heartbeatIntervalMs and
        // resources: a channel session is not a document actor.
        let request = Client.makeChannelWatchRequest(clientID: "session", channelKey: "room", heartbeatIntervalMs: 5000)

        XCTAssertEqual(request.clientID, "session")
        XCTAssertEqual(request.actorID, "")
        XCTAssertEqual(request.heartbeatIntervalMs, 5000)
        XCTAssertEqual(request.resources.first?.channel.channelKey, "room")
    }

    func test_the_client_never_sends_its_actor_on_the_channel_watch_request() {
        let client = Client("http://localhost", ClientOptions(), isMockingEnabled: true)
        let attachment = Attachment(resource: Document(key: "doc"), resourceID: "r")
        client.adoptAttachment(attachment, key: "doc", actorID: "stable")

        XCTAssertEqual(client.getActorID(), "stable")
        XCTAssertEqual(client.makeChannelWatchRequest(clientID: "session", channelKey: "room").actorID, "")
        XCTAssertEqual(client.makeDocumentWatchRequest(clientID: "session", documentID: "doc-1").actorID, "stable")
    }

    // MARK: - Heartbeat interval

    // The server heartbeats only the streams that ask, so a Watch request that carried nothing
    // would silently get no heartbeat and leave the idle watchdog disarmed. Both Watch requests
    // must carry the interval, built from the option the way `Client` builds them.

    private enum Kind: CaseIterable {
        case document
        case channel
    }

    private func requestedInterval(_ kind: Kind, _ options: ClientOptions = ClientOptions()) -> Int64 {
        let client = Client("http://localhost", options)
        let interval = client.watchHeartbeatIntervalMs
        switch kind {
        case .document:
            return Client.makeDocumentWatchRequest(clientID: "session", actorID: "stable", documentID: "doc-1", heartbeatIntervalMs: interval).heartbeatIntervalMs
        case .channel:
            return Client.makeChannelWatchRequest(clientID: "session", channelKey: "room", heartbeatIntervalMs: interval).heartbeatIntervalMs
        }
    }

    func test_watch_request_asks_for_the_default_heartbeat_interval_when_none_is_configured() {
        for kind in Kind.allCases {
            XCTAssertEqual(self.requestedInterval(kind), 20000, "\(kind)")
        }
    }

    func test_watch_request_asks_for_the_configured_heartbeat_interval() {
        for kind in Kind.allCases {
            XCTAssertEqual(self.requestedInterval(kind, ClientOptions(watchHeartbeatInterval: 7000)), 7000, "\(kind)")
        }
    }

    func test_watch_request_asks_for_no_heartbeat_when_the_interval_is_0() {
        for kind in Kind.allCases {
            XCTAssertEqual(self.requestedInterval(kind, ClientOptions(watchHeartbeatInterval: 0)), 0, "\(kind)")
        }
    }

    func test_watch_request_reads_a_negative_interval_as_asking_for_nothing() {
        // The option is a whole number of milliseconds, so JS's NaN case has no counterpart here.
        for kind in Kind.allCases {
            XCTAssertEqual(self.requestedInterval(kind, ClientOptions(watchHeartbeatInterval: -1)), 0, "\(kind)")
            XCTAssertEqual(self.requestedInterval(kind, ClientOptions(watchHeartbeatInterval: Int.min)), 0, "\(kind)")
        }
    }

    func test_watch_request_caps_an_interval_too_large_for_the_js_safe_integer_range() {
        let max: Int64 = 9_007_199_254_740_991
        for kind in Kind.allCases {
            XCTAssertEqual(self.requestedInterval(kind, ClientOptions(watchHeartbeatInterval: Int.max)), max, "\(kind)")
        }
        XCTAssertEqual(Client.toHeartbeatIntervalMs(Int(max)), max)
        XCTAssertEqual(Client.toHeartbeatIntervalMs(1), 1, "the smallest positive value is kept, not opted out")
    }
}
