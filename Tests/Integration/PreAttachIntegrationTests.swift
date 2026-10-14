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

import Connect
import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Ports `packages/sdk/test/integration/pre_attach_test.ts` from yorkie-js-sdk v0.7.25
/// (yorkie-js-sdk#1449 "Re-issue pre-attach tickets to the client's actor on attach"), plus the
/// attach-level scenarios of `test/unit/client/reissue_claim_test.ts`, which the JS suite drives
/// through a fake `rpcClient` and iOS can only drive against a server.
///
/// Needs a yorkie server of v0.7.25 or later: an older one does not replay a pack whose tickets
/// name the client's actor the way these assertions expect.
@MainActor
final class PreAttachIntegrationTests: XCTestCase {
    private let rpcAddress = "http://localhost:8080"

    private func activeClients(_ count: Int, key: String? = nil) async throws -> [Client] {
        var clients = [Client]()
        for _ in 0 ..< count {
            let client = Client(self.rpcAddress, ClientOptions(key: key))
            try await client.activate()
            clients.append(client)
        }
        return clients
    }

    /// Sets a new Text under the given key of a detached document.
    private func fill(_ doc: Document, _ key: String, _ content: String) throws {
        try doc.update { root, _ in
            root[key] = JSONText()
            (root[key] as? JSONText)?.edit(0, 0, content)
        }
    }

    /// Returns the actor of the element under the given key.
    private func creatorOf(_ doc: Document, _ key: String) throws -> String {
        try XCTUnwrap(doc.getRootObject().get(key: key)).createdAt.actorID
    }

    private func docKey(_ suffix: String = "") -> String {
        "\(self.description)-\(Int(Date().timeIntervalSince1970 * 1000))\(suffix)".toDocKey
    }

    func test_converges_two_clients_that_filled_the_same_key_before_attach() async throws {
        // Their elements are created under the initial actor, so two clients that fill the same key
        // used to push values with the same createdAt.
        let docKey = self.docKey()

        var last = ""
        var lastText = ""
        for round in 0 ..< 3 {
            let clients = try await self.activeClients(2)
            let docs = [Document(key: docKey), Document(key: docKey)]
            let contents = ["round\(round)-c1", "round\(round)-c2"]
            for (index, doc) in docs.enumerated() {
                try doc.update { root, _ in
                    root.k1 = JSONText()
                    (root.k1 as? JSONText)?.edit(0, 0, contents[index])
                    root.o = ["by": contents[index]] as [String: Any]
                }
            }

            for (index, doc) in docs.enumerated() {
                try await clients[index].attach(doc, [:], .manual)
            }
            for client in clients + [clients[0]] {
                try await client.sync()
            }
            XCTAssertEqual(docs[0].toSortedJSON(), docs[1].toSortedJSON())

            // One whole client's write wins every key, never a mix or nothing. Every pre-attach
            // write has lamport 1, so the previous round's winner may still win by the actor
            // tie-break -- but nothing older.
            let text = try XCTUnwrap((docs[0].getRoot().k1 as? JSONText)?.toString)
            let candidates = lastText.isEmpty ? contents : contents + [lastText]
            XCTAssertTrue(candidates.contains(text), docs[0].toSortedJSON())
            lastText = text
            XCTAssertEqual((docs[0].getRoot().o as? JSONObject)?.by as? String, text)
            last = docs[0].toSortedJSON()

            for client in clients {
                try await client.deactivate()
            }
        }

        let observer = try await self.activeClients(1)[0]
        let observed = Document(key: docKey)
        try await observer.attach(observed, [:], .manual)
        XCTAssertEqual(observed.toSortedJSON(), last)
        try await observer.deactivate()
    }

