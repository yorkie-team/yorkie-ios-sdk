/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

final class WebhookIntegrationTests: XCTestCase {
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

    override func setUp() async throws {
        self.webhookServer = WebhookServer(port: 3004)
        try self.webhookServer.start()

        self.context = try await YorkieProjectHelper.initializeProject(
            rpcAddress: self.rpcAddress,
            username: self.testAPIID,
            password: self.testAPIPW,
            webhookURL: self.webhookServer.authWebhookUrl,
            webhookMethods: self.allAuthWebhookMethods
        )
        self.apiKey = self.context.apiKey
    }

    override func tearDown() async throws {
        self.webhookServer.stop()

        Self.authTokenInjectorCallCounter.reset()

        // Prevents duplication of project ID (based on timeInterval)
        try await Task.sleep(milliseconds: 1000)
    }

    func test_initialize_project_successfully() async throws {
        XCTAssertTrue(!self.apiKey.isEmpty)
    }

    func test_should_successfully_authorize_with_valid_token_200() async throws {
        struct TestAuthTokenInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                return "token-\(Date().timeInterval(after: 1000 * 1000 * 60 * 60))" // expire in 1 hour
            }
        }

        let client1 = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: TestAuthTokenInjector()))
        let client2 = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: TestAuthTokenInjector()))

        try await client1.activate()
        try await client2.activate()

        let docKey = "\(self.description)-\(Date().description)".toDocKey

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)

        try await client1.attach(doc1)
        try await client2.attach(doc2)

        let syncEventCollector = EventCollector<DocSyncStatus>(doc: doc2)
        await doc1.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncEventCollector.add(event: syncEvent.value)
        }

        try await doc2.update { root, _ in
            root.k1 = "v1"
        }

        try await client1.sync(doc1)
        try await client2.sync(doc2)

        let k1Value = await(doc2.getRoot().k1 as? String)
        XCTAssertEqual(k1Value, "v1")

        // try await client1.detach(doc)
        try await client1.deactivate()
        try await client2.deactivate()
    }

    func test_should_return_unauthenticated_error_for_client_with_empty_token_401() async throws {
        let client = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: nil))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
    }

    func test_should_return_unauthenticated_error_for_client_with_invalid_token_401() async throws {
        struct InvalidAuthTokenInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                return "invalid token"
            }
        }

        let client = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: InvalidAuthTokenInjector()))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
    }

    func test_should_return_permission_denied_error_for_client_with_not_allowed_token_403() async throws {
        struct NotAllowedAuthTokenInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                return "not-allowed-token"
            }
        }

        let client = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: NotAllowedAuthTokenInjector()))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .permissionDenied
        }
    }

    func test_should_refresh_token_when_unauthenticated_error_occurs_in_manual_sync() async throws {
        struct TestAuthTokenInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                WebhookIntegrationTests.authTokenInjectorCallCounter.increase(with: reason)
                let callCount = WebhookIntegrationTests.authTokenInjectorCallCounter.calls.count

                if reason == Constant.expiredTokenErrorMessage || callCount == 3 {
                    return "token-\(Date().timeInterval(after: Constant.tokenExpirationMs))"
                }
                return "token-\(Date().timeInterval(before: Constant.tokenExpirationMs))"
            }
        }

        let client = Client(rpcAddress, ClientOptions(apiKey: apiKey, authTokenInjector: TestAuthTokenInjector()))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 2)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 1), "")
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 2), Constant.expiredTokenErrorMessage)

        // retry activate
        try await client.activate()
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 3), "")

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        try await Task.sleep(milliseconds: UInt64(Constant.tokenExpirationMs))
        await assertThrows {
            try await client.attach(doc, [:], .manual)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 4)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 4), Constant.expiredTokenErrorMessage)

        // retry attach
        try await client.attach(doc, [:], .manual)

        try await doc.update { root, _ in
            root.k1 = "v1"
        }

        try await Task.sleep(milliseconds: UInt64(Constant.tokenExpirationMs))
        await assertThrows {
            try await client.sync(doc)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 5)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 5), Constant.expiredTokenErrorMessage)

        // retry sync in manual mode
        try await client.sync(doc)

        try await Task.sleep(milliseconds: UInt64(Constant.tokenExpirationMs))
        await assertThrows {
            try await client.detach(doc)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 6)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 6), Constant.expiredTokenErrorMessage)

        // retry detach
        try await client.detach(doc)

        try await Task.sleep(milliseconds: UInt64(Constant.tokenExpirationMs))
        await assertThrows {
            try await client.deactivate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 7)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 7), Constant.expiredTokenErrorMessage)

        // retry deactivate
        try await client.deactivate()
    }

    func test_should_refresh_token_and_retry_realtime_sync() async throws {
        // Prevents duplication of project ID (based on timeInterval)
        try await Task.sleep(milliseconds: 1000)

        self.context = try await YorkieProjectHelper.initializeProject(rpcAddress: self.rpcAddress,
                                                                       username: self.testAPIID,
                                                                       password: self.testAPIPW,
                                                                       webhookURL: self.webhookServer.authWebhookUrl,
                                                                       webhookMethods: ["PushPull"])
        self.apiKey = self.context.apiKey

        struct TestAuthTokenInjector: AuthTokenInjector {
            // set the token expiration time considering the sum of sync loop delay(100ms) and stream reconnection delay(1000ms).
            static let expirationInMils: Double = 1500

            func getToken(reason: String?) async throws -> String {
                WebhookIntegrationTests.authTokenInjectorCallCounter.increase(with: reason)

                if reason == Constant.expiredTokenErrorMessage {
                    return "token-\(Date().timeInterval(after: TestAuthTokenInjector.expirationInMils))"
                }
                return "token-\(Date().timeIntervalSince1970)"
            }
        }

        let options = ClientOptions(apiKey: apiKey, authTokenInjector: TestAuthTokenInjector(), retrySyncLoopDelay: 100)
        let client = Client(rpcAddress, options)
        try await client.activate()

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)
        try await client.attach(doc)

        // retry realtime sync
        try await Task.sleep(milliseconds: UInt64(TestAuthTokenInjector.expirationInMils))

        let syncEventCollector = EventCollector<DocSyncStatus>(doc: doc)
        await doc.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncEventCollector.add(event: syncEvent.value)
        }

        let authErrorEventCollector = EventCollector<AuthErrorValue>(doc: doc)
        await doc.subscribeAuthError { event, _ in
            guard let authErrorEvent = event as? AuthErrorEvent else { return }
            authErrorEventCollector.add(event: authErrorEvent.value)
        }

        try await doc.update { root, _ in
            root.k1 = "v1"
        }

        let targetAuthErrorValue = AuthErrorValue(reason: Constant.expiredTokenErrorMessage, method: .pushPull)
        for await value in authErrorEventCollector.waitStream(until: targetAuthErrorValue) {
            print("Received AuthErrorValue:", value)
        }

        for await value in syncEventCollector.waitStream(until: .synced) {
            print("Received SyncStatus:", value)
        }

        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 2)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 1), "") // on client.activate
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 2), Constant.expiredTokenErrorMessage) // on client.syncInternal

        try await client.detach(doc)
        try await client.deactivate()
    }

    func test_should_refresh_token_and_retry_watch_document() async throws {
        // Prevents duplication of project ID (based on timeInterval)
        try await Task.sleep(milliseconds: 1000)

        self.context = try await YorkieProjectHelper.initializeProject(rpcAddress: self.rpcAddress,
                                                                       username: self.testAPIID,
                                                                       password: self.testAPIPW,
                                                                       webhookURL: self.webhookServer.authWebhookUrl,
                                                                       webhookMethods: ["WatchDocuments"])
        self.apiKey = self.context.apiKey

        struct TestAuthTokenInjector: AuthTokenInjector {
            let name: String
            let expirationInMils: Double

            func getToken(reason: String?) async throws -> String {
                if self.name == "client" {
                    WebhookIntegrationTests.authTokenInjectorCallCounter.increase(with: reason)
                }

                if reason == Constant.expiredTokenErrorMessage {
                    return "token-\(Date().timeInterval(after: self.expirationInMils))"
                }
                return "token-\(Date().timeIntervalSince1970)"
            }
        }

        let expirationInMils: Double = 500
        let options = ClientOptions(apiKey: apiKey,
                                    authTokenInjector: TestAuthTokenInjector(name: "client", expirationInMils: expirationInMils),
                                    reconnectStreamDelay: 100)
        let client = Client(rpcAddress, options)
        try await client.activate()

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        let authErrorEventCollector = EventCollector<AuthErrorValue>(doc: doc)
        await doc.subscribeAuthError { event, _ in
            guard let authErrorEvent = event as? AuthErrorEvent else { return }
            authErrorEventCollector.add(event: authErrorEvent.value)
        }

        // Another client for verifying if the watchDocument is working properly
        let options2 = ClientOptions(apiKey: apiKey,
                                     authTokenInjector: TestAuthTokenInjector(name: "client2", expirationInMils: 1000 * 60 * 60))
        let client2 = Client(rpcAddress, options2)
        try await client2.activate()
        let doc2 = Document(key: docKey)
        try await client2.attach(doc2)

        let presenceEventCollector = EventCollector<DocEventType>(doc: doc2)
        await doc2.subscribePresence { event, _ in
            presenceEventCollector.add(event: event.type)
        }

        // retry watch document
        try await Task.sleep(milliseconds: UInt64(expirationInMils))

        Task {
            try await client.attach(doc)
        }
        let targetAuthErrorValue = AuthErrorValue(reason: Constant.expiredTokenErrorMessage, method: .watchDocuments)
        for await value in authErrorEventCollector.waitStream(until: targetAuthErrorValue) {
            print("Received AuthErrorValue:", value)
        }

        XCTAssertEqual(Self.authTokenInjectorCallCounter.count, 2)
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 1), "") // on client.activate
        XCTAssertEqual(Self.authTokenInjectorCallCounter.reason(nth: 2), Constant.expiredTokenErrorMessage) // on client.watchDocument

        for await value in presenceEventCollector.waitStream(until: .watched) {
            print("Received DocEventType:", value)
        }

        let syncEventCollector = EventCollector<DocSyncStatus>(doc: doc)
        await doc.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncEventCollector.add(event: syncEvent.value)
        }

        try await doc2.update { root, _ in
            root.k1 = "v1"
        }

        for await value in syncEventCollector.waitStream(until: .synced) {
            print("Received DocSyncStatus:", value)
        }

        let k1Value = await(doc.getRoot().k1 as? String)
        XCTAssertEqual(k1Value, "v1")

        try await client.detach(doc)
        try await client.deactivate()
    }
}
