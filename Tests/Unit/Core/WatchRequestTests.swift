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
        let request = Client.makeDocumentWatchRequest(clientID: "session", actorID: "stable", documentID: "doc-1")

        XCTAssertEqual(request.clientID, "session")
        XCTAssertEqual(request.actorID, "stable")
        XCTAssertEqual(request.resources.first?.document.documentID, "doc-1")
    }

    func test_document_watch_request_never_sends_the_session_id_as_the_actor() {
        let request = Client.makeDocumentWatchRequest(clientID: "session", actorID: nil, documentID: "doc-1")

        XCTAssertEqual(request.clientID, "session")
        XCTAssertEqual(request.actorID, "")
    }

    func test_channel_watch_request_declares_the_stable_actor() {
        let request = Client.makeChannelWatchRequest(clientID: "session", actorID: "stable", channelKey: "room")

        XCTAssertEqual(request.actorID, "stable")
        XCTAssertEqual(request.resources.first?.channel.channelKey, "room")
    }

    func test_channel_watch_request_never_sends_the_session_id_as_the_actor() {
        let request = Client.makeChannelWatchRequest(clientID: "session", actorID: nil, channelKey: "room")

        XCTAssertEqual(request.clientID, "session")
        XCTAssertEqual(request.actorID, "")
    }
}
