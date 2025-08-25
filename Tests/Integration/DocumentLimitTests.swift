/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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
import Connect

class DocumentSizeLimitTest: XCTestCase {
    let docKey = "doc-size-\(Date().description)".toDocKey
    let rpcAddress = "http://localhost:8080"
    let testAPIID = "admin"
    let testAPIPW = "admin"

    var apiKey = ""
    let allAuthWebhookMethods = [
        "ActivateClient",
        "DeactivateClient",
        "AttachDocument",
        "DetachDocument",
        "RemoveDocument",
        "PushPull",
        "WatchDocuments",
        "Broadcast"
    ]

    enum Constant {
        static let expiredTokenErrorMessage = "expired token"
        static let tokenExpirationMs: Double = 500
    }

    struct AuthTokenInjectorCallCounter {
        var calls: [String] = []

        mutating func reset() {
            self.calls = []
        }

        mutating func increase(with reason: String?) {
            self.calls.append(reason ?? "")
        }

        var count: Int {
            return self.calls.count
        }

        func reason(nth: Int) -> String {
            let index = nth - 1
            guard index >= 0 && index < self.calls.count else {
                return ""
            }
            return self.calls[index]
        }
    }

    static var authTokenInjectorCallCounter = AuthTokenInjectorCallCounter()

    var webhookServer: WebhookServer!
    var context: YorkieProjectContext!
    var projectName: String!
    var sizeLimit: Int!

    override func setUp() async throws {
        self.webhookServer = WebhookServer(port: 3004)
        try self.webhookServer.start()
        self.projectName = "auth-webhook-\(Int(Date().timeIntervalSince1970))"
        self.sizeLimit = makeRandomSize()
        self.context = try await YorkieProjectHelper.initializeProject(
            rpcAddress: self.rpcAddress,
            username: self.testAPIID,
            password: self.testAPIPW,
            webhookURL: self.webhookServer.authWebhookUrl,
            webhookMethods: [],
            projectName: self.projectName
        )
        self.apiKey = self.context.apiKey
    }

    override func tearDown() async throws {
        self.webhookServer.stop()
        self.projectName = nil
        self.sizeLimit = nil

        Self.authTokenInjectorCallCounter.reset()

        // Prevents duplication of project ID (based on timeInterval)
        try await Task.sleep(milliseconds: 1000)
    }

    func whenUpdateMaxSizeLimit(sizeLimit: Int) async throws {
        // update the max size of document
        try await YorkieProjectHelper.updateProjectWebhook(
            rpcAddress: self.rpcAddress,
            token: self.context.adminToken,
            projectID: self.context.projectID,
            webhookURL: self.webhookServer.authWebhookUrl,
            customFields: ["max_size_per_document": sizeLimit]
        )

        // get project detail and ensure the max size of document is correct!
        let response = try await YorkieProjectHelper.getProject(
            rpcAddress: self.rpcAddress,
            token: self.context.adminToken,
            projectName: self.projectName
        )

        if let maxSizePerDocument = (response["project"] as? [String: Any])?["maxSizePerDocument"] as? Int {
            XCTAssertEqual(maxSizePerDocument, sizeLimit)
            return
        } else {
            XCTFail("The error in Webhook call!")
        }
    }

    private func makeRandomSize() -> Int {
        // to make the test case more stable, use random integer instead of fixed number
        let randomInt = Int.random(in: 10...100)
        let sizeLimit = randomInt * 1024 * 1024
        return sizeLimit
    }

    func activateClientAndDocument(size: Int? = nil) async throws -> (Client, Document) {
        let size = size ?? sizeLimit
        sizeLimit = size
        try await whenUpdateMaxSizeLimit(sizeLimit: size!)
        let client1 = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: TestAuthTokenInjector()))

        try await client1.activate()

        let doc1 = Document(key: docKey)

        try await client1.attach(doc1, [:], .manual)
        let docMaxSize = await doc1.getMaxSizePerDoc()
        XCTAssertEqual(docMaxSize, size)

        return (client1, doc1)
    }
}

extension DocumentSizeLimitTest {
    // should successfully assign size limit to document
    func test_should_successfully_assign_size_limit_to_document() async throws {
        // update the max size of document
        let (_, document) = try await activateClientAndDocument()
        let docMaxSize = await document.getMaxSizePerDoc()
        
        XCTAssertEqual(docMaxSize, sizeLimit)
    }

    // should reject local update that exceeds document size limit
    func test_should_reject_local_update_that_exceeds_document_size_limit() async throws {
        let expectation = XCTestExpectation(description: "Must throws when update due to size limitation risk!")
        let (client, document) = try await activateClientAndDocument(size: 100)
        try await document.update { root, _ in
            root.t = JSONText()
        }

        let size = await document.getDocSize()
        XCTAssertEqual(size.live, .init(data: 0, meta: 72))
        let rootSize = await document.getClone()?.root.getDocSize()
        XCTAssertEqual(size, rootSize)

        // document size exceeded
        do {
            try await document.update { root, _ in
                (root.t as? JSONText)?.edit(0, 0, "helloworld")
            }
        } catch {
            expectation.fulfill()
        }

        let totalSize = await document.getDocSize().totalDocSize
        XCTAssertEqual(totalSize, 72)
        
        try await client.detach(document)
        try await client.deactivate()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // should allow remote updates even if they exceed document size limit
    func test_should_allow_remote_updates_even_if_they_exceed_document_size_limit() async throws {
        let (client1, doc1) = try await activateClientAndDocument(size: 100)

        let client2 = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: TestAuthTokenInjector()))

        try await client2.activate()
        let doc2 = Document(key: docKey)

        try await client2.attach(doc2)

        try await doc1.update { root, _ in
            root.t = JSONText()
        }

        var size = await doc1.getDocSize()
        XCTAssertEqual(size.live, .init(data: 0, meta: 72))

        try await client1.sync()
        try await client2.sync()

        size = await doc1.getDocSize()
        XCTAssertEqual(size.live, .init(data: 0, meta: 72))

        try await doc1.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "aa")
        }
        var live = await doc1.getDocSize().live
        XCTAssertEqual(live, .init(data: 4, meta: 96))

        try await doc2.update { root, _ in
            (root.t as? JSONText)?.edit(0, 0, "a")
        }

        live = await doc2.getDocSize().live
        XCTAssertEqual(live, .init(data: 2, meta: 96))

        try await client2.sync()
        // Pulls changes - should succeed despite exceeding limit

        live = await doc2.getDocSize().live
        XCTAssertEqual(live, .init(data: 2, meta: 96))

        try await client1.sync()

        live = await doc1.getDocSize().live
        XCTAssertEqual(live, .init(data: 6, meta: 120))

        let expectation = XCTestExpectation(description: "Must return error!")
        do {
            try await doc1.update { root, _ in
                (root.t as? JSONText)?.edit(0, 0, "a")
            }
        } catch {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)

        try await client1.detach(doc1)
        try await client1.deactivate()

        try await client2.detach(doc2)
        try await client2.deactivate()
    }
}

// MARK: - Helpers
private struct TestAuthTokenInjector: AuthTokenInjector {
    func getToken(reason: String?) async throws -> String {
        return "token-\(Date().timeInterval(after: 1000 * 1000 * 60 * 60))" // expire in 1 hour
    }
}
