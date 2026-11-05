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
import Foundation
import SwiftProtobuf
import XCTest
@testable import Yorkie

private let expiredToken = "expired token"

private struct InjectorFailure: Error, Equatable {
    let message: String
}

private func unauthenticated() -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": YorkieError.Code.errUnauthenticated.rawValue, "reason": expiredToken]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .unauthenticated,
        message: "unauthenticated",
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

private func unavailable() -> ConnectError {
    ConnectError(code: .unavailable, message: "down", exception: nil, details: [], metadata: [:])
}

/// A fake clock the token refresh backoff runs on.
@MainActor
private final class Clock {
    var nowMs: Int64 = 1_000_000
}

/// An injector whose calls the test settles by hand, so it controls the order they finish in.
private final class ManualInjector: AuthTokenInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = [CheckedContinuation<String, Error>]()
    private var recordedReasons = [String?]()

    var callCount: Int { self.lock.withLock { self.recordedReasons.count } }
    var reasons: [String?] { self.lock.withLock { self.recordedReasons } }

    func getToken(reason: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.withLock {
                self.recordedReasons.append(reason)
                self.pending.append(continuation)
            }
        }
    }

    /// Settles the `index`-th call (0-based).
    func resolve(_ index: Int, _ token: String) {
        self.lock.withLock { self.pending[index] }.resume(returning: token)
    }

    func reject(_ index: Int, _ message: String = "token api unavailable") {
        self.lock.withLock { self.pending[index] }.resume(throwing: InjectorFailure(message: message))
    }
}

/// An injector that answers at once from a script: a nil entry fails, a value succeeds.
private final class ScriptedInjector: AuthTokenInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String?]
    private var recordedReasons = [String?]()

    init(_ script: [String?]) { self.script = script }

    var callCount: Int { self.lock.withLock { self.recordedReasons.count } }
    var reasons: [String?] { self.lock.withLock { self.recordedReasons } }

    func getToken(reason: String?) async throws -> String {
        let next: String?? = self.lock.withLock {
            self.recordedReasons.append(reason)
            return self.script.isEmpty ? .some("token") : .some(self.script.removeFirst())
        }
        guard let token = next ?? nil else {
            throw InjectorFailure(message: "token api unavailable")
        }
        return token
    }
}

/// Mirrors yorkie-js-sdk `auth_refresh_test.ts` (#1513) against the iOS structure: the refresh
/// backoff state lives in `Client.authRefresh` on the injectable clock `authRefreshNow`. The backoff
/// is jittered by ±20% (JS mocks `Math.random`), so waits are asserted as ranges. The iOS client has
/// no setter to observe the token, so `authRefresh.tokenGeneration` (the number of the injector call
/// whose token is in use) stands in for `setAuthToken`.
@MainActor
final class ClientAuthRefreshTests: XCTestCase {
    private let clock = Clock()

    private func makeClient(_ injector: AuthTokenInjector) -> Client {
        let client = Client(
            "http://localhost:1",
            ClientOptions(authTokenInjector: injector, reconnectStreamDelay: 3_600_000),
            isMockingEnabled: true
        )
        let clock = self.clock
        client.authRefreshNow = { clock.nowMs }
        return client
    }

    /// Waits until `condition` holds, yielding to the pending tasks.
    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 2000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    private func waitMs(_ client: Client) -> Int64 {
        client.authRefresh.retryAt - self.clock.nowMs
    }

    func test_calls_a_rejecting_injector_again_only_after_a_doubling_backoff() async throws {
        // given - three failures, then success
        let injector = ScriptedInjector([nil, nil, nil, "new-token"])
        let client = self.makeClient(injector)

        for (index, base) in [Int64(1000), 2000, 4000].enumerated() {
            // when - a 401 refreshes and fails
            var handled = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
            XCTAssertTrue(handled)
            XCTAssertEqual(injector.callCount, index + 1)
            let wait = self.waitMs(client)
            XCTAssertGreaterThanOrEqual(wait, Int64(Double(base) * 0.8))
            XCTAssertLessThanOrEqual(wait, Int64(Double(base) * 1.2))

            // then - a 401 inside the wait does not call the injector
            self.clock.nowMs += Int64(Double(base) * 0.79)
            handled = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
            XCTAssertTrue(handled)
            XCTAssertEqual(injector.callCount, index + 1)

            // and once the wait is up it is called again
            self.clock.nowMs = client.authRefresh.retryAt
            _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
            XCTAssertEqual(injector.callCount, index + 2)
            if index < 2 { XCTAssertEqual(client.authRefresh.failures, index + 2) }
        }
        XCTAssertEqual(injector.reasons.first ?? nil, expiredToken)

        // the refresh succeeded: the next 401 refreshes at once
        XCTAssertEqual(client.authRefresh.failures, 0)
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertEqual(injector.callCount, 5)
    }

