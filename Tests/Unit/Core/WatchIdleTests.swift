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

import Foundation
import XCTest
@testable import Yorkie

/// A deterministic stand-in for the clock and `Task.sleep`, mirroring vitest fake timers.
///
/// A pending sleep is a timer: ``timerCount`` is `vi.getTimerCount()`.
final class FakeWatchClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Int64 = 1_000_000
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var nowMs: Int64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }

    var timerCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.sleepers.count
    }

    @MainActor
    func sleep(_ nanoseconds: UInt64) async throws {
        let id = self.takeID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = self.lock.withLock { () -> Bool in
                    if Task.isCancelled {
                        return true
                    }
                    let deadline = self.current + Int64(nanoseconds / 1_000_000)
                    self.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.lock.lock()
            let removed = self.sleepers.first { $0.id == id }
            self.sleepers.removeAll { $0.id == id }
            self.lock.unlock()
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances time, resuming each due sleeper in deadline order and letting it run.
    func advance(_ ms: Int64) async {
        let target = self.nowMs + ms
        while let due = self.popEarliest(upTo: target) {
            due.continuation.resume()
            await Self.settle()
        }
        self.lock.withLock { self.current = target }
        await Self.settle()
    }

    /// Resumes the due sleepers without letting their continuations run.
    func advanceWithoutSettling(_ ms: Int64) {
        let target = self.nowMs + ms
        while let due = self.popEarliest(upTo: target) {
            due.continuation.resume()
        }
        self.lock.withLock { self.current = target }
    }

    /// Waits until `condition` holds, for the work the watchdog task has still to do after a
    /// timer was resumed. Gives up after about two seconds and returns the last answer.
    @MainActor
    static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 2000 {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    static func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        // A real, tiny sleep lets every job already enqueued on the main actor run to its next
        // suspension point; yielding alone does not guarantee that.
        try? await Task.sleep(nanoseconds: 1_000_000)
    }

    private func takeID() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.nextID += 1
        return self.nextID
    }

    private func popEarliest(upTo target: Int64) -> (continuation: CheckedContinuation<Void, Error>, deadline: Int64)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let earliest = self.sleepers.min(by: { $0.deadline < $1.deadline }), earliest.deadline <= target else {
            return nil
        }
        self.sleepers.removeAll { $0.id == earliest.id }
        self.current = max(self.current, earliest.deadline)
        return (earliest.continuation, earliest.deadline)
    }
}

@MainActor
private final class IdleCounter {
    var count = 0
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

final class WatchIdleTests: XCTestCase {
    // MARK: - watchIdleTimeout

    func test_watch_idle_timeout_is_0_when_the_server_sends_no_heartbeats() {
        XCTAssertEqual(watchIdleTimeout(0), 0)
        XCTAssertEqual(watchIdleTimeout(-1), 0)
        XCTAssertEqual(watchIdleTimeout(Int64.min), 0)
    }

    func test_watch_idle_timeout_is_three_heartbeat_intervals() {
        XCTAssertEqual(watchIdleTimeout(20000), 60000)
        XCTAssertEqual(watchIdleTimeout(334), 1002)
    }

    func test_watch_idle_timeout_is_clamped_to_1s_and_24h() {
        XCTAssertEqual(watchIdleTimeout(1), 1000)
        XCTAssertEqual(watchIdleTimeout(333), 1000)
        XCTAssertEqual(watchIdleTimeout(Int64(Int32.max)), 24 * 3_600_000)
        // Tripling these would overflow `Int64`.
        XCTAssertEqual(watchIdleTimeout(Int64.max), 24 * 3_600_000)
        XCTAssertEqual(watchIdleTimeout(Int64.max / 3 + 1), 24 * 3_600_000)
    }

    // MARK: - watchHeartbeatInterval

    func test_watch_heartbeat_interval_reads_the_interval_an_init_response_advertises() {
        XCTAssertEqual(watchHeartbeatInterval(initResponse(heartbeatIntervalMs: 20000)), 20000)
        XCTAssertEqual(watchHeartbeatInterval(initResponse(heartbeatIntervalMs: 0)), 0)
        XCTAssertEqual(watchHeartbeatInterval(heartbeatResponse()), 0)
        XCTAssertEqual(watchHeartbeatInterval(WatchResponse()), 0)
    }

    // MARK: - Wire

    func test_watch_response_round_trips_heartbeat_fields() throws {
        let initData = try initResponse(heartbeatIntervalMs: 20000).serializedData()
        let decodedInit = try WatchResponse(serializedBytes: initData)
        XCTAssertEqual(watchHeartbeatInterval(decodedInit), 20000)

        let beatData = try heartbeatResponse().serializedData()
        let decodedBeat = try WatchResponse(serializedBytes: beatData)
        guard case .heartbeat = decodedBeat.body else {
            return XCTFail("expected a heartbeat body")
        }
    }

    func test_presence_change_round_trips_patch_fields() throws {
        let change = PbPresenceChange.with {
            $0.type = .patch
            $0.removedKeys = ["a", "b"]
        }
        let decoded = try PbPresenceChange(serializedBytes: change.serializedData())
        XCTAssertEqual(decoded.type, .patch)
        XCTAssertEqual(decoded.removedKeys, ["a", "b"])
    }

    // MARK: - WatchIdleWatchdog

    /// Arms the watchdog and waits until its task is sleeping, as it is a moment after a stream
    /// delivers its init response.
    @MainActor
    private func arm(_ watchdog: WatchIdleWatchdog, _ clock: FakeWatchClock, timeoutMs: Int64) async {
        watchdog.arm(timeoutMs: timeoutMs)
        if timeoutMs > 0 {
            let sleeping = await FakeWatchClock.until { clock.timerCount == 1 }
            XCTAssertTrue(sleeping)
        }
    }

