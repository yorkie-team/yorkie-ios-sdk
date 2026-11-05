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

/// Bounds the wait between token refreshes after `authTokenInjector` fails.
///
/// The wait starts at ``initialMs``, doubles on each failure in a row up to ``maxMs``, and each wait
/// is jittered by ±``jitter`` so clients that lost their token API at the same moment do not come
/// back at the same moment.
enum AuthRefreshBackoff {
    static let initialMs: Double = 1000
    static let maxMs: Double = 30000
    static let jitter: Double = 0.2

    /// Caps how long a loop retry that got a 401 waits for the token refresh backoff.
    ///
    /// The rest of the client expects a failed loop to run again soon: a channel session lapses
    /// after the server's 15s TTL, and a refresh that succeeds elsewhere (a one-shot call, another
    /// loop) should take effect without waking anything. The default channel heartbeat, TTL/3,
    /// keeps both.
    static let retryMaxWaitMs: Int64 = 5000

    /// Returns the wait before the next refresh.
    ///
    /// - Parameter failures: How many refreshes have failed in a row (1 for the first failure).
    /// - Returns: The wait in milliseconds.
    static func delayMs(failures: Int) -> Int64 {
        let base = Swift.min(self.initialMs * pow(2, Double(failures - 1)), self.maxMs)
        let jittered = base * (1 + self.jitter * Double.random(in: -1 ... 1))
        return Int64(Swift.min(jittered, self.maxMs))
    }
}

/// The state ``Client`` keeps about token refreshes, see `Client.refreshAuthToken(reason:inRetryLoop:)`.
struct AuthRefreshState {
    /// The token refreshes that failed in a row.
    var failures = 0
    /// When the next refresh may run, on ``Client/authRefreshNow``'s clock (ms).
    var retryAt: Int64 = 0
    /// Numbers the injector calls.
    var generation = 0
    /// The number of the call whose token is in use.
    var tokenGeneration = 0

    /// Forgets the failures after a token was set outside a refresh, by `activate`.
    mutating func tokenSetByActivation() {
        self.failures = 0
        self.retryAt = 0
        self.generation += 1
        self.tokenGeneration = self.generation
    }
}

extension Client {
    /// Handles an error a retry loop (the sync loop, the Watch streams, broadcast retries) got.
    ///
    /// Its 401s skip the token refresh while it backs off, and a refresh that fails does not throw:
    /// the loop retries on its own.
    ///
    /// - Parameter error: The error the loop got.
    /// - Returns: Whether the loop should retry.
    func handleLoopConnectError(_ error: Error?) async -> Bool {
        do {
            return try await self.handleConnectError(error, inRetryLoop: true)
        } catch {
            // `inRetryLoop` never throws: a failed refresh is swallowed for a loop. Should that ever
            // change, keep the loop retrying rather than stopping it silently.
            assertionFailure("handleConnectError threw in a retry loop: \(error)")
            Logger.error("[AT] c:\"\(self.key)\" unexpected error in a retry loop:", error: error)
            return true
        }
    }

    /// Returns how long a loop retry waits after `error`.
    ///
    /// It is the loop's own `delayMs`, or, for a 401, until the next token refresh may run if that
    /// is later, so the retry does not just resend a refused token -- but no longer than
    /// ``AuthRefreshBackoff/retryMaxWaitMs``. Other errors keep their own delay: a method the auth
    /// webhook does not guard still works with the refused token.
    ///
    /// - Parameters:
    ///   - error: The error the loop got.
    ///   - delayMs: The loop's own retry delay in milliseconds.
    /// - Returns: The delay to wait in milliseconds.
    func loopRetryDelay(_ error: Error?, _ delayMs: Int) -> Int {
        guard let connectError = error as? ConnectError,
              YorkieError.Code(rawValue: errorCodeOf(error: connectError)) == .errUnauthenticated
        else {
            return delayMs
        }
        let backoff = Swift.min(self.authRefresh.retryAt - self.authRefreshNow(), AuthRefreshBackoff.retryMaxWaitMs)
        return Swift.max(delayMs, Int(backoff))
    }
}
