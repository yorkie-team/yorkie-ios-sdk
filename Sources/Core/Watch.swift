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

import Foundation

/// Multiplies the heartbeat interval the server advertises to get how long a silent stream is
/// given before it is treated as half-open.
///
/// More than one interval, so a single late or dropped heartbeat does not tear down a stream
/// that is merely slow.
private let watchIdleTimeoutFactor: Int64 = 3

/// Floors the idle timeout. The interval arrives off the wire, so a server advertising a handful
/// of milliseconds would otherwise time every stream out as soon as it came up and spin the
/// reconnect loop.
private let watchIdleTimeoutMin: Int64 = 1000

/// Caps the idle timeout at 24 hours so a nonsensical interval cannot overflow.
private let watchIdleTimeoutMax: Int64 = 24 * 60 * 60 * 1000

/// Returns how long, in milliseconds, a watch stream may stay silent before it is treated as
/// half-open, given the heartbeat interval the server advertised.
///
/// A server that sends no heartbeats advertises 0 and gets 0 back: nothing is expected to
/// arrive on a quiet stream, so nothing may time one out.
func watchIdleTimeout(_ heartbeatIntervalMs: Int64) -> Int64 {
    guard heartbeatIntervalMs > 0 else {
        return 0
    }

    let (scaled, overflow) = heartbeatIntervalMs.multipliedReportingOverflow(by: watchIdleTimeoutFactor)
    if overflow {
        return watchIdleTimeoutMax
    }

    return min(max(scaled, watchIdleTimeoutMin), watchIdleTimeoutMax)
}

/// Returns the heartbeat interval, in milliseconds, that a watch init response advertises.
///
/// A server older than the heartbeat, or one with it turned off, advertises 0, as does any
/// response that is not the init response.
func watchHeartbeatInterval(_ response: WatchResponse) -> Int64 {
    if case .initialization(let initialization) = response.body {
        return initialization.heartbeatIntervalMs
    }

    return 0
}

/// The clock a ``WatchIdleWatchdog`` reads and sleeps on. Tests substitute a fake one.
struct WatchIdleClock {
    let now: @MainActor () -> Int64
    let sleep: @MainActor (UInt64) async throws -> Void

    static let system = WatchIdleClock(
        now: { WatchIdleWatchdog.monotonicNowMs() },
        sleep: { try await Task.sleep(nanoseconds: $0) }
    )
}

/// Detects a watch stream that has gone silent past the server heartbeat.
///
/// A quiet document sends nothing on its watch stream, so a half-open connection looks exactly
/// like a quiet document. When the server advertises a heartbeat interval, the client treats
/// ``watchIdleTimeout(_:)`` of silence as half-open and calls `onIdle`.
///
/// The watchdog owns a single live task. Responses only record the time through
/// ``recordActivity()``; the task re-arms itself for what is left of the timeout, so a busy
/// stream does not create and cancel a task per response. It is armed only after the init
/// response, never during the handshake, whose auth webhook retries the client has no basis
/// to bound.
///
/// `now` and `sleep` are injectable so tests can drive time deterministically.
@MainActor
final class WatchIdleWatchdog {
    private let now: @MainActor () -> Int64
    private let sleep: @MainActor (UInt64) async throws -> Void
    private let onIdle: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var timeoutMs: Int64 = 0
    private var lastActivityMs: Int64 = 0

    /// Creates a watchdog.
    ///
    /// - Parameters:
    ///   - now: Returns a monotonic timestamp in milliseconds.
    ///   - sleep: Suspends for the given number of nanoseconds, throwing when cancelled. It is
    ///     main-actor isolated so a fake can register its timer in step with the caller.
    ///   - onIdle: Called once when the stream has been silent for the whole timeout.
    init(
        now: @escaping @MainActor () -> Int64 = { WatchIdleWatchdog.monotonicNowMs() },
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        onIdle: @escaping @MainActor () -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.onIdle = onIdle
    }

    /// Returns whether a timer is currently pending.
    var isArmed: Bool {
        return self.task != nil
    }

    /// Arms the watchdog for the given idle timeout in milliseconds. A timeout of 0 or less
    /// leaves it disarmed, as does a watchdog that is already armed.
    func arm(timeoutMs: Int64) {
        guard timeoutMs > 0, self.task == nil else {
            return
        }

        self.timeoutMs = timeoutMs
        self.lastActivityMs = self.now()
        self.generation += 1
        let generation = self.generation
        // Strong on purpose: the task ends when it fires or `cancel()` runs, and the owner
        // cancels it whenever the stream goes away.
        self.task = Task {
            await self.run(generation: generation)
        }
    }

    /// Records that the stream was heard from.
    func recordActivity() {
        self.lastActivityMs = self.now()
    }

    /// Stops the watchdog without calling `onIdle`.
    func cancel() {
        self.generation += 1
        self.task?.cancel()
        self.task = nil
    }

    /// Returns a monotonic timestamp in milliseconds that keeps counting while the device sleeps.
    nonisolated static func monotonicNowMs() -> Int64 {
        return Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
    }

    private func run(generation: Int) async {
        while generation == self.generation {
            let remaining = self.lastActivityMs + self.timeoutMs - self.now()
            if remaining <= 0 {
                break
            }

            do {
                try await self.sleep(UInt64(remaining) * 1_000_000)
            } catch {
                return
            }
        }

        guard generation == self.generation else {
            return
        }

        self.task = nil
        self.onIdle()
    }
}