    func test_re_issues_pre_attach_tickets_to_the_client_actor() async throws {
        // given
        let clients = try await self.activeClients(2)
        let (c1, c2) = (clients[0], clients[1])
        let doc = Document(key: self.docKey())
        try self.fill(doc, "k1", "abc")
        XCTAssertEqual(try self.creatorOf(doc, "k1"), ActorIDs.initial)

        // when
        try await c1.attach(doc, [:], .manual)

        // then
        XCTAssertEqual(try self.creatorOf(doc, "k1"), c1.getActorID())
        XCTAssertEqual(doc.toSortedJSON(), "{\"k1\":[{\"val\":\"abc\"}]}")

        let observed = Document(key: doc.getKey())
        try await c2.attach(observed, [:], .manual)
        XCTAssertEqual(observed.toSortedJSON(), doc.toSortedJSON())
        XCTAssertEqual(try self.creatorOf(observed, "k1"), c1.getActorID())

        try await c1.deactivate()
        try await c2.deactivate()
    }

    func test_does_not_re_issue_a_second_pre_attach_document_of_a_key() async throws {
        // A re-issue keeps the lamports, and a fresh document starts them at 1, so re-issuing this
        // one to the same actor would mint the createdAt the first attach already pushed. The tickets
        // keep the initial actor.
        let docKey = self.docKey()
        let clients = try await self.activeClients(2)
        let (client, observer) = (clients[0], clients[1])

        let doc1 = Document(key: docKey)
        try self.fill(doc1, "first", "a")
        try await client.attach(doc1, [:], .manual)
        XCTAssertEqual(try self.creatorOf(doc1, "first"), client.getActorID())
        try await client.detach(doc1)

        let doc2 = Document(key: docKey)
        try self.fill(doc2, "second", "b")
        try await client.attach(doc2, [:], .manual)
        XCTAssertEqual(try self.creatorOf(doc2, "second"), ActorIDs.initial)

        // Both elements survive. Read them through another client: a pull drops the changes the
        // pulling actor itself pushed up to its checkpoint's clientSeq, and doc2 repeated the
        // clientSeq doc1 pushed under, so its own pull filters doc1's change out (yorkie#2123).
        let observed = Document(key: docKey)
        try await observer.attach(observed, [:], .manual)
        XCTAssertEqual(observed.toSortedJSON(), "{\"first\":[{\"val\":\"a\"}],\"second\":[{\"val\":\"b\"}]}")

        try await client.deactivate()
        try await observer.deactivate()
    }

    func test_re_issues_a_later_document_of_a_key_the_first_left_untouched() async throws {
        // A plain attach takes no claim. The first document minted no operation ticket under the
        // actor, so its lamports in that key are still free and the next document of the key
        // re-issues onto them.
        let docKey = self.docKey()
        let client = try await self.activeClients(1)[0]

        let first = Document(key: docKey)
        try await client.attach(first, [:], .manual)
        try await client.detach(first)

        let second = Document(key: docKey)
        try self.fill(second, "second", "two")
        try await client.attach(second, [:], .manual)

        XCTAssertEqual(try self.creatorOf(second, "second"), client.getActorID())
        try await client.deactivate()
    }

    func test_declines_a_later_document_when_the_first_minted_while_attached() async throws {
        // The first document minted its tickets under the actor after it was attached, so the claim
        // is taken on the way out (`detachInternal`): a re-issue of the second one would mint the
        // lamports the first pushed.
        let docKey = self.docKey()
        let client = try await self.activeClients(1)[0]

        let first = Document(key: docKey)
        try await client.attach(first, [:], .manual)
        try self.fill(first, "first", "one")
        try await client.detach(first)

        let second = Document(key: docKey)
        try self.fill(second, "second", "two")
        try await client.attach(second, [:], .manual)

        XCTAssertEqual(try self.creatorOf(second, "second"), ActorIDs.initial)
        try await client.deactivate()
    }