    func test_caps_the_backoff_at_30s() async throws {
        // given
        let injector = ScriptedInjector(Array(repeating: nil, count: 12))
        let client = self.makeClient(injector)

        // when - fail seven times in a row
        for _ in 0 ..< 7 {
            _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
            self.clock.nowMs = client.authRefresh.retryAt
        }
        XCTAssertEqual(injector.callCount, 7)

        // then - the next wait is the cap (jitter never exceeds it)
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        let wait = self.waitMs(client)
        XCTAssertGreaterThanOrEqual(wait, 24000)
        XCTAssertLessThanOrEqual(wait, 30000)
        XCTAssertEqual(AuthRefreshBackoff.delayMs(failures: 20) <= 30000, true)

        self.clock.nowMs += wait - 1
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertEqual(injector.callCount, 8)
        self.clock.nowMs += 1
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertEqual(injector.callCount, 9)
    }

    func test_counts_401s_that_arrive_together_as_one_failure() async throws {
        // given - the sync loop's and two Watch streams' 401s when the token expires
        let injector = ManualInjector()
        let client = self.makeClient(injector)

        // when
        let handled = (0 ..< 3).map { _ in
            Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        }
        let called = await self.until { injector.callCount == 3 }
        XCTAssertTrue(called)
        (0 ..< 3).forEach { injector.reject($0) }
        for task in handled {
            let result = try await task.value
            XCTAssertTrue(result)
        }

        // then - one failure: the next refresh may run in about 1s, not 4s
        XCTAssertEqual(client.authRefresh.failures, 1)
        let delay = client.loopRetryDelay(unauthenticated(), 0)
        XCTAssertGreaterThanOrEqual(delay, 800)
        XCTAssertLessThanOrEqual(delay, 1200)
    }

    func test_lets_a_later_401_refresh_while_an_earlier_call_never_settles() async throws {
        // given - a Watch stream's call hangs on a token API that does not answer
        let injector = ManualInjector()
        let client = self.makeClient(injector)
        let hung = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let first = await self.until { injector.callCount == 1 }
        XCTAssertTrue(first)

        // when - the sync loop's 401 is not held by it
        let later = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let second = await self.until { injector.callCount == 2 }
        XCTAssertTrue(second)
        injector.resolve(1, "new-token")

        // then
        let laterResult = try await later.value
        XCTAssertTrue(laterResult)
        XCTAssertEqual(client.authRefresh.tokenGeneration, 2)

        injector.resolve(0, "old-token")
        _ = try await hung.value
    }

