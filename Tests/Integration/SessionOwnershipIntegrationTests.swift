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

// Drives the session and attachment ownership guards of yorkie-js-sdk #1522 / #1527 through a
// real request: the response hook (`setResponseHook`) runs a teardown, and sometimes a
// re-activation and re-attach, while the request is in flight, and the test checks that the late
// response leaves the newer state alone. Mirrors the cases of
// packages/sdk/test/unit/client/keepalive_deactivate_test.ts that apply on iOS.
//
// Requires a yorkie server at localhost:8080.

import Connect
import XCTest
@testable import Yorkie

/// Runs a hook body once, however many responses of its method arrive.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        self.lock.withLock {
            defer { self.fired = true }
            return !self.fired
        }
    }
}

final class SessionOwnershipIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    private typealias Methods = YorkieServiceClient.Metadata.Methods

    @MainActor
    private func makeClient() async throws -> Client {
        let client = Client(self.rpcAddress, isMockingEnabled: true)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }
        return client
    }

    private var docKey: String {
        "\(Date().timeIntervalSince1970)-\(self.name)".toDocKey
    }

    private func assertNotActivated(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? YorkieError)?.code, .errClientNotActivated, "\(error)", file: file, line: line)
    }

    // MARK: - attach

    @MainActor
    func test_does_not_register_a_document_attach_that_lands_after_the_teardown() async throws {
        // given - the client is deactivated while the AttachDocument request is in flight
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        let docIDBefore = doc.getDocID()
        let once = Once()
        client.setResponseHook(for: Methods.attachDocument) { _ in
            guard once.claim() else { return }
            try? await client.deactivate()
        }

        // when
        do {
            try await client.attach(doc, [:], .manual)
            XCTFail("the attach must fail")
        } catch {
            // then - it fails as an abandoned attach, and the stale response touched nothing
            self.assertNotActivated(error)
        }
        XCTAssertFalse(client.has(doc.getKey()))
        XCTAssertEqual(doc.status, .detached)
        XCTAssertEqual(doc.getDocID(), docIDBefore, "the stale response's document id must not be applied")
    }

    // MARK: - sync

    @MainActor
    func test_late_sync_response_does_not_touch_a_document_detached_by_teardown() async throws {
        // given - a remote change waits on the server for `doc`
        let key = self.docKey
        let client = try await self.makeClient()
        let doc = Document(key: key)
        try await client.attach(doc, [:], .manual)

        let other = try await self.makeClient()
        let otherDoc = Document(key: key)
        try await other.attach(otherDoc, [:], .manual)
        try otherDoc.update { root, _ in root.remote = "change" }
        try await other.sync(otherDoc)

        let once = Once()
        client.setResponseHook(for: Methods.pushPullChanges) { _ in
            guard once.claim() else { return }
            try? await client.deactivate()
        }

        // when - the pull comes back after the teardown
        _ = try? await client.sync(doc)

        // then - its change pack is not applied to the detached document
        XCTAssertEqual(doc.status, .detached)
        XCTAssertNil(doc.getRoot().remote)
    }

    @MainActor
    func test_a_remotely_removed_document_cancels_its_watch_stream() async throws {
        // given - another client removes the document
        let key = self.docKey
        let client = try await self.makeClient()
        let doc = Document(key: key)
        try await client.attach(doc, [:], .manual)
        let attachment = try XCTUnwrap(client.getDocumentAttachment(key))

        let other = try await self.makeClient()
        let otherDoc = Document(key: key)
        try await other.attach(otherDoc, [:], .manual)
        try await other.remove(otherDoc)

        // when - the sync learns of the removal
        try await client.sync(doc)

        // then - the attachment is torn down, its stream included, not just dropped from the map
        XCTAssertEqual(doc.status, .removed)
        XCTAssertFalse(client.has(key))
        XCTAssertTrue(attachment.cancelled)
    }

    // MARK: - detach / remove

    @MainActor
    func test_ignores_detach_success_after_teardown_and_keeps_the_reattached_document() async throws {
        // given - while a detach is in flight, the client is torn down, activated again, and
        // attaches a new document of the same key
        let key = self.docKey
        let client = try await self.makeClient()
        let doc = Document(key: key)
        try await client.attach(doc, [:], .manual)
        let reattached = Document(key: key)

        let once = Once()
        client.setResponseHook(for: Methods.detachDocument) { _ in
            guard once.claim() else { return }
            try? await client.deactivate()
            try? await client.activate()
            try? await client.attach(reattached, [:], .manual)
        }

        // when
        _ = try? await client.detach(doc)

        // then - the late response does not detach the newer attachment of the key
        XCTAssertEqual(reattached.status, .attached)
        XCTAssertTrue(client.getDocumentAttachment(key)?.resource === reattached)
        try await client.sync(reattached)
    }

    @MainActor
    func test_ignores_remove_success_after_teardown_and_permits_public_reattachment() async throws {
        // given - the client is deactivated while the RemoveDocument request is in flight
        let key = self.docKey
        let client = try await self.makeClient()
        let doc = Document(key: key)
        try await client.attach(doc, [:], .manual)

        let once = Once()
        client.setResponseHook(for: Methods.removeDocument) { _ in
            guard once.claim() else { return }
            try? await client.deactivate()
        }

        // when
        _ = try? await client.remove(doc)

        // then - the late response leaves the document as teardown left it
        XCTAssertEqual(doc.status, .detached)
        XCTAssertFalse(client.has(key))

        // and the key can be attached again through the public API. The server did remove the
        // document, so a fresh `Document` takes the key: the old one keeps the client sequence
        // of the removed document.
        try await client.activate()
        let reattached = Document(key: key)
        try await client.attach(reattached, [:], .manual)
        XCTAssertEqual(reattached.status, .attached)
        XCTAssertTrue(client.getDocumentAttachment(key)?.resource === reattached)
    }

    // MARK: - attachChannel

    @MainActor
    func test_an_attachChannel_that_loses_its_session_registers_nothing() async throws {
        // given - the client is deactivated while the first-call RefreshChannel is in flight
        let client = try await self.makeClient()
        let channel = try Channel(key: self.docKey)
        let once = Once()
        client.setResponseHook(for: Methods.refreshChannel) { _ in
            guard once.claim() else { return }
            try? await client.deactivate()
        }

        // when
        do {
            try await client.attachChannel(channel)
            XCTFail("the attach must fail")
        } catch {
            // then
            self.assertNotActivated(error)
        }
        XCTAssertFalse(client.has(channel.getKey()))
        XCTAssertEqual(channel.getStatus(), .detached)
    }
}
