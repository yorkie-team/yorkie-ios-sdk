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

/// Ported from `client_options_test.ts`'s "Client key with offline persistence" suite
/// (yorkie-js-sdk#1402/#1385).
///
/// iOS's `Logger` (`Sources/Core/Logger.swift`) wraps swift-log with no test-capture seam --
/// unlike `console.warn`, which JS's tests spy on directly -- so the emitted warning's text
/// itself is not asserted here. What is covered instead is the behaviour the warning exists to
/// flag: a store configured without a client key still gets a usable (non-empty, generated) key
/// rather than failing or producing an empty one, and an explicitly supplied key is used as-is.
/// Also covers this commit's second fix reachable without a server: `storeKey`/`sessionLockName`
/// escaping a separator in a component so two distinct identities cannot collide on one
/// namespace.
@MainActor
final class ClientKeyWarningTests: XCTestCase {
    func test_keeps_the_generated_key_when_only_a_store_is_configured() throws {
        // given / when — a store is configured but no key is supplied.
        let client = Client("http://localhost:8080", ClientOptions(store: MemoryDocStore()))

        // then — a key was still generated, so the client remains usable (the warning is a
        // diagnostic, not a hard failure).
        XCTAssertFalse(client.key.isEmpty)
    }

    func test_uses_the_given_key_when_store_is_configured() throws {
        // given / when
        let client = Client("http://localhost:8080", ClientOptions(key: "stable-key", store: MemoryDocStore()))

        // then — supplying a key must not be overridden by the generated fallback.
        XCTAssertEqual(client.key, "stable-key")
    }

    func test_does_not_require_a_key_when_no_store_is_configured() throws {
        // given / when — no store, no key: the combination the warning does not apply to.
        let client = Client("http://localhost:8080", ClientOptions())

        // then
        XCTAssertFalse(client.key.isEmpty)
    }

    func test_store_key_escapes_a_separator_so_two_identities_cannot_collide() throws {
        // given — two distinct (clientKey, docKey) identities that would join to the same bare
        // "apiKey/clientKey/docKey" string if the separator inside a component were not escaped.
        let clientA = Client("http://localhost:8080", ClientOptions(key: "a/b"))
        let clientB = Client("http://localhost:8080", ClientOptions(key: "a"))

        // when
        let storeKeyA = clientA.storeKey("c")
        let storeKeyB = clientB.storeKey("b/c")

        // then — escaping `/` inside a component keeps the two identities from addressing the
        // same persisted envelope.
        XCTAssertNotEqual(storeKeyA, storeKeyB)
    }

    func test_session_lock_name_escapes_a_separator_so_two_identities_cannot_collide() throws {
        // given
        let clientA = Client("http://localhost:8080", ClientOptions(key: "a/b"))
        let clientB = Client("http://localhost:8080", ClientOptions(key: "a"))

        // when
        let lockNameA = clientA.sessionLockName("c")
        let lockNameB = clientB.sessionLockName("b/c")

        // then
        XCTAssertNotEqual(lockNameA, lockNameB)
    }

    func test_store_key_is_unaffected_by_escaping_for_ordinary_keys() throws {
        // given — keys with no separator or escape character, the overwhelming common case.
        let client = Client("http://localhost:8080", ClientOptions(key: "client-1"))

        // when / then — escaping must be a no-op here, matching the pre-existing bare-join
        // format exactly (other tests and stored envelopes depend on this shape).
        XCTAssertEqual(client.storeKey("doc-1"), "/client-1/doc-1")
        XCTAssertEqual(client.sessionLockName("doc-1"), "yorkie-session:/client-1/doc-1")
    }
}