    func test_holds_only_the_retries_that_got_a_401_until_the_next_refresh_may_run() async throws {
        // given
        let injector = ScriptedInjector([nil])
        let client = self.makeClient(injector)
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 100), 100)

        // when - a refresh fails
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)

        // then - a 401 retry waits for the refresh, another error keeps its own delay
        let wait = Int(self.waitMs(client))
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 100), wait)
        XCTAssertGreaterThanOrEqual(wait, 800)
        XCTAssertEqual(client.loopRetryDelay(unavailable(), 100), 100)
        self.clock.nowMs += 400
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 100), max(100, wait - 400))
        self.clock.nowMs = client.authRefresh.retryAt
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 100), 100)
    }

    func test_waits_at_most_5s_for_the_refresh_and_keeps_a_longer_delay_of_its_own() async throws {
        // given - a backoff of about 16s
        let injector = ScriptedInjector(Array(repeating: nil, count: 8))
        let client = self.makeClient(injector)
        for _ in 0 ..< 5 {
            _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
            self.clock.nowMs = client.authRefresh.retryAt
        }
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertGreaterThan(self.waitMs(client), 5000)

        // then - the loop never waits more than 5s, but a longer delay of its own stays
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 100), 5000)
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 8000), 8000)
    }

    func test_lets_an_earlier_call_that_settles_later_neither_set_its_token_nor_count() async throws {
        // given - the Watch stream's call is still pending when the sync loop's settles
        let injector = ManualInjector()
        let client = self.makeClient(injector)
        let first = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started1 = await self.until { injector.callCount == 1 }
        XCTAssertTrue(started1)
        let second = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started2 = await self.until { injector.callCount == 2 }
        XCTAssertTrue(started2)

        // when
        injector.resolve(1, "new-token")
        _ = try await second.value
        XCTAssertEqual(client.authRefresh.tokenGeneration, 2)
        injector.resolve(0, "old-token")
        _ = try await first.value

        // then - the old token did not take over
        XCTAssertEqual(client.authRefresh.tokenGeneration, 2)

        // nor does a late rejection start a backoff after a refresh succeeded
        let third = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started3 = await self.until { injector.callCount == 3 }
        XCTAssertTrue(started3)
        let fourth = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started4 = await self.until { injector.callCount == 4 }
        XCTAssertTrue(started4)
        injector.resolve(3, "newer-token")
        _ = try await fourth.value
        injector.reject(2)
        _ = try await third.value
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 0), 0)
        XCTAssertEqual(client.authRefresh.failures, 0)
    }

    func test_sets_the_token_of_a_call_that_settles_while_a_later_one_is_pending() async throws {
        // given - the sync loop's call, then a Watch stream's call while the first is pending
        let injector = ManualInjector()
        let client = self.makeClient(injector)
        let syncLoop = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started1 = await self.until { injector.callCount == 1 }
        XCTAssertTrue(started1)
        let watch = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started2 = await self.until { injector.callCount == 2 }
        XCTAssertTrue(started2)

        // when - the first settles while the second is pending: it must not be dropped
        injector.resolve(0, "token-1")
        _ = try await syncLoop.value
        XCTAssertEqual(client.authRefresh.tokenGeneration, 1)

        // then
        injector.resolve(1, "token-2")
        _ = try await watch.value
        XCTAssertEqual(client.authRefresh.tokenGeneration, 2)
    }

    func test_drops_an_injector_call_still_pending_when_the_client_activates_again() async throws {
        // given - a loop's call from the previous session is still pending
        let injector = ManualInjector()
        let client = self.makeClient(injector)
        let old = Task { @MainActor in try await client.handleConnectError(unauthenticated(), inRetryLoop: true) }
        let started = await self.until { injector.callCount == 1 }
        XCTAssertTrue(started)

        // when - `activate` sets the new session's token and settles the old call afterwards
        client.authRefresh.tokenSetByActivation()
        let sessionGeneration = client.authRefresh.tokenGeneration
        injector.resolve(0, "old-session-token")
        _ = try await old.value

        // then
        XCTAssertEqual(client.authRefresh.tokenGeneration, sessionGeneration)
        XCTAssertEqual(client.authRefresh.failures, 0)
    }

    func test_lets_a_one_shot_call_the_injector_during_the_backoff_and_throw_its_error() async throws {
        // given - a loop's 401 started the backoff
        let injector = ScriptedInjector([nil, nil, "new-token"])
        let client = self.makeClient(injector)
        let first = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        let second = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertTrue(first && second)
        XCTAssertEqual(injector.callCount, 1)

        // when - the app's call calls the injector all the same and gets its error
        do {
            _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: false)
            XCTFail("expected the injector's error")
        } catch {
            XCTAssertEqual(error as? InjectorFailure, InjectorFailure(message: "token api unavailable"))
        }

        // then - the failure counts toward the backoff
        XCTAssertEqual(injector.callCount, 2)
        XCTAssertEqual(client.authRefresh.failures, 2)
        let wait = self.waitMs(client)
        XCTAssertGreaterThanOrEqual(wait, 1600)
        XCTAssertLessThanOrEqual(wait, 2400)

        // once the token API is back the call sets the token at once, for the caller to retry
        let recovered = try await client.handleConnectError(unauthenticated(), inRetryLoop: false)
        XCTAssertTrue(recovered)
        XCTAssertEqual(injector.callCount, 3)
        XCTAssertEqual(client.loopRetryDelay(unauthenticated(), 0), 0)
    }

    func test_a_one_shot_sync_calls_the_injector_during_the_backoff_and_throws_its_error() async throws {
        // given - an attached document whose push is refused with a 401
        let injector = ScriptedInjector([nil, nil, "new-token"])
        let client = self.makeClient(injector)
        let doc = Document(key: "sync-doc")
        client.adoptAttachment(Attachment(resource: doc, resourceID: "r", syncMode: .manual), key: "sync-doc", actorID: "000000000000000000000001")
        client.setMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges, error: unauthenticated(), count: Int.max)
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertEqual(injector.callCount, 1)

        // when
        do {
            try await client.sync(doc)
            XCTFail("expected the injector's error")
        } catch {
            // then - the injector's error, not the 401
            XCTAssertEqual(error as? InjectorFailure, InjectorFailure(message: "token api unavailable"))
        }
        XCTAssertEqual(injector.callCount, 2)
        XCTAssertEqual(client.authRefresh.failures, 2)

        // once the token API is back it throws the 401 it got, for the app to retry
        do {
            try await client.sync(doc)
            XCTFail("expected the 401")
        } catch {
            XCTAssertNotEqual(error as? InjectorFailure, InjectorFailure(message: "token api unavailable"), "\(error)")
        }
        XCTAssertEqual(injector.callCount, 3)
        XCTAssertEqual(client.authRefresh.failures, 0)
    }

    func test_deactivates_locally_when_the_deactivation_gets_a_401_that_cannot_be_refreshed() async throws {
        // given
        let injector = ScriptedInjector(["new-token", nil])
        let client = self.makeClient(injector)
        let doc = Document(key: "deactivate-doc")
        client.adoptAttachment(Attachment(resource: doc, resourceID: "r", syncMode: .manual), key: "deactivate-doc", actorID: "000000000000000000000001")
        client.setMockError(for: YorkieServiceClient.Metadata.Methods.deactivateClient, error: unauthenticated(), count: Int.max)

        // when - a token the injector refreshes: the app may retry, so stay activated
        do {
            try await client.deactivate()
            XCTFail("expected the 401")
        } catch {
            XCTAssertNotEqual(error as? InjectorFailure, InjectorFailure(message: "token api unavailable"))
        }
        XCTAssertEqual(client.status, .activated)

        // then - signed out: stop locally and throw the injector's error
        do {
            try await client.deactivate()
            XCTFail("expected the injector's error")
        } catch {
            XCTAssertEqual(error as? InjectorFailure, InjectorFailure(message: "token api unavailable"))
        }
        XCTAssertEqual(injector.callCount, 2)
        XCTAssertEqual(client.status, .deactivated)
        XCTAssertNil(client.getDocumentAttachment("deactivate-doc"))
    }

    func test_calls_the_injector_on_a_broadcasts_first_try_during_the_backoff() async throws {
        // given - a loop's 401 started the backoff
        let injector = ScriptedInjector([nil, nil])
        let client = self.makeClient(injector)
        let channel = try Channel(key: "room")
        client.adoptAttachment(Attachment(resource: channel, resourceID: "c", syncMode: .realtime), key: "room", actorID: "000000000000000000000001")
        client.setMockError(for: YorkieServiceClient.Metadata.Methods.broadcast, error: unauthenticated(), count: Int.max)
        _ = try await client.handleConnectError(unauthenticated(), inRetryLoop: true)
        XCTAssertEqual(injector.callCount, 1)

        // when - the app's broadcast is a one-shot call on its first try
        do {
            try await client.broadcast("room", topic: "topic", payload: Payload(["k": "v"]), options: BroadcastOptions(maxRetries: 0))
            XCTFail("expected the injector's error")
        } catch {
            // then
            XCTAssertEqual(error as? InjectorFailure, InjectorFailure(message: "token api unavailable"))
        }
        XCTAssertEqual(injector.callCount, 2)
    }
}
