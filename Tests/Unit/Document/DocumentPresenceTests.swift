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

final class DocumentPresenceTests: XCTestCase {
    // Mirrors yorkie-js-sdk document_test.ts "should retain presence after watch stream
    // reconnection" (#1186). Verifies the Document-level invariant the fix introduced: a stale
    // presence is NOT pruned when its client leaves the online set, but `getPresences` /
    // `getOthersPresences` filter it out — so when the peer re-watches, its retained presence
    // resurfaces. The matching `.watched` event emission lives in the client watch-event handler,
    // which relies on this retained presence to fire.
    @MainActor
    func test_should_retain_presence_after_watch_stream_reconnection() {
        // given — a peer with injected presence, currently online
        let doc = Document(key: "test-doc")
        let peerID = "peer-client-id"
        doc.setPresenceForTest(peerID, StringValueTypeDictionary.stringifyAttributes(["name": "Alice"]))
        doc.addOnlineClient(peerID)

        XCTAssertTrue(doc.hasPresence(peerID))
        XCTAssertTrue(doc.getOthersPresences().contains { $0.clientID == peerID })

        // when — the watch stream reconnects and the peer is momentarily absent from the online set
        // (iOS equivalent of applyWatchInit([]); presences are intentionally NOT pruned)
        doc.setOnlineClients([])

        // then — the peer is hidden from the filtered API, but its presence is retained internally
        XCTAssertFalse(doc.getOthersPresences().contains { $0.clientID == peerID })
        XCTAssertTrue(doc.hasPresence(peerID))

        // when — the peer's watch stream reconnects (re-added to the online set)
        doc.addOnlineClient(peerID)

        // then — the peer is visible again with its original presence intact
        XCTAssertTrue(doc.getOthersPresences().contains { $0.clientID == peerID })
        XCTAssertEqual(doc.getPresence(peerID)?["name"] as? String, "Alice")
    }
}
