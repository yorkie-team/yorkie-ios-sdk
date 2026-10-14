/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

import Connect
import Foundation
import SwiftProtobuf
import XCTest
@testable import Yorkie

/// Parks `getToken` until the test releases it, so the Watch completion handler suspends inside
/// `handleConnectError` for as long as the test wants.
private final class GatedInjector: AuthTokenInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isEntered = false

    var entered: Bool {
        self.lock.withLock { self.isEntered }
    }

    func getToken(reason: String?) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.withLock {
                self.isEntered = true
                self.continuation = continuation
            }
        }
        return "token"
    }

    func release() {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private func initResponse(heartbeatIntervalMs: Int64) -> WatchResponse {
    return WatchResponse.with {
        $0.initialization = Yorkie_V1_WatchInitialization.with {
            $0.heartbeatIntervalMs = heartbeatIntervalMs
        }
    }
}

private func heartbeatResponse() -> WatchResponse {
    return WatchResponse.with {
        $0.heartbeat = Yorkie_V1_WatchHeartbeat()
    }
}

private func unauthenticated() -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": YorkieError.Code.errUnauthenticated.rawValue]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .unauthenticated,
        message: "expired",
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

private func complete(_ error: ConnectError?) -> StreamResult<WatchResponse> {
    return .complete(code: error?.code ?? .ok, error: error, trailers: nil)
}

/// Drives the Watch wiring of a real `Client` (mocking enabled, so no network is touched) with the
/// watchdog on a fake clock, mirroring the idle-watchdog cases of yorkie-js-sdk's `client_test.ts`.
@MainActor
final class ClientWatchIdleTests: XCTestCase {
    private let key = "watch-idle-doc"

    private struct Fixture {
        let client: Client
        let attachment: Attachment<Document>
        let document: Document
        let clock: FakeWatchClock
        let log: EventLog
    }

    @MainActor
    private final class EventLog {
        var events: [String] = []
        var disconnects: Int { self.events.filter { $0 == "disconnected" }.count }
    }

    private func makeFixture(injector: AuthTokenInjector? = nil) -> Fixture {
        let clock = FakeWatchClock()
        // The reconnect timer is scheduled but must never fire during a test.
        let client = Client(
            "http://localhost:1",
            ClientOptions(authTokenInjector: injector, reconnectStreamDelay: 3_600_000),
            isMockingEnabled: true
        )
        client.watchIdleClock = WatchIdleClock(now: { clock.nowMs }, sleep: { try await clock.sleep($0) })

        let document = Document(key: self.key)
        let attachment = Attachment(resource: document, resourceID: "resource-1", syncMode: .realtime)
        client.adoptAttachment(attachment, key: self.key, actorID: "000000000000000000000001")

        let log = EventLog()
        document.subscribeConnection { event, _ in
            if let event = event as? ConnectionChangedEvent {
                log.events.append(event.value == .connected ? "connected" : "disconnected")
            }
        }
        document.subscribePresence { event, _ in
            if event is InitializedEvent {
                log.events.append("initialized")
            }
        }
        return Fixture(client: client, attachment: attachment, document: document, clock: clock, log: log)
    }

    /// Starts a stream generation and delivers its init response, then waits for the watchdog task
    /// to start sleeping, as it does a moment after a real stream's init.
    @discardableResult
    private func startStream(_ fixture: Fixture, heartbeatIntervalMs: Int64 = 1000) async -> Int {
        let generation = fixture.attachment.beginWatchStream()
        await fixture.client.handleDocumentWatchResult(
            .message(initResponse(heartbeatIntervalMs: heartbeatIntervalMs)),
            key: self.key,
            attachment: fixture.attachment,
            generation: generation
        )
        if heartbeatIntervalMs > 0 {
            let sleeping = await FakeWatchClock.until { fixture.clock.timerCount == 1 }
            XCTAssertTrue(sleeping)
        }
        return generation
    }

    private func fireIdle(_ fixture: Fixture, from generation: Int) async {
        await fixture.clock.advance(3000)
        let bumped = await FakeWatchClock.until { fixture.attachment.watchGeneration != generation }
        XCTAssertTrue(bumped)
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.attachment.resetWatchLoopTimer()
        fixture.attachment.cancelWatchIdleWatchdog()
    }

    // MARK: - Arming

    func test_client_arms_the_watchdog_only_on_the_init_response_with_a_heartbeat_interval() async {
        let fixture = self.makeFixture()
        defer { self.tearDown(fixture) }
        let generation = fixture.attachment.beginWatchStream()

        // Nothing before the init response: a heartbeat or an event is not a handshake.
        await fixture.client.handleDocumentWatchResult(.message(heartbeatResponse()), key: self.key, attachment: fixture.attachment, generation: generation)
        XCTAssertNil(fixture.attachment.watchIdleWatchdog)

        // An init response that advertises no interval leaves it disarmed.
        await fixture.client.handleDocumentWatchResult(.message(initResponse(heartbeatIntervalMs: 0)), key: self.key, attachment: fixture.attachment, generation: generation)
        XCTAssertNil(fixture.attachment.watchIdleWatchdog)
        XCTAssertEqual(fixture.clock.timerCount, 0)

        await fixture.client.handleDocumentWatchResult(.message(initResponse(heartbeatIntervalMs: 1000)), key: self.key, attachment: fixture.attachment, generation: generation)
        XCTAssertEqual(fixture.attachment.watchIdleWatchdog?.isArmed, true)
        let sleeping = await FakeWatchClock.until { fixture.clock.timerCount == 1 }
        XCTAssertTrue(sleeping)
    }

    // MARK: - Idle fire

    func test_client_idle_fire_bumps_the_generation_resets_the_document_and_schedules_a_reconnect() async {
        let fixture = self.makeFixture()
        defer { self.tearDown(fixture) }
        fixture.document.setOnlineClients(["peer"])
        let generation = await self.startStream(fixture)

        await self.fireIdle(fixture, from: generation)

        XCTAssertEqual(fixture.attachment.watchGeneration, generation + 1)
        XCTAssertTrue(fixture.document.onlineClients.isEmpty)
        XCTAssertEqual(fixture.log.events, ["initialized", "disconnected"])
        XCTAssertNotNil(fixture.attachment.watchLoopReconnectTimer)
    }

    // MARK: - Stale stream

    func test_client_stale_completion_and_messages_after_an_idle_bump_do_nothing() async {
        let fixture = self.makeFixture()
        defer { self.tearDown(fixture) }
        let generation = await self.startStream(fixture)
        await self.fireIdle(fixture, from: generation)
        fixture.attachment.resetWatchLoopTimer()
        let events = fixture.log.events

        await fixture.client.handleDocumentWatchResult(complete(unauthenticated()), key: self.key, attachment: fixture.attachment, generation: generation)
        await fixture.client.handleDocumentWatchResult(.message(initResponse(heartbeatIntervalMs: 1000)), key: self.key, attachment: fixture.attachment, generation: generation)

        XCTAssertEqual(fixture.log.events, events)
        XCTAssertNil(fixture.attachment.watchLoopReconnectTimer, "a stale completion must not schedule a reconnect")
        XCTAssertNotEqual(fixture.attachment.watchIdleWatchdog?.isArmed, true, "a stale init must not arm a watchdog")
        XCTAssertEqual(fixture.clock.timerCount, 0)
    }

    // MARK: - Failed stream handled slowly

    func test_client_completion_stops_the_watchdog_before_it_awaits_the_error_handling() async {
        let injector = GatedInjector()
        let fixture = self.makeFixture(injector: injector)
        defer { self.tearDown(fixture) }
        let generation = await self.startStream(fixture)

        let completion = Task { @MainActor in
            await fixture.client.handleDocumentWatchResult(complete(unauthenticated()), key: self.key, attachment: fixture.attachment, generation: generation)
        }
        let suspended = await FakeWatchClock.until { injector.entered }
        XCTAssertTrue(suspended)

        // The stream is over: the silence that follows must not read as idle.
        XCTAssertEqual(fixture.clock.timerCount, 0)
        await fixture.clock.advance(10000)
        XCTAssertEqual(fixture.attachment.watchGeneration, generation)

        injector.release()
        await completion.value

        XCTAssertEqual(fixture.log.disconnects, 1, "the failed stream is disconnected exactly once")
        XCTAssertNotNil(fixture.attachment.watchLoopReconnectTimer)
    }

    func test_client_completion_that_lost_its_stream_while_handling_the_error_leaves_the_successor_alone() async {
        let injector = GatedInjector()
        let fixture = self.makeFixture(injector: injector)
        defer { self.tearDown(fixture) }
        let generation = await self.startStream(fixture)

        let completion = Task { @MainActor in
            await fixture.client.handleDocumentWatchResult(complete(unauthenticated()), key: self.key, attachment: fixture.attachment, generation: generation)
        }
        let suspended = await FakeWatchClock.until { injector.entered }
        XCTAssertTrue(suspended)

        // A successor stream starts while the old completion is still refreshing the token.
        let successor = fixture.attachment.beginWatchStream()
        fixture.attachment.resetWatchLoopTimer()
        let events = fixture.log.events
        var authErrors = 0
        fixture.document.subscribeAuthError { _, _ in authErrors += 1 }

        injector.release()
        await completion.value

        XCTAssertEqual(fixture.attachment.watchGeneration, successor)
        XCTAssertNil(fixture.attachment.watchLoopReconnectTimer, "the old completion must not reconnect over its successor")
        XCTAssertEqual(authErrors, 0)
        XCTAssertEqual(fixture.log.events, events)
    }

    func test_client_channel_completion_stops_the_watchdog_and_leaves_the_successor_alone() async throws {
        let injector = GatedInjector()
        let fixture = self.makeFixture(injector: injector)
        let channel = try Channel(key: "room")
        let attachment = Attachment(resource: channel, resourceID: "channel-1", syncMode: .realtime)
        fixture.client.adoptAttachment(attachment, key: "room", actorID: "000000000000000000000001")
        defer { attachment.resetWatchLoopTimer(); attachment.cancelWatchIdleWatchdog() }

        let generation = attachment.beginWatchStream()
        await fixture.client.handleChannelWatchResult(.message(initResponse(heartbeatIntervalMs: 1000)), key: "room", attachment: attachment, generation: generation)
        let armed = await FakeWatchClock.until { fixture.clock.timerCount == 1 }
        XCTAssertTrue(armed)

        let completion = Task { @MainActor in
            await fixture.client.handleChannelWatchResult(complete(unauthenticated()), key: "room", attachment: attachment, generation: generation)
        }
        let suspended = await FakeWatchClock.until { injector.entered }
        XCTAssertTrue(suspended)
        XCTAssertEqual(fixture.clock.timerCount, 0)
        await fixture.clock.advance(10000)
        XCTAssertEqual(attachment.watchGeneration, generation)

        let successor = attachment.beginWatchStream()
        injector.release()
        await completion.value

        XCTAssertEqual(attachment.watchGeneration, successor)
        XCTAssertNil(attachment.watchLoopReconnectTimer)
    }

    // MARK: - Reconnected stream

    func test_client_re_arms_the_watchdog_on_the_reconnected_streams_init() async {
        let fixture = self.makeFixture()
        defer { self.tearDown(fixture) }
        let first = await self.startStream(fixture)
        await self.fireIdle(fixture, from: first)
        XCTAssertEqual(fixture.clock.timerCount, 0)

        let second = await self.startStream(fixture)
        XCTAssertEqual(second, first + 2, "the idle bump and the new stream each take a generation")
        XCTAssertEqual(fixture.attachment.watchIdleWatchdog?.isArmed, true)

        await self.fireIdle(fixture, from: second)
        XCTAssertEqual(fixture.log.disconnects, 2)
    }
}
