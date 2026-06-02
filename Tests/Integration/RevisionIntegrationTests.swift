/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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
@testable import YorkieTestHelper

final class RevisionIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    @MainActor
    func test_can_create_a_revision_and_list_revisions() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)
        let client = Client(self.rpcAddress)

        try await client.activate()
        try await client.attach(doc, [:], .manual)

        // 01. Make initial changes.
        try doc.update({ root, _ in root.k1 = "v1" }, "add k1")
        try await client.sync()

        // 02. Create a revision.
        let rev = try await client.createRevision(doc, label: "v1.0", description: "First revision")
        XCTAssertEqual(rev.label, "v1.0")
        XCTAssertEqual(rev.description, "First revision")

        // 03. Make more changes.
        try doc.update({ root, _ in root.k2 = "v2" }, "add k2")
        try await client.sync()

        // 04. Create another revision.
        let rev2 = try await client.createRevision(doc, label: "v2.0", description: "Second revision")
        XCTAssertEqual(rev2.label, "v2.0")

        // 05. List all revisions (newest first).
        let revisions = try await client.listRevisions(doc)
        XCTAssertTrue(revisions.count >= 2)
        XCTAssertEqual(revisions[0].label, "v2.0")
        XCTAssertEqual(revisions[1].label, "v1.0")

        try await client.detach(doc)
        try await client.deactivate()
    }

    @MainActor
    func test_should_handle_revision_pagination() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)
        let client = Client(self.rpcAddress)

        try await client.activate()
        try await client.attach(doc, [:], .manual)

        // Create multiple revisions.
        for index in 1 ... 5 {
            try doc.update { root, _ in root.count = Int64(index) }
            try await client.sync()
            try await client.createRevision(doc, label: "v\(index).0", description: "Revision \(index)")
        }

        // List with pagination.
        let firstPage = try await client.listRevisions(doc, pageSize: 3)
        XCTAssertEqual(firstPage.count, 3)

        let secondPage = try await client.listRevisions(doc, pageSize: 3, offset: 3)
        XCTAssertEqual(secondPage.count, 2)

        try await client.detach(doc)
        try await client.deactivate()
    }

    @MainActor
    func test_can_restore_to_a_revision() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey
        let doc = Document(key: docKey)
        let client = Client(self.rpcAddress)

        try await client.activate()
        try await client.attach(doc, [:], .manual)

        // 01. Create initial state.
        try doc.update({ root, _ in
            root.k1 = "v1"
            root.k2 = "v2"
        }, "initial state")
        try await client.sync()

        // 02. Create a revision of the initial state.
        let revision = try await client.createRevision(doc, label: "v1.0", description: "Initial state")

        // 03. Make more changes.
        try doc.update({ root, _ in
            root.k1 = "modified"
            root.k2 = "v3"
        }, "modify document")
        try await client.sync()

        // 04. Verify the document was modified.
        var k1 = await doc.getRoot().k1 as? String
        var k2 = await doc.getRoot().k2 as? String
        XCTAssertEqual(k1, "modified")
        XCTAssertEqual(k2, "v3")

        // 05. Restore to the revision.
        try await client.restoreRevision(doc, revisionID: revision.id)

        // 06. Sync to get the restored state.
        try await client.sync()

        // 07. Verify the document was restored to the initial state.
        k1 = await doc.getRoot().k1 as? String
        k2 = await doc.getRoot().k2 as? String
        XCTAssertEqual(k1, "v1")
        XCTAssertEqual(k2, "v2")

        try await client.detach(doc)
        try await client.deactivate()
    }

    @MainActor
    func test_should_propagate_restore_to_other_clients() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // 01. Client1 creates initial state.
            try d1.update({ root, _ in
                root.k1 = "v1"
                root.k2 = "v2"
            }, "initial state")
            try await c1.sync()
            try await c2.sync()

            // 02. Both clients share the same state.
            var d2k1 = await d2.getRoot().k1 as? String
            XCTAssertEqual(d2k1, "v1")

            // 03. Client1 creates a revision.
            let revision = try await c1.createRevision(d1, label: "v1.0", description: "Initial state")

            // 04. Client1 makes changes.
            try d1.update({ root, _ in
                root.k1 = "modified"
                root.k2 = "v3"
            }, "modify document")
            try await c1.sync()
            try await c2.sync()

            // 05. Both clients have the modified state.
            d2k1 = await d2.getRoot().k1 as? String
            XCTAssertEqual(d2k1, "modified")

            // 06. Client1 restores to the revision.
            try await c1.restoreRevision(d1, revisionID: revision.id)
            try await c1.sync()

            // 07. Client2 syncs to receive the restore.
            try await c2.sync()

            // 08. Both clients are restored to the initial state.
            let d1k1 = await d1.getRoot().k1 as? String
            let d1k2 = await d1.getRoot().k2 as? String
            d2k1 = await d2.getRoot().k1 as? String
            let d2k2 = await d2.getRoot().k2 as? String
            XCTAssertEqual(d1k1, "v1")
            XCTAssertEqual(d1k2, "v2")
            XCTAssertEqual(d2k1, "v1")
            XCTAssertEqual(d2k2, "v2")
        }
    }
}