    func test_re_issues_a_second_never_synced_document_of_another_key() async throws {
        // The claim is per document key: the tickets the first document minted live in that document
        // alone, so a second one under another key has nothing to collide with and still re-issues.
        let client = try await self.activeClients(1)[0]

        let first = Document(key: self.docKey("-one"))
        try self.fill(first, "first", "one")
        try await client.attach(first, [:], .manual)

        let second = Document(key: self.docKey("-two"))
        try self.fill(second, "second", "two")
        try await client.attach(second, [:], .manual)

        XCTAssertEqual(try self.creatorOf(first, "first"), client.getActorID())
        XCTAssertEqual(try self.creatorOf(second, "second"), client.getActorID())
        try await client.deactivate()
    }

    func test_does_not_re_issue_when_the_attach_options_are_rejected() async throws {
        // Option validation runs before the re-issue, so an attach rejected for a bad option leaves
        // the document and the claim alone.
        let client = try await self.activeClients(1)[0]
        let doc = Document(key: self.docKey())
        try self.fill(doc, "k", "hello")

        // when
        do {
            try await client.attach(doc, [:], .polling, documentPollInterval: 0)
            XCTFail("attach should reject a non-positive poll interval")
        } catch {
            XCTAssertTrue("\(error)".contains("documentPollInterval"))
        }

        // then
        XCTAssertEqual(doc.changeID.getActorID(), ActorIDs.initial)
        XCTAssertTrue(doc.canUndo)

        // The claim was not taken either, so the valid retry still re-issues.
        try await client.attach(doc, [:], .manual)
        XCTAssertEqual(try self.creatorOf(doc, "k"), client.getActorID())
        try await client.deactivate()
    }

    func test_keeps_the_re_issued_state_when_the_attach_fails() async throws {
        // There is no rollback: a re-issued document is a valid detached document, and a retry under
        // the same client re-issues nothing because the claim is taken before the round trip.
        let client = Client(self.rpcAddress, ClientOptions(), isMockingEnabled: true)
        try await client.activate()
        let doc = Document(key: self.docKey())
        try self.fill(doc, "k", "hello")
        client.setMockError(
            for: YorkieServiceClient.Metadata.Methods.attachDocument,
            error: ConnectError(code: .unavailable, message: "lost")
        )

        // when
        do {
            try await client.attach(doc, [:], .manual)
            XCTFail("attach should fail")
        } catch {}

        // then
        XCTAssertEqual(doc.changeID.getActorID(), client.getActorID())
        XCTAssertEqual(try self.creatorOf(doc, "k"), client.getActorID())
        XCTAssertEqual(doc.toSortedJSON(), "{\"k\":[{\"val\":\"hello\"}]}")
        try await client.deactivate()
    }

    func test_keeps_an_earlier_session_of_an_explicit_client_key() async throws {
        // Every session of an explicit key shares its stable actor. A re-issue in the second session
        // would mint the tickets the first session's first edits carry, and the server would keep one
        // of the two elements, so pre-attach tickets under an explicit key keep the initial actor.
        let docKey = self.docKey()
        let clientKey = "\(docKey)-client"

        let first = try await self.activeClients(1, key: clientKey)[0]
        let doc1 = Document(key: docKey)
        try await first.attach(doc1, [:], .manual)
        try self.fill(doc1, "first", "a")
        try await first.sync()
        try await first.deactivate()

        let second = try await self.activeClients(1, key: clientKey)[0]
        XCTAssertEqual(second.getActorID(), first.getActorID())
        let doc2 = Document(key: docKey)
        try self.fill(doc2, "second", "b")
        try await second.attach(doc2, [:], .manual)
        XCTAssertEqual(try self.creatorOf(doc2, "second"), ActorIDs.initial)

        let observer = try await self.activeClients(1)[0]
        let observed = Document(key: docKey)
        try await observer.attach(observed, [:], .manual)
        XCTAssertEqual(observed.toSortedJSON(), "{\"first\":[{\"val\":\"a\"}],\"second\":[{\"val\":\"b\"}]}")

        try await second.deactivate()
        try await observer.deactivate()
    }
}
