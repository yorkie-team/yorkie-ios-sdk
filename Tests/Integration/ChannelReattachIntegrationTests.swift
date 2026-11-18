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

// Ports the identity cases of yorkie-js-sdk 0.7.27 (#1527) packages/sdk/test/integration/channel_test.ts,
// "re-attaching the same key while the previous detach is pending". iOS `detachChannel` is local and
// synchronous, so the pending-detach race does not exist; what is left is that a detach resolves the
// attachment by Channel identity, and that deactivate reaches an attachment a same-key attach evicted.
// Needs a live server at localhost:8080.
final class ChannelReattachIntegrationTests: XCTestCase {
    private let rpcAddress = "http://localhost:8080"

    private func uniqueKey(_ suffix: String) -> String {
        "\(UUID().uuidString.lowercased().prefix(8))-reattach-\(suffix)"
    }

    @MainActor
    func test_keeps_the_new_channel_when_the_old_one_is_detached_after_re_attach() async throws {
        // given - `old` was attached, then `next` attached under the same key
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }
        let key = self.uniqueKey("keep")
        let old = try Channel(key: key)
        try await client.attachChannel(old)
        let next = try Channel(key: key)
        try await client.attachChannel(next)
        XCTAssertTrue(next.isAttached())

        // when - the stale Channel object detaches
        do {
            try await client.detachChannel(old)
            XCTFail("detaching a replaced Channel must throw")
        } catch {
            XCTAssertEqual((error as? YorkieError)?.code, .errNotAttached)
        }

        // then - the channel that took the key is still held and attached
        XCTAssertTrue(client.has(key))
        XCTAssertTrue(next.isAttached())
        let count = try await client.syncChannel(next)
        XCTAssertGreaterThanOrEqual(count, 1)

        // and it detaches normally
        try await client.detachChannel(next)
        XCTAssertFalse(client.has(key))
        XCTAssertFalse(next.isAttached())
    }

    @MainActor
    func test_detaches_a_channel_attached_again_after_its_own_detach() async throws {
        // given
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }
        let key = self.uniqueKey("cycle")
        let old = try Channel(key: key)
        try await client.attachChannel(old)

        // when - detach, then a new Channel of the same key attaches
        try await client.detachChannel(old)
        let next = try Channel(key: key)
        try await client.attachChannel(next)

        // then
        XCTAssertFalse(old.isAttached())
        XCTAssertTrue(next.isAttached())
        XCTAssertTrue(client.has(key))
        try await client.detachChannel(next)
    }

    @MainActor
    func test_deactivate_detaches_a_channel_a_same_key_attach_evicted() async throws {
        // given - two live Channels of one key; the second took the key from the first
        let client = Client(rpcAddress)
        try await client.activate()
        let key = self.uniqueKey("orphan")
        let first = try Channel(key: key)
        let second = try Channel(key: key)
        try await client.attachChannel(first)
        try await client.attachChannel(second)

        // when
        try await client.deactivate()

        // then - both are torn down, not only the one the key names
        XCTAssertFalse(client.isActive)
        XCTAssertFalse(first.isAttached())
        XCTAssertFalse(second.isAttached())
        XCTAssertFalse(client.has(key))
    }
}
