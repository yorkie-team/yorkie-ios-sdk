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

/// Recovery from a lost presence base (yorkie-js-sdk#1477).
extension Client {
    /// Sends a pack built by `build` and answers `ErrPresenceBaseUnavailable` by resending it once
    /// with the presence put back in full.
    ///
    /// The server had no base to fold the pack's presence patch into -- evicted, restarted, or moved
    /// to another shard -- and stored none of the pack. An expected signal, not a failure. Every
    /// request that pushes a pack goes through here, not just push-pull: a queue restored from
    /// offline persistence, or one carried over a ``resync(_:discardLocalChanges:initialPresence:)``,
    /// can still hold patches, and the next request they ride out on is an attach. Without the retry
    /// that attach fails, and fails again on every try, because the pack never changes.
    ///
    /// The retry carries its own base, so it cannot hit the same error twice. Any other error is
    /// returned as is, for the caller to handle as it did before.
    ///
    /// - Parameters:
    ///   - doc: The document whose pack is pushed.
    ///   - build: Builds the pack to send. Called again for the retry, so it must be re-entrant and
    ///     read the document afresh: the patch the first pack carried has been rewritten by then.
    ///   - send: Sends the built pack.
    /// - Returns: The response to the pack that was sent last.
    func pushWithPresenceBase<Response>(
        _ doc: Document,
        build: () -> PbChangePack,
        send: (PbChangePack) async -> ResponseMessage<Response>
    ) async -> ResponseMessage<Response> {
        let response = await send(build())
        guard let error = response.error,
              isErrorCode(error, YorkieError.Code.errPresenceBaseUnavailable.rawValue)
        else {
            return response
        }

        Logger.info("[PP] c:\"\(self.key)\" d:\"\(doc.getKey())\" presence base unavailable; resending with a full presence")
        doc.restorePresencePatches()
        return await send(build())
    }
}
