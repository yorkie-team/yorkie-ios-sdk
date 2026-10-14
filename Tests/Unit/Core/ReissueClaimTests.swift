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

/// Ports the claim bookkeeping of `packages/sdk/test/unit/client/reissue_claim_test.ts` from
/// yorkie-js-sdk v0.7.25 (yorkie-js-sdk#1449 "Re-issue pre-attach tickets to the client's actor on
/// attach").
///
/// The JS suite drives `Client.attach` through a fake `rpcClient`. ``YorkieService`` only fakes
/// failures, not successful responses, so the attach-level scenarios ("pushes the pre-attach
/// changes under the client actor", "declines a second never-synced document of a key", ...) live
/// in `PreAttachIntegrationTests`, which needs a server. What a unit test can reach without one is
/// the decision itself: ``Client/claimReissue(_:docKey:)`` and ``Client/markReissueClaim(_:docKey:)``,
/// and the ``Document`` signal the client takes the claim from.
///
/// Not ported: "refuses to generate a key when it cannot be unguessable". The generated key is a
/// `UUID`, which draws from the system CSPRNG, so there is no weak-randomness case to refuse.
@MainActor
final class ReissueClaimTests: XCTestCase {
    private let actorA = "0000000000000000000000a1"
    private let actorB = "0000000000000000000000b1"

    func test_allows_a_re_issue_for_a_generated_key() {
        // given
        let client = Client("http://localhost:8080", ClientOptions())

        // when / then
        XCTAssertTrue(client.claimReissue(self.actorA, docKey: "doc"))
    }

    func test_does_not_allow_a_re_issue_under_an_explicit_client_key() {
        // given -- every session of an explicit key shares its stable actor, so a ticket re-issued
        // after a relaunch would equal one an earlier session's first edits carry, and the server
        // would keep one of the two elements.
        let client = Client("http://localhost:8080", ClientOptions(key: "reissue-claim-explicit-client"))

        // when / then
        XCTAssertFalse(client.claimReissue(self.actorA, docKey: "doc"))
    }

    func test_declines_a_second_document_of_a_key_once_the_claim_is_taken() {
        // given -- the re-issue keeps each lamport, so a second document re-issued to the same actor
        // would mint the tickets the first one may have pushed.
        let client = Client("http://localhost:8080", ClientOptions())
        XCTAssertTrue(client.claimReissue(self.actorA, docKey: "doc"))

        // when
        client.markReissueClaim(self.actorA, docKey: "doc")

        // then
        XCTAssertFalse(client.claimReissue(self.actorA, docKey: "doc"))
    }

    func test_asking_for_a_claim_takes_nothing() {
        // given -- a plain attach of an untouched document takes no claim: it records what the actor
        // minted, not that it once attached.
        let client = Client("http://localhost:8080", ClientOptions())

        // when
        XCTAssertTrue(client.claimReissue(self.actorA, docKey: "doc"))

        // then
        XCTAssertTrue(client.claimReissue(self.actorA, docKey: "doc"))
    }

    func test_scopes_the_claim_to_the_document_key() {
        // given -- the tickets the first document minted live in that document alone, so a second
        // one under another key has nothing to collide with.
        let client = Client("http://localhost:8080", ClientOptions())

        // when
        client.markReissueClaim(self.actorA, docKey: "key-one")

        // then
        XCTAssertFalse(client.claimReissue(self.actorA, docKey: "key-one"))
        XCTAssertTrue(client.claimReissue(self.actorA, docKey: "key-two"))
    }

    func test_scopes_the_claim_to_the_actor() {
        // given -- a retry under another actor re-issues from the first actor to its own.
        let client = Client("http://localhost:8080", ClientOptions())

        // when
        client.markReissueClaim(self.actorA, docKey: "doc")

        // then
        XCTAssertTrue(client.claimReissue(self.actorB, docKey: "doc"))
    }

    func test_an_untouched_document_has_minted_nothing() throws {
        // given -- the client takes the claim at attach only for a document that already carries
        // tickets, so an untouched one leaves the key free for the next document.
        let doc = Document(key: "doc")

        // when / then
        XCTAssertFalse(doc.hasMintedOperations())
    }

    func test_a_document_that_made_an_edit_has_minted_operations() throws {
        // given
        let doc = Document(key: "doc")

        // when
        try doc.update { root, _ in root.k = "v" }

        // then
        XCTAssertTrue(doc.hasMintedOperations())
    }

    func test_a_presence_only_change_mints_no_operations() throws {
        // given -- a presence change is not an operation, so it cannot collide on a ticket.
        let doc = Document(key: "doc")

        // when
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        // then
        XCTAssertFalse(doc.getPendingChangeStructs().isEmpty)
        XCTAssertFalse(doc.hasMintedOperations())
    }

    func test_an_undo_with_operations_counts_as_minting() throws {
        // given -- the undo is a local change carrying operations too.
        let doc = Document(key: "doc")
        try doc.update { root, _ in root.k = "v" }

        // when
        try doc.undo()

        // then
        XCTAssertTrue(doc.hasMintedOperations())
    }

    func test_restoring_appended_changes_counts_as_minting_only_when_they_carry_operations() throws {
        // given
        let source = Document(key: "doc")
        try source.update { root, _ in root.k = "v" }
        let stored = try source.getPendingChangesAfter(0)

        // when
        let withOperations = Document(key: "doc")
        try withOperations.restoreAppendedChanges(stored)
        let empty = Document(key: "doc")
        try empty.restoreAppendedChanges([])

        // then
        XCTAssertTrue(withOperations.hasMintedOperations())
        XCTAssertFalse(empty.hasMintedOperations())
    }
}
