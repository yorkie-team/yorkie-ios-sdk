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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

class DocumentSchemaTest: XCTestCase {
    var apiKey: String {
        self.context.publicKey
    }

    var secretKey: String {
        self.context.secretKey
    }

    var webhookServer: WebhookServer!
    var context: YorkieProjectContext!

    override func setUp() async throws {
        try await super.setUp()
        (self.webhookServer, self.context) = try await ServerInfo.setUpServer()
    }

    override func tearDown() async throws {
        self.webhookServer.stop()
        // Prevents duplication of project ID (based on timeInterval)
        try await Task.sleep(milliseconds: 1000)
    }

    @MainActor
    func test_initialize_project_successfully() async throws {
        XCTAssertTrue(!self.context.publicKey.isEmpty)
        XCTAssertTrue(!self.context.secretKey.isEmpty)
    }

    func whenSetUpSchema(time: String) async {
        do {
            try await YorkieProjectHelper.createSchema(
                rpcAddress: ServerInfo.rpcAddress,
                date: time,
                projectApiKey: self.context.publicKey,
                projectSecretKey: self.secretKey
            )
        } catch {
            fatalError("Fail create schema!")
        }
    }
}

extension DocumentSchemaTest {
    // can attach document with schema
    func testCanAttachDocumentWithSchema() async throws {
        let docKey = "\(#function)-\(Date().timeIntervalSince1970)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        do {
            try await client.attach(doc, [:], .manual, "noexist@1")
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, "find schema of noexist@1: schema not found")
        }

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await client.deactivate()
    }

    // should reject local update that violates schema
    func testShouldRejectLocalUpdateThatViolatesSchema() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        do {
            try await doc.update { root, _ in
                root["title"] = Int32(123)
            }
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? Yorkie.YorkieError else { fatalError() }
            print("success")
            XCTAssertEqual(
                error.message,
                "schema validation failed: Expected primitive(Yorkie.PrimitiveType.string) at path $.title"
            )
        }

        var docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, "{}")

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)
        try await client.deactivate()
    }

    // can update schema with new rules via UpdateDocument API
    func testCanUpdateSchemaWithNewRulesViaUpdateDocumentAPI() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        var docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)
        try await client.detach(doc)

        let updateBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": #"{"title": Int(123)}"#,
            "schemaKey": "schema2-\(time)@1"
        ]

        try await YorkieProjectHelper.updateDocument(
            rpcAddress: ServerInfo.rpcAddress,
            updateBody: updateBody,
            time: time,
            token: self.secretKey
        )
        let doc2 = Document(key: docKey)
        try await client.attach(doc2, [:], .manual)

        docJSON = await doc2.toSortedJSON()

        XCTAssertEqual(docJSON, """
        {"title":123}
        """)

        try await client.deactivate()
    }

    // should reject schema update when document is attached
    func testShouldRejectSchemaUpdateWhenDocumentIsAttached() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        let updateBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": #"{"title": Int(123)}"#,
            "schemaKey": "schema2-\(time)@1"
        ]

        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: updateBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError else { fatalError() }
            if case .invalidResponse(let status) = error {
                XCTAssertEqual(
                    status["message"] as? String ?? "",
                    "document is attached"
                )
            } else {
                XCTFail("Wrong returned message")
            }
        }
    }

    // should reject schema update when existing root violates new schema'
    func testShouldRejectSchemaUpdateWhenExistingRootViolatesNewSchema() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        let docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)
        try await client.detach(doc)

        let updateBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": #"{"title": Long(123)}"#,
            "schemaKey": "schema2-\(time)@1"
        ]
        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: updateBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError else { fatalError() }
            if case .invalidResponse(let status) = error {
                XCTAssertEqual(
                    status["message"] as? String ?? "",
                    "schema validation failed: expected integer at path $.title"
                )
            } else {
                XCTFail("Wrong returned message")
            }
        }
    }

    // can detach schema via UpdateDocument API
    func testCanDetachSchemaViaUpdateDocumentAPI() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        var docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)

        let detachBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": "",
            "schemaKey": ""
        ]
        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: detachBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError else { fatalError() }
            if case .invalidResponse(let status) = error {
                XCTAssertEqual(
                    status["message"] as? String ?? "",
                    "document is attached"
                )
            } else {
                XCTFail("Wrong returned message")
            }
        }

        try await client.detach(doc)
        try await YorkieProjectHelper.updateDocument(
            rpcAddress: ServerInfo.rpcAddress,
            updateBody: detachBody,
            time: time,
            token: self.secretKey
        )

        let doc2 = Document(key: docKey)
        try await client.attach(doc2, [:], .manual)
        docJSON = await doc2.toSortedJSON()

        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)
        try await doc2.update { root, _ in
            root["title"] = Int32(123)
        }

        docJSON = await doc2.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":123}
        """)

        try await client.deactivate()
    }

    // can attach schema via UpdateDocument API
    func testCanAttachSchemaViaUpdateDocumentAPI() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        var docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)

        let attachBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": "",
            "schemaKey": "schema2-\(time)@1"
        ]
        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: attachBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError else { fatalError() }
            if case .invalidResponse(let status) = error {
                XCTAssertEqual(
                    status["message"] as? String ?? "",
                    "document is attached"
                )
            } else {
                XCTFail("Wrong returned message")
            }
        }

        try await client.detach(doc)

        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: attachBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError else { fatalError() }
            if case .invalidResponse(let status) = error {
                XCTAssertEqual(
                    status["message"] as? String ?? "",
                    "schema validation failed: expected integer at path $.title"
                )
            } else {
                XCTFail("Wrong returned message")
            }
        }

        let reattachBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": "",
            "schemaKey": "schema1-\(time)@1"
        ]

        try await YorkieProjectHelper.updateDocument(
            rpcAddress: ServerInfo.rpcAddress,
            updateBody: reattachBody,
            time: time,
            token: self.secretKey
        )

        let doc2 = Document(key: docKey)
        try await client.attach(doc2, [:], .manual)

        docJSON = await doc2.toSortedJSON()

        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        do {
            try await doc2.update { root, _ in
                root["title"] = Int32(123)
            }
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? Yorkie.YorkieError else { fatalError() }
            XCTAssertEqual(
                error.message,
                "schema validation failed: Expected primitive(Yorkie.PrimitiveType.string) at path $.title"
            )
        }

        try await client.deactivate()
    }

    // can update root only
    func testCanUpdateSchemaOnly() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)

        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        let docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)
        try await client.detach(doc)

        let updateBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": "",
            "schemaKey": "schema2-\(time)@1"
        ]

        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: updateBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError, case .invalidResponse(let status) = error else { fatalError() }
            XCTAssertEqual(
                status["message"] as? String ?? "",
                "schema validation failed: expected integer at path $.title"
            )
        }
        try await client.deactivate()
    }

    // can update root only
    func testCanUpdateRootOnly() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        var docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)

        let updateBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": #"{"title": Int(123)}"#,
            "schemaKey": ""
        ]
        try await YorkieProjectHelper.updateDocument(
            rpcAddress: ServerInfo.rpcAddress,
            updateBody: updateBody,
            time: time,
            token: self.secretKey
        )
        try await client.detach(doc)
        let doc2 = Document(key: docKey)
        try await client.attach(doc2, [:], .manual)
        docJSON = await doc2.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":123}
        """)
    }

    // can update root only when document has attached schema
    func testCanUpdateRootOnlyWhenDocumentHasAttachedSchema() async throws {
        let docKey = "doc-size-\(Date().description)".toDocKey
        let time = "\(Date().timeIntervalSince1970)"
        await self.whenSetUpSchema(time: time)

        let client = await Client.makeMock(apiKey: self.apiKey)
        try await client.activate()

        let doc = Document(key: docKey)
        let schema = "schema1-" + time + "@1"
        try await client.attach(doc, [:], .manual, schema)

        try await doc.update { root, _ in
            root["title"] = "hello"
        }

        var docJSON = await doc.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"hello"}
        """)

        try await client.sync(doc)
        try await client.detach(doc)

        let updateBody: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": #"{"title": Int(123)}"#,
            "schemaKey": ""
        ]
        do {
            try await YorkieProjectHelper.updateDocument(
                rpcAddress: ServerInfo.rpcAddress,
                updateBody: updateBody,
                time: time,
                token: self.secretKey
            )
            XCTFail("The API should not be success!")
        } catch {
            guard let error = error as? YorkieProjectError, case .invalidResponse(let status) = error else { fatalError() }
            XCTAssertEqual(
                status["message"] as? String ?? "",
                "schema validation failed: expected string at path $.title"
            )
        }

        let updateBody2: [String: Any] = [
            "projectName": "default",
            "documentKey": docKey,
            "root": #"{"title": "world"}"#,
            "schemaKey": ""
        ]
        try await YorkieProjectHelper.updateDocument(
            rpcAddress: ServerInfo.rpcAddress,
            updateBody: updateBody2,
            time: time,
            token: self.secretKey
        )
        let doc2 = Document(key: docKey)
        try await client.attach(doc2, [:], .manual)
        docJSON = await doc2.toSortedJSON()
        XCTAssertEqual(docJSON, """
        {"title":"world"}
        """)
        do {
            try await doc2.update { root, _ in
                root["title"] = Int32(123)
            }
            XCTFail("The API should not be success!")
        } catch {
            XCTAssertEqual(
                (
                    error as? Yorkie.YorkieError
                )?.message ?? "",
                "schema validation failed: Expected primitive(Yorkie.PrimitiveType.string) at path $.title"
            )
        }

        try await client.deactivate()
    }
}
