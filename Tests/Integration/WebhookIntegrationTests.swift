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
    // MARK: - Constants

    static let rpcAddress = "http://localhost:8080"
    static let testAPIID = "admin"
    static let testAPIPW = "admin"
    static let webhookServerPort = 3004

    static let invalidTokenErrorMessage = "invalid token"
    static let expiredTokenErrorMessage = "expired token"
    static let notAllowedToken = "not-allowed-token"

    static let allAuthWebhookMethods = [
        "ActivateClient",
        "DeactivateClient",
        "AttachDocument",
        "DetachDocument",
        "RemoveDocument",
        "PushPull",
        "Watch",
        "Broadcast"
    ]

    // Bound on every `waitFor` so a missing event fails fast.
    static let defaultWaitTimeoutMs: UInt64 = 5000

    // Channel watch-stream delivery is now wired in Client.doWatchLoop.
    // Kept as a const so the Channel-broadcast block in `test_..._valid_token_200`
    // and `test_should_refresh_token_and_retry_broadcast` can be turned off
    // again if a regression surfaces.
    private static let channelWatchStreamUnavailable = false

    // MARK: - Suite-level state (JS `beforeAll`/`afterAll`)

    nonisolated(unsafe) static var webhookServer: WebhookServer!
    nonisolated(unsafe) static var apiKey = ""
    nonisolated(unsafe) static var adminToken = ""
    private nonisolated(unsafe) static var initTask: Task<Void, Error>?

    override static func setUp() {
        super.setUp()
        self.webhookServer = WebhookServer(port: self.webhookServerPort)
        do {
            try self.webhookServer.start()
        } catch {
            XCTFail("Failed to start webhook server on port \(self.webhookServerPort): \(error)")
        }
    }

    override static func tearDown() {
        self.webhookServer?.stop()
        self.initTask = nil
        super.tearDown()
    }

    override func setUp() async throws {
        try await Self.ensureProjectInitialized()
    }

    private static func ensureProjectInitialized() async throws {
        if self.initTask == nil {
            self.initTask = Task {
                let token = try await YorkieProjectHelper.logIn(
                    rpcAddress: self.rpcAddress,
                    username: self.testAPIID,
                    password: self.testAPIPW
                )
                let projectName = "wh-\(Int(Date().timeIntervalSince1970 * 1000))"
                let (projectID, publicKey, _) = try await YorkieProjectHelper.createProject(
                    rpcAddress: self.rpcAddress,
                    token: token,
                    name: projectName
                )
                try await YorkieProjectHelper.updateProjectWebhook(
                    rpcAddress: self.rpcAddress,
                    token: token,
                    projectID: projectID,
                    webhookURL: self.webhookServer.authWebhookUrl,
                    webhookMethods: self.allAuthWebhookMethods
                )
                self.adminToken = token
                self.apiKey = publicKey
            }
        }
        try await self.initTask!.value
    }

    // MARK: - Helpers

    /// Creates a fresh project with the given webhook methods and returns its apiKey.
    /// Mirrors JS tests that call `CreateProject` inline. Project names are capped
    /// at 30 chars by the server, so we use a millisecond timestamp (13 digits)
    /// after `wh-` (3 chars) → 16 chars total.
    private func createIsolatedProject(webhookMethods: [String]) async throws -> String {
        let projectName = "wh-\(Int(Date().timeIntervalSince1970 * 1000))"
        let (projectID, publicKey, _) = try await YorkieProjectHelper.createProject(
            rpcAddress: Self.rpcAddress,
            token: Self.adminToken,
            name: projectName
        )
        try await YorkieProjectHelper.updateProjectWebhook(
            rpcAddress: Self.rpcAddress,
            token: Self.adminToken,
            projectID: projectID,
            webhookURL: Self.webhookServer.authWebhookUrl,
            webhookMethods: webhookMethods
        )
        return publicKey
    }

    // MARK: - Tests (mirroring webhook_test.ts order)

    /// JS: `should successfully authorize with valid token(200)`
    /// Includes both Document sync and Channel broadcast verification.
    @MainActor
    func test_should_successfully_authorize_with_valid_token_200() async throws {
        struct ValidTokenInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                return "token-\(Date().timeInterval(after: 1000 * 60 * 60))" // expire in 1 hour
            }
        }

        let c1 = Client(Self.rpcAddress, ClientOptions(apiKey: Self.apiKey, authTokenInjector: ValidTokenInjector()))
        let c2 = Client(Self.rpcAddress, ClientOptions(apiKey: Self.apiKey, authTokenInjector: ValidTokenInjector()))

        let docKey = "\(self.description)-\(Date().timeIntervalSince1970)".toDocKey
        try await c1.activate()
        try await c2.activate()

        let doc1 = Document(key: docKey)
        let doc2 = Document(key: docKey)
        try await c1.attach(doc1)
        try await c2.attach(doc2)

        // Channel-broadcast verification — only runs when the watch stream is wired.
        if !Self.channelWatchStreamUnavailable {
            let channelKey = "presence-\(docKey)"
            let ch1 = try Channel(key: channelKey)
            let ch2 = try Channel(key: channelKey)
            _ = try await c1.attachChannel(ch1)
            _ = try await c2.attachChannel(ch2)

            let topic = "test"
            let payload = Payload(["data": "data"])

            let collector = ChannelPayloadCollector()
            ch2.subscribeBroadcast { event in
                if event.topic == topic {
                    collector.add(event.payload)
                }
            }

            try ch1.broadcast(topic: topic, payload: payload)
            try await collector.waitForFirst(equals: payload, timeoutMs: Self.defaultWaitTimeoutMs)

            _ = try await c1.detachChannel(ch1)
            _ = try await c2.detachChannel(ch2)
        }

        try doc1.update { root, _ in
            root.k1 = "v1"
        }
        try await c1.sync(doc1)
        try await c2.sync(doc2)

        let k1Value = (doc2.getRoot().k1 as? String)
        XCTAssertEqual(k1Value, "v1")

        try await c1.detach(doc1)
        try await c2.remove(doc2)

        try await c1.deactivate()
        try await c2.deactivate()
    }

    /// JS: `should return unauthenticated error for client with empty token (401)`
    @MainActor
    func test_should_return_unauthenticated_error_for_client_with_empty_token_401() async throws {
        let client = Client(Self.rpcAddress, ClientOptions(apiKey: Self.apiKey, authTokenInjector: nil))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
    }

    /// JS: `should return unauthenticated error for client with invalid token (401)`
    @MainActor
    func test_should_return_unauthenticated_error_for_client_with_invalid_token_401() async throws {
        struct InvalidTokenInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                return "invalid-token"
            }
        }

        let client = Client(Self.rpcAddress, ClientOptions(apiKey: Self.apiKey, authTokenInjector: InvalidTokenInjector()))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
    }

    /// JS: `should return permission denied error for client with not allowed token (403)`
    @MainActor
    func test_should_return_permission_denied_error_for_client_with_not_allowed_token_403() async throws {
        let counter = AuthCallCounter()
        struct NotAllowedTokenInjector: AuthTokenInjector {
            let counter: AuthCallCounter
            func getToken(reason: String?) async throws -> String {
                await self.counter.add(reason)
                return WebhookIntegrationTests.notAllowedToken
            }
        }

        let client = Client(Self.rpcAddress, ClientOptions(apiKey: Self.apiKey, authTokenInjector: NotAllowedTokenInjector(counter: counter)))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .permissionDenied
        }

        let callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 1)
        await counter.assertNthCall(1, equals: "")
    }

    /// JS: `should refresh token when unauthenticated error occurs (in manual sync)`
    @MainActor
    func test_should_refresh_token_when_unauthenticated_error_occurs_in_manual_sync() async throws {
        let tokenExpirationMs: Double = 500
        let counter = AuthCallCounter()
        struct InjectorImpl: AuthTokenInjector {
            let counter: AuthCallCounter
            let tokenExpirationMs: Double
            func getToken(reason: String?) async throws -> String {
                await self.counter.add(reason)
                let callCount = await counter.calls.count
                if reason == WebhookIntegrationTests.expiredTokenErrorMessage || callCount == 3 {
                    return "token-\(Date().timeInterval(after: self.tokenExpirationMs))"
                }
                return "token-\(Date().timeInterval(before: self.tokenExpirationMs))" // expired
            }
        }

        let client = Client(Self.rpcAddress, ClientOptions(apiKey: Self.apiKey, authTokenInjector: InjectorImpl(counter: counter, tokenExpirationMs: tokenExpirationMs)))

        await assertThrows {
            try await client.activate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        var callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 2)
        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)

        // retry activate
        try await client.activate()
        await counter.assertNthCall(3, equals: "")

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        await assertThrows {
            try await client.attach(doc, [:], .manual)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 4)
        await counter.assertNthCall(4, equals: Self.expiredTokenErrorMessage)

        try await client.attach(doc, [:], .manual)

        try doc.update { root, _ in
            root.k1 = "v1"
        }

        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        await assertThrows {
            try await client.sync(doc)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 5)
        await counter.assertNthCall(5, equals: Self.expiredTokenErrorMessage)

        try await client.sync(doc)

        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        await assertThrows {
            try await client.detach(doc)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 6)
        await counter.assertNthCall(6, equals: Self.expiredTokenErrorMessage)

        try await client.detach(doc)

        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        await assertThrows {
            try await client.deactivate()
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 7)
        await counter.assertNthCall(7, equals: Self.expiredTokenErrorMessage)

        try await client.deactivate()
    }

    /// JS: `should refresh token when unauthenticated error occurs (RemoveDocument)`
    @MainActor
    func test_should_refresh_token_when_unauthenticated_error_occurs_remove_document() async throws {
        let localApiKey = try await createIsolatedProject(webhookMethods: ["RemoveDocument"])

        let tokenExpirationMs: Double = 500
        let counter = AuthCallCounter()
        struct InjectorImpl: AuthTokenInjector {
            let counter: AuthCallCounter
            let tokenExpirationMs: Double
            func getToken(reason: String?) async throws -> String {
                await self.counter.add(reason)
                if reason == WebhookIntegrationTests.expiredTokenErrorMessage {
                    return "token-\(Date().timeInterval(after: self.tokenExpirationMs))"
                }
                return "token-\(Date().timeInterval(before: self.tokenExpirationMs))" // expired
            }
        }

        let client = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: InjectorImpl(counter: counter, tokenExpirationMs: tokenExpirationMs)))
        try await client.activate()

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)

        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        await assertThrows {
            try await client.remove(doc)
        } isExpectedError: { (error: ConnectError) in
            error.code == .unauthenticated
        }
        let callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 2)
        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)

        try await client.remove(doc)

        try await client.deactivate()
    }

    /// JS: `should refresh token and retry realtime sync`
    @MainActor
    func test_should_refresh_token_and_retry_realtime_sync() async throws {
        let localApiKey = try await createIsolatedProject(webhookMethods: ["PushPull"])

        let tokenExpirationMs: Double = 500
        let counter = AuthCallCounter()
        struct InjectorImpl: AuthTokenInjector {
            let counter: AuthCallCounter
            let tokenExpirationMs: Double
            func getToken(reason: String?) async throws -> String {
                await self.counter.add(reason)
                if reason == WebhookIntegrationTests.expiredTokenErrorMessage {
                    return "token-\(Date().timeInterval(after: self.tokenExpirationMs))"
                }
                return "token-\(Date().timeIntervalSince1970)"
            }
        }

        let options = ClientOptions(
            apiKey: localApiKey,
            authTokenInjector: InjectorImpl(counter: counter, tokenExpirationMs: tokenExpirationMs),
            retrySyncLoopDelay: 100
        )
        let client = Client(Self.rpcAddress, options)
        try await client.activate()

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)
        try await client.attach(doc)

        // wait for token expiration; realtime sync will fail once and trigger a refresh.
        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))

        let authErrorCollector = EventCollector<AuthErrorValue>(doc: doc)
        doc.subscribeAuthError { event, _ in
            guard let authEvent = event as? AuthErrorEvent else { return }
            authErrorCollector.add(event: authEvent.value)
        }

        try doc.update { root, _ in
            root.k1 = "v1"
        }

        // Wait for both the AuthErrorEvent (proves the sync attempt happened) and
        // the follow-up injector call (which happens after the event publishes,
        // when the retry loop calls handleConnectError → injectAuthTokenAfterGet).
        try await self.collectorWait(
            authErrorCollector,
            until: AuthErrorValue(reason: Self.expiredTokenErrorMessage, method: .pushPull),
            timeoutMs: Self.defaultWaitTimeoutMs
        )
        try await counter.waitForCount(atLeast: 2, timeoutMs: Self.defaultWaitTimeoutMs)

        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)

        try await client.detach(doc)
        try await client.deactivate()
    }

    /// JS: `should refresh token and retry watch document`
    @MainActor
    func test_should_refresh_token_and_retry_watch_document() async throws {
        let localApiKey = try await createIsolatedProject(webhookMethods: ["Watch"])

        let tokenExpirationMs: Double = 500
        let counter = AuthCallCounter()
        struct InjectorImpl: AuthTokenInjector {
            let counter: AuthCallCounter
            let tokenExpirationMs: Double
            let isPrimary: Bool
            func getToken(reason: String?) async throws -> String {
                if self.isPrimary { await self.counter.add(reason) }
                if reason == WebhookIntegrationTests.expiredTokenErrorMessage {
                    return "token-\(Date().timeInterval(after: self.tokenExpirationMs))"
                }
                return "token-\(Date().timeIntervalSince1970)"
            }
        }

        let c1 = Client(Self.rpcAddress, ClientOptions(
            apiKey: localApiKey,
            authTokenInjector: InjectorImpl(counter: counter, tokenExpirationMs: tokenExpirationMs, isPrimary: true),
            reconnectStreamDelay: 100
        ))
        try await c1.activate()

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        let authErrorCollector = EventCollector<AuthErrorValue>(doc: doc)
        doc.subscribeAuthError { event, _ in
            guard let authEvent = event as? AuthErrorEvent else { return }
            authErrorCollector.add(event: authEvent.value)
        }

        // second client with a long-lived token to verify watch really works
        let c2 = Client(Self.rpcAddress, ClientOptions(
            apiKey: localApiKey,
            authTokenInjector: InjectorImpl(counter: counter, tokenExpirationMs: 1000 * 60 * 60, isPrimary: false)
        ))
        try await c2.activate()
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2)

        let presenceCollector = EventCollector<DocEventType>(doc: doc2)
        doc2.subscribePresence { event, _ in
            presenceCollector.add(event: event.type)
        }

        // primary token is expired by now; watch document will retry once
        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        try await c1.attach(doc)

        try await self.collectorWait(
            authErrorCollector,
            until: AuthErrorValue(reason: Self.expiredTokenErrorMessage, method: .watch),
            timeoutMs: Self.defaultWaitTimeoutMs
        )
        let callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 2)
        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)

        try await self.collectorWait(presenceCollector, until: .watched, timeoutMs: Self.defaultWaitTimeoutMs)

        let syncCollector = EventCollector<DocSyncStatus>(doc: doc)
        doc.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncCollector.add(event: syncEvent.value)
        }
        try doc2.update { root, _ in
            root.k1 = "v1"
        }
        try await self.collectorWait(syncCollector, until: .synced, timeoutMs: Self.defaultWaitTimeoutMs)

        let k1Value = (doc.getRoot().k1 as? String)
        XCTAssertEqual(k1Value, "v1")

        try await c1.detach(doc)
        try await c1.deactivate()
        try await c2.detach(doc2)
        try await c2.deactivate()
    }

    // MARK: - Token refresh failures (yorkie-js-sdk#1513)

    /// A short-lived first token expires `shortTokenLifetimeMs` after it is issued.
    private static let shortTokenLifetimeMs: Double = 500

    /// A little over the server's default `auth-webhook-cache-ttl` (10s).
    private static let authWebhookCacheTTLMs: UInt64 = 10500

    /// Creates a project whose auth webhook guards `methods`, with no webhook retries and a 1s
    /// request timeout, as the JS `createWebhookProject` does.
    private func createWebhookProject(methods: [String]) async throws -> String {
        let projectName = "wh-\(Int(Date().timeIntervalSince1970 * 1000))"
        let (projectID, publicKey, _) = try await YorkieProjectHelper.createProject(
            rpcAddress: Self.rpcAddress,
            token: Self.adminToken,
            name: projectName
        )
        try await YorkieProjectHelper.updateProjectWebhook(
            rpcAddress: Self.rpcAddress,
            token: Self.adminToken,
            projectID: projectID,
            webhookURL: Self.webhookServer.authWebhookUrl,
            webhookMethods: methods,
            customFields: ["auth_webhook_max_retries": 0, "auth_webhook_request_timeout": "1s"]
        )
        return publicKey
    }

    /// JS: `should keep retrying realtime sync when a token refresh fails`
    @MainActor
    func test_should_keep_retrying_realtime_sync_when_a_token_refresh_fails() async throws {
        // given - the first refresh fails as if the token API were down for a moment
        let localApiKey = try await createWebhookProject(methods: ["PushPull"])
        let counter = AuthCallCounter()
        let injector = FlakyRefreshInjector(counter: counter, refreshFailures: 1, shortLifetimeMs: Self.shortTokenLifetimeMs)
        let client = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: injector, retrySyncLoopDelay: 100))
        try await client.activate()
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)
        try await client.attach(doc)

        try await Task.sleep(milliseconds: UInt64(Self.shortTokenLifetimeMs))
        let syncCollector = EventCollector<DocSyncStatus>(doc: doc)
        doc.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncCollector.add(event: syncEvent.value)
        }

        // when - the failed refresh must not stop the loop: it retries, gets 401 again, refreshes
        // successfully and pushes the change
        try doc.update { root, _ in
            root.k1 = "v1"
        }
        try await self.collectorWait(syncCollector, until: .synced, timeoutMs: 10000)

        // then
        let callCount = await counter.calls.count
        XCTAssertEqual(callCount, 3)
        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)
        await counter.assertNthCall(3, equals: Self.expiredTokenErrorMessage)

        let client2 = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: FlakyRefreshInjector(counter: AuthCallCounter(), refreshFailures: 0, shortLifetimeMs: 1000 * 60 * 60)))
        try await client2.activate()
        let doc2 = Document(key: docKey)
        try await client2.attach(doc2, [:], .manual)
        XCTAssertEqual(doc2.getRoot().k1 as? String, "v1")

        try await client2.deactivate()
        try await client.detach(doc)
        try await client.deactivate()
    }

    /// JS: `should keep reconnecting watch document when a token refresh fails`
    @MainActor
    func test_should_keep_reconnecting_watch_document_when_a_token_refresh_fails() async throws {
        // given
        let localApiKey = try await createWebhookProject(methods: ["Watch"])
        let counter = AuthCallCounter()
        let injector = FlakyRefreshInjector(counter: counter, refreshFailures: 1, shortLifetimeMs: Self.shortTokenLifetimeMs)
        let c1 = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: injector, reconnectStreamDelay: 100))
        try await c1.activate()
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let doc = Document(key: docKey)

        // another client for verifying that the watch really works
        let c2 = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: FlakyRefreshInjector(counter: AuthCallCounter(), refreshFailures: 0, shortLifetimeMs: 1000 * 60 * 60)))
        try await c2.activate()
        let doc2 = Document(key: docKey)
        try await c2.attach(doc2)
        let presenceCollector = EventCollector<DocEventType>(doc: doc2)
        doc2.subscribePresence { event, _ in
            presenceCollector.add(event: event.type)
        }

        // when - the failed refresh must not stop the watch loop
        try await Task.sleep(milliseconds: UInt64(Self.shortTokenLifetimeMs))
        try await c1.attach(doc)
        try await self.collectorWait(presenceCollector, until: .watched, timeoutMs: 10000)

        // then
        let callCount = await counter.calls.count
        XCTAssertEqual(callCount, 3)
        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)
        await counter.assertNthCall(3, equals: Self.expiredTokenErrorMessage)

        let syncCollector = EventCollector<DocSyncStatus>(doc: doc)
        doc.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncCollector.add(event: syncEvent.value)
        }
        try doc2.update { root, _ in
            root.k1 = "v1"
        }
        try await self.collectorWait(syncCollector, until: .synced, timeoutMs: Self.defaultWaitTimeoutMs)
        XCTAssertEqual(doc.getRoot().k1 as? String, "v1")

        try await c2.deactivate()
        try await c1.detach(doc)
        try await c1.deactivate()
    }

    /// JS: `should back off the token refresh and resend the refused token once per attempt`
    @MainActor
    func test_should_back_off_the_token_refresh_and_resend_the_refused_token_once_per_attempt() async throws {
        // given - the first two refreshes fail; the third succeeds after about 1s + 2s of backoff
        let localApiKey = try await createWebhookProject(methods: ["PushPull"])
        let counter = AuthCallCounter()
        let injector = FlakyRefreshInjector(counter: counter, refreshFailures: 2, shortLifetimeMs: Self.shortTokenLifetimeMs)
        let client = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: injector, retrySyncLoopDelay: 100))
        try await client.activate()
        let doc = Document(key: "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey)
        try await client.attach(doc)
        let expiredToken = try XCTUnwrap(injector.issuedTokens.first)

        try await Task.sleep(milliseconds: UInt64(Self.shortTokenLifetimeMs))
        let callsBeforeExpiry = WebhookCallLog.shared.calls.count
        let syncCollector = EventCollector<DocSyncStatus>(doc: doc)
        doc.subscribeSync { event, _ in
            guard let syncEvent = event as? SyncStatusChangedEvent else { return }
            syncCollector.add(event: syncEvent.value)
        }

        // when
        try doc.update { root, _ in
            root.k1 = "v1"
        }
        try await self.collectorWait(syncCollector, until: .synced, timeoutMs: 10000)

        // then - the loop retries every 100ms, but the refreshes were 1s and then 2s apart (±20%),
        // and each one was set off by a single push with the refused token
        let callCount = await counter.calls.count
        XCTAssertEqual(callCount, 4)
        let refreshedAt = injector.refreshedAt
        XCTAssertGreaterThanOrEqual(refreshedAt.count, 3)
        XCTAssertGreaterThanOrEqual(refreshedAt[1] - refreshedAt[0], 0.8)
        XCTAssertGreaterThanOrEqual(refreshedAt[2] - refreshedAt[1], 1.6)
        let refused = WebhookCallLog.shared.calls.dropFirst(callsBeforeExpiry)
            .filter { $0.token == expiredToken && $0.method == "PushPull" }
        XCTAssertEqual(refused.count, 3)

        try await client.detach(doc)
        try await client.deactivate()
    }

    /// JS: `should pull a remote change whose pull failed on a 401`
    @MainActor
    func test_should_pull_a_remote_change_whose_pull_failed_on_a_401() async throws {
        // given
        let localApiKey = try await createWebhookProject(methods: ["PushPull"])
        let counter = AuthCallCounter()
        let c1 = Client(Self.rpcAddress, ClientOptions(
            apiKey: localApiKey,
            authTokenInjector: FlakyRefreshInjector(counter: counter, refreshFailures: 1, shortLifetimeMs: Self.shortTokenLifetimeMs),
            retrySyncLoopDelay: 100
        ))
        let c2 = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: FlakyRefreshInjector(counter: AuthCallCounter(), refreshFailures: 0, shortLifetimeMs: 1000 * 60 * 60)))
        try await c1.activate()
        try await c2.activate()
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)
        try await c1.attach(d1)
        try await c2.attach(d2)

        // c1 has no local changes: the only reason it pulls is c2's change, and that pull is the
        // one that gets the 401. The server caches an allowed webhook answer for the same request
        // for 10s (`auth-webhook-cache-ttl`), so wait that out too, or the expired token would
        // still pass.
        try await Task.sleep(milliseconds: UInt64(Self.shortTokenLifetimeMs) + Self.authWebhookCacheTTLMs)

        // when
        try d2.update { root, _ in
            root.k1 = "v1"
        }

        // then
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, d1.getRoot().k1 as? String != "v1" {
            try await Task.sleep(milliseconds: 50)
        }
        XCTAssertEqual(d1.getRoot().k1 as? String, "v1")
        let callCount = await counter.calls.count
        XCTAssertEqual(callCount, 3)

        try await c2.deactivate()
        try await c1.detach(d1)
        try await c1.deactivate()
    }

    /// JS: `should refresh token and retry broadcast`
    @MainActor
    func test_should_refresh_token_and_retry_broadcast() async throws {
        let localApiKey = try await createIsolatedProject(webhookMethods: ["Broadcast"])

        // Set above DefaultBroadcastOptions.initialRetryInterval (1000ms).
        let tokenExpirationMs: Double = 1500
        let counter = AuthCallCounter()
        struct InjectorImpl: AuthTokenInjector {
            let counter: AuthCallCounter
            let tokenExpirationMs: Double
            func getToken(reason: String?) async throws -> String {
                await self.counter.add(reason)
                if reason == WebhookIntegrationTests.expiredTokenErrorMessage {
                    return "token-\(Date().timeInterval(after: self.tokenExpirationMs))"
                }
                return "token-\(Date().timeIntervalSince1970)"
            }
        }
        let c1 = Client(Self.rpcAddress, ClientOptions(
            apiKey: localApiKey,
            authTokenInjector: InjectorImpl(counter: counter, tokenExpirationMs: tokenExpirationMs),
            reconnectStreamDelay: 100
        ))
        try await c1.activate()

        let channelKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let ch1 = try Channel(key: channelKey)
        _ = try await c1.attachChannel(ch1)

        let authErrorOnCh1 = AuthErrorCollector()
        ch1.subscribeAuthError { event in
            authErrorOnCh1.add(reason: event.reason, method: event.method)
        }

        struct LongLivedInjector: AuthTokenInjector {
            func getToken(reason: String?) async throws -> String {
                return "token-\(Date().timeInterval(after: 1000 * 60 * 60))"
            }
        }
        let c2 = Client(Self.rpcAddress, ClientOptions(apiKey: localApiKey, authTokenInjector: LongLivedInjector()))
        try await c2.activate()
        let ch2 = try Channel(key: channelKey)
        _ = try await c2.attachChannel(ch2)

        let payloadCollector = ChannelPayloadCollector()
        let topic = "test"
        let payload = Payload(["data": "data"])
        ch2.subscribeBroadcast { event in
            if event.topic == topic {
                payloadCollector.add(event.payload)
            }
        }

        // wait for c1's token to expire so the broadcast triggers a refresh
        try await Task.sleep(milliseconds: UInt64(tokenExpirationMs))
        try ch1.broadcast(topic: topic, payload: payload)

        try await payloadCollector.waitForFirst(equals: payload, timeoutMs: Self.defaultWaitTimeoutMs)
        try await authErrorOnCh1.waitForFirst(
            equals: AuthErrorPair(reason: Self.expiredTokenErrorMessage, method: "Broadcast"),
            timeoutMs: Self.defaultWaitTimeoutMs
        )

        let callsCount = await counter.calls.count
        XCTAssertEqual(callsCount, 2)
        await counter.assertNthCall(1, equals: "")
        await counter.assertNthCall(2, equals: Self.expiredTokenErrorMessage)

        ch2.unsubscribeBroadcast()
        _ = try await c1.detachChannel(ch1)
        _ = try await c2.detachChannel(ch2)
        try await c1.deactivate()
        try await c2.deactivate()
    }

    // MARK: - Wait helpers (bounded so a missing event fails fast)

    private func collectorWait<T: Equatable & Sendable>(
        _ collector: EventCollector<T>,
        until target: T,
        timeoutMs: UInt64
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in collector.waitStream(until: target) { /* drain */ }
            }
            group.addTask {
                try await Task.sleep(milliseconds: timeoutMs)
                throw YorkieError(code: .errUnexpected, message: "Timed out waiting for \(target) after \(timeoutMs)ms")
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - Test-local helpers

/// Thread-safe call recorder for `AuthTokenInjector` (replaces `vi.fn` mock counters).
actor AuthCallCounter {
    private(set) var calls: [String] = []
    func add(_ reason: String?) { self.calls.append(reason ?? "") }
    /// Bounds-safe equivalent of JS `nthCalledWith(n, expected)`. Reports a clear
    /// test failure if the Nth call hasn't happened yet, rather than crashing.
    func assertNthCall(_ nth: Int, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let index = nth - 1
        guard self.calls.indices.contains(index) else {
            XCTFail("Expected at least \(nth) auth calls, got \(self.calls.count): \(self.calls)", file: file, line: line)
            return
        }
        XCTAssertEqual(self.calls[index], expected, file: file, line: line)
    }

    /// Polls until `calls.count >= n` or the timeout elapses. Used when an event
    /// (e.g. AuthErrorEvent) fires *before* the injector is called by the retry
    /// loop, so we can't assert the count immediately after seeing the event.
    func waitForCount(atLeast target: Int, timeoutMs: UInt64, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while Date() < deadline {
            if self.calls.count >= target { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(target) auth calls; got \(self.calls.count): \(self.calls)", file: file, line: line)
    }
}

private struct AuthErrorPair: Equatable {
    let reason: String
    let method: String
}

private final class AuthErrorCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yorkie.authErrorCollector", attributes: .concurrent)
    private var _values: [AuthErrorPair] = []

    var values: [AuthErrorPair] { self.queue.sync { self._values } }

    func add(reason: String, method: String) {
        self.queue.async(flags: .barrier) {
            self._values.append(AuthErrorPair(reason: reason, method: method))
        }
    }

    func waitForFirst(equals target: AuthErrorPair, timeoutMs: UInt64) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while Date() < deadline {
            if self.values.contains(target) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for AuthErrorPair \(target) after \(timeoutMs)ms; got \(self.values)")
    }
}

private final class ChannelPayloadCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yorkie.channelPayloadCollector", attributes: .concurrent)
    private var _values: [Payload] = []

    var values: [Payload] { self.queue.sync { self._values } }
    var count: Int { self.values.count }

    func add(_ payload: Payload) {
        self.queue.async(flags: .barrier) {
            self._values.append(payload)
        }
    }

    func waitForFirst(equals target: Payload, timeoutMs: UInt64) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while Date() < deadline {
            if self.values.first == target { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for payload \(target) after \(timeoutMs)ms; got \(self.values)")
    }
}

/// Injector whose first `refreshFailures` refreshes (calls with the webhook's reason) throw, as if
/// the token API were down for a moment; later refreshes return a long-lived token and the first
/// token lasts `shortLifetimeMs`.
final class FlakyRefreshInjector: AuthTokenInjector, @unchecked Sendable {
    private let counter: AuthCallCounter
    private let shortLifetimeMs: Double
    private let lock = NSLock()
    private var remainingFailures: Int
    private var tokens = [String]()
    private var refreshTimes = [TimeInterval]()

    init(counter: AuthCallCounter, refreshFailures: Int, shortLifetimeMs: Double) {
        self.counter = counter
        self.remainingFailures = refreshFailures
        self.shortLifetimeMs = shortLifetimeMs
    }

    /// Every token this injector returned, in order.
    var issuedTokens: [String] { self.lock.withLock { self.tokens } }

    /// When each refresh (a call with the webhook's reason) happened, in seconds.
    var refreshedAt: [TimeInterval] { self.lock.withLock { self.refreshTimes } }

    func getToken(reason: String?) async throws -> String {
        await self.counter.add(reason)
        if reason == WebhookIntegrationTests.expiredTokenErrorMessage {
            let shouldFail = self.lock.withLock { () -> Bool in
                self.refreshTimes.append(Date().timeIntervalSince1970)
                guard self.remainingFailures > 0 else { return false }
                self.remainingFailures -= 1
                return true
            }
            if shouldFail {
                throw YorkieError(code: .errUnexpected, message: "token api unavailable")
            }
            let token = "token-\(Date().timeInterval(after: 1000 * 60 * 60))"
            self.lock.withLock { self.tokens.append(token) }
            return token
        }
        let token = "token-\(Date().timeInterval(after: self.shortLifetimeMs))"
        self.lock.withLock { self.tokens.append(token) }
        return token
    }
}