    @MainActor
    private func makeWatchdog(_ clock: FakeWatchClock, _ idle: IdleCounter) -> WatchIdleWatchdog {
        return WatchIdleWatchdog(
            now: { clock.nowMs },
            sleep: { try await clock.sleep($0) },
            onIdle: { idle.count += 1 }
        )
    }

    @MainActor
    func test_watchdog_fires_for_a_stream_that_goes_silent() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: watchIdleTimeout(1000))

        await clock.advance(2999)
        XCTAssertEqual(idle.count, 0)

        await clock.advance(1)
        let fired = await FakeWatchClock.until { idle.count == 1 && !watchdog.isArmed }
        XCTAssertTrue(fired)
        XCTAssertEqual(clock.timerCount, 0)
    }

    @MainActor
    func test_watchdog_keeps_a_stream_alive_while_heartbeats_arrive() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: watchIdleTimeout(1000))

        for _ in 0 ..< 10 {
            await clock.advance(2000)
            watchdog.recordActivity()
        }
        XCTAssertEqual(idle.count, 0)

        await clock.advance(3000)
        let fired = await FakeWatchClock.until { idle.count == 1 }
        XCTAssertTrue(fired)
    }

    @MainActor
    func test_watchdog_never_times_out_when_the_server_advertises_no_heartbeat() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: watchIdleTimeout(0))

        await clock.advance(3_600_000)
        XCTAssertEqual(idle.count, 0)
        XCTAssertFalse(watchdog.isArmed)
        XCTAssertEqual(clock.timerCount, 0)
    }

    @MainActor
    func test_watchdog_reports_idle_once_and_does_not_fire_again() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: 3000)

        await clock.advance(3000)
        let fired = await FakeWatchClock.until { idle.count == 1 }
        XCTAssertTrue(fired)
        await clock.advance(60000)
        XCTAssertEqual(idle.count, 1)
        XCTAssertEqual(clock.timerCount, 0)
    }

    @MainActor
    func test_watchdog_can_be_armed_again_for_the_successor_stream() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: 3000)
        await clock.advance(3000)
        let first = await FakeWatchClock.until { idle.count == 1 }
        XCTAssertTrue(first)

        await self.arm(watchdog, clock, timeoutMs: 3000)
        XCTAssertTrue(watchdog.isArmed)
        await clock.advance(3000)
        let second = await FakeWatchClock.until { idle.count == 2 }
        XCTAssertTrue(second)
    }

    @MainActor
    func test_watchdog_stops_the_timer_when_the_stream_ends() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: 3000)
        await FakeWatchClock.settle()
        XCTAssertEqual(clock.timerCount, 1)

        watchdog.cancel()
        await FakeWatchClock.settle()
        XCTAssertEqual(clock.timerCount, 0)

        await clock.advance(10000)
        XCTAssertEqual(idle.count, 0)
    }

    @MainActor
    func test_watchdog_leaves_a_cancellation_the_client_asked_for_as_it_was() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: 3000)

        await clock.advance(1000)
        watchdog.cancel()
        await clock.advance(10000)
        XCTAssertEqual(idle.count, 0)
        XCTAssertEqual(clock.timerCount, 0)
    }

    @MainActor
    func test_watchdog_does_not_report_a_cancellation_as_idle_when_the_timer_fires_first() async {
        // The client cancels just as the deadline passes: the sleep has already been resumed
        // but its continuation has not run yet.
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: 3000)
        await FakeWatchClock.settle()

        clock.advanceWithoutSettling(3000)
        watchdog.cancel()
        await FakeWatchClock.settle()
        await clock.advance(10000)
        XCTAssertEqual(idle.count, 0)
        XCTAssertEqual(clock.timerCount, 0)
    }

    @MainActor
    func test_watchdog_keeps_a_busy_stream_on_a_single_timer() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: watchIdleTimeout(1000))
        // A second arm while one is live must not add a timer.
        await self.arm(watchdog, clock, timeoutMs: watchIdleTimeout(1000))

        for _ in 0 ..< 100 {
            await clock.advance(50)
            watchdog.recordActivity()
        }
        await FakeWatchClock.settle()
        XCTAssertEqual(idle.count, 0)
        XCTAssertEqual(clock.timerCount, 1)
    }

    @MainActor
    func test_watchdog_fires_without_any_cooperation_from_the_stream() async {
        // Over a half-open socket the transport never settles the pending read, so the
        // watchdog must report on its own: nothing but silence drives `onIdle`.
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let watchdog = self.makeWatchdog(clock, idle)
        await self.arm(watchdog, clock, timeoutMs: watchIdleTimeout(1000))

        await clock.advance(3000)
        let fired = await FakeWatchClock.until { idle.count == 1 }
        XCTAssertTrue(fired)
        XCTAssertEqual(clock.timerCount, 0)
    }

    // MARK: - Attachment

    @MainActor
    func test_attachment_disconnect_stream_cancels_the_watchdog() async {
        let clock = FakeWatchClock()
        let idle = IdleCounter()
        let attachment = Attachment(resource: Document(key: "watch-idle-attachment"), resourceID: "r-1")
        let watchdog = self.makeWatchdog(clock, idle)
        attachment.watchIdleWatchdog = watchdog
        await self.arm(watchdog, clock, timeoutMs: 3000)

        attachment.cancelWatchStream()
        XCTAssertNil(attachment.watchIdleWatchdog)
        XCTAssertFalse(watchdog.isArmed)

        await clock.advance(10000)
        XCTAssertEqual(idle.count, 0)
    }
}
