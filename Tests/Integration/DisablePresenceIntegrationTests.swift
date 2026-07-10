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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// Port of yorkie-js-sdk packages/sdk/test/integration/disable_presence_test.ts at v0.7.12.
//
// The JS suite documents itself as end-to-end coverage for the `disablePresence` attach option
// paired with server-side support (yorkie-team/yorkie#1841). The local dev server this repo's
// tunnel targets (localhost:8080) turns out to already fixate `disable_presence` per document key
// across attaches, so the first three scenarios below assert the full JS expectation unrelaxed.
// The fourth (presence-content stripping across clients) is relaxed — see that test's comment.
final class DisablePresenceIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    // Ports: "First attach fixates disable_presence on DocInfo"
    @MainActor
    func test_first_attach_fixates_disable_presence_on_docinfo() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey, opts: DocumentOptions(disableGC: true, disablePresence: true))
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        // when
        try await client.attach(doc, [:], .manual, disableGC: true, disablePresence: true)
        self.addTeardownBlock { try? await client.detach(doc) }

        // then — the SDK reads back the server-fixated flag from the attach response.
        XCTAssertTrue(doc.isPresenceDisabled(), "first attach with disablePresence must observe the server-fixated true")
    }

    // Ports: "Late attacher without the option observes the persisted value"
    @MainActor
    func test_late_attacher_without_the_option_observes_the_persisted_value() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let d1 = Document(key: docKey, opts: DocumentOptions(disableGC: true, disablePresence: true))
        let d2 = Document(key: docKey)

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)
        try await c1.activate()
        try await c2.activate()
        self.addTeardownBlock {
            try? await c1.deactivate()
            try? await c2.deactivate()
        }

        // when — first attach fixates the document as presenceless.
        try await c1.attach(d1, [:], .manual, disableGC: true, disablePresence: true)
        self.addTeardownBlock { try? await c1.detach(d1) }

        // Second client attaches without the option but should observe the server-fixated true.
        try await c2.attach(d2, [:], .manual)
        self.addTeardownBlock { try? await c2.detach(d2) }

        // then
        XCTAssertTrue(d2.isPresenceDisabled(), "late attacher must observe the server-fixated value (true)")
    }

    // Ports: "Re-attach with the opposite option still observes the fixated value"
    @MainActor
    func test_reattach_with_the_opposite_option_still_observes_the_fixated_value() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let client = Client(rpcAddress)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        // when — first attach fixates the doc as presenceless.
        let d1 = Document(key: docKey, opts: DocumentOptions(disableGC: true, disablePresence: true))
        try await client.attach(d1, [:], .manual, disableGC: true, disablePresence: true)
        try await client.detach(d1)

        // Re-attach declaring the opposite option. The server returns the persisted true; the SDK
        // aligns local state from the response.
        let d2 = Document(key: docKey, opts: DocumentOptions(disableGC: true, disablePresence: false))
        try await client.attach(d2, [:], .manual, disableGC: true, disablePresence: false)
        self.addTeardownBlock { try? await client.detach(d2) }

        // then
        XCTAssertTrue(d2.isPresenceDisabled(), "re-attach must observe the persisted fixated value, not the request")
    }

    // Ports: "Presence emits from any client are stripped on a presenceless doc"
    //
    // Relaxed: the JS assertion is that the server strips presence *content* so `dOwner` never sees
    // any keys from `dOther`, even though `dOther` attached without the option and the peer's
    // client_id may still surface via `getPresences()`. Whether this dev server actually strips the
    // payload (as opposed to just fixating the flag, which the first three tests confirmed it does)
    // is a separate server-side capability we should not assume without direct evidence, so this
    // test verifies the invariant precisely: for every presence entry `dOwner` observes, the content
    // must be empty. If the server does strip (as its correct fixation behavior suggests it might),
    // this passes as written and matches the JS test exactly; if some future server regresses
    // stripping while keeping fixation, this is the test that catches it.
    @MainActor
    func test_presence_emits_from_any_client_are_stripped_on_a_presenceless_doc() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let dOwner = Document(key: docKey, opts: DocumentOptions(disableGC: true, disablePresence: true))
        let dOther = Document(key: docKey)

        let cOwner = Client(rpcAddress)
        let cOther = Client(rpcAddress)
        try await cOwner.activate()
        try await cOther.activate()
        self.addTeardownBlock {
            try? await cOwner.deactivate()
            try? await cOther.deactivate()
        }

        try await cOwner.attach(dOwner, [:], .manual, disableGC: true, disablePresence: true)
        self.addTeardownBlock { try? await cOwner.detach(dOwner) }

        // when — the opt-out client attaches without the option, then tries to set presence. The
        // server must strip the presence data so dOwner sees no presence content from the other
        // client, even if the peer's client_id surfaces via the watch / online-clients channel.
        try await cOther.attach(dOther, [:], .manual)
        self.addTeardownBlock { try? await cOther.detach(dOther) }

        try dOther.update { _, presence in
            presence.set(["name": "leaker"])
        }
        try await cOther.sync()
        try await cOwner.sync()

        // then — presence *content* never leaks across clients on a presenceless document. Peer
        // client_id enumeration (onlineClients) is orthogonal to the original symptom — the
        // accumulation that bloated AttachDocument responses was always the presence-data payload,
        // not the actor count.
        for entry in dOwner.getPresences() {
            XCTAssertTrue(entry.presence.isEmpty, "presenceless doc must surface no presence content; got \(entry.presence) for \(entry.clientID)")
        }
    }
}
