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

// MARK: - Watch requests

extension Client {
    /// Builds the Watch request for a document.
    ///
    /// The stable actor is sent or nothing: never the session id, which the server rejects as a
    /// mismatch. An empty value makes the server fall back to the session id, as old SDKs get by
    /// omitting the field. Mirrors yorkie-js-sdk, which sends `actorID ?? ''`.
    ///
    /// - Parameters:
    ///   - clientID: The session id of this client.
    ///   - actorID: The stable actor, or `nil` before the server assigned one.
    ///   - documentID: The server-side id of the document to watch.
    static func makeDocumentWatchRequest(clientID: String, actorID: ActorID?, documentID: String) -> WatchRequest {
        return WatchRequest.with {
            $0.clientID = clientID
            $0.actorID = actorID ?? ""
            $0.resources = [
                ResourceDescriptor.with {
                    $0.document = DocumentDescriptor.with {
                        $0.documentID = documentID
                    }
                }
            ]
        }
    }

    /// Builds the Watch request for a channel, declaring the stable actor like
    /// ``makeDocumentWatchRequest(clientID:actorID:documentID:)``.
    static func makeChannelWatchRequest(clientID: String, actorID: ActorID?, channelKey: String) -> WatchRequest {
        return WatchRequest.with {
            $0.clientID = clientID
            $0.actorID = actorID ?? ""
            $0.resources = [
                ResourceDescriptor.with {
                    $0.channel = ChannelDescriptor.with {
                        $0.channelKey = channelKey
                    }
                }
            ]
        }
    }
}

// MARK: - Watch idle watchdog wiring

extension Client {
    /// Records that the watch stream was heard from, and arms the idle watchdog on the init response.
    ///
    /// The watchdog is armed only after the init response, never during the handshake, and only
    /// when the server advertised a heartbeat interval. Every later response (event or
    /// heartbeat) counts as activity.
    func recordWatchActivity<R: Attachable>(
        of response: WatchResponse,
        key: String,
        on attachment: Attachment<R>,
        generation: Int
    ) {
        guard attachment.watchGeneration == generation else {
            return
        }

        guard case .initialization = response.body else {
            attachment.watchIdleWatchdog?.recordActivity()
            return
        }

        let timeoutMs = watchIdleTimeout(watchHeartbeatInterval(response))
        guard timeoutMs > 0 else {
            return
        }

        let watchdog = WatchIdleWatchdog { [weak self, weak attachment] in
            // A fire for a stream the client already cancelled or replaced is not idle.
            guard let self, let attachment, attachment.watchGeneration == generation, !attachment.cancelled else {
                return
            }
            self.handleWatchIdle(key, with: attachment, timeoutMs: timeoutMs)
        }
        attachment.watchIdleWatchdog?.cancel()
        attachment.watchIdleWatchdog = watchdog
        watchdog.arm(timeoutMs: timeoutMs)
    }

    /// Abandons a watch stream that went silent and reconnects it.
    ///
    /// Reconnects from the watchdog itself rather than once the stream unwinds: a transport need
    /// not settle a read pending on a half-open socket. The generation bump makes whatever the old
    /// stream does afterwards a no-op, so it can neither reach the error path nor cancel the
    /// successor stream. For documents the same reset as the error path is published first.
    private func handleWatchIdle<R: Attachable>(_ key: String, with attachment: Attachment<R>, timeoutMs: Int64) {
        attachment.watchGeneration += 1

        let error = YorkieError(code: .errWatchStreamIdle, message: "watch stream is idle for \(timeoutMs)ms")
        Logger.warning("[WL] c:\"\(self.key)\" \(error)")

        if let document = attachment.resource as? Document {
            document.resetOnlineClients()
            document.publishInitializedEvent()
            document.publishConnectionEvent(.disconnected)
        }

        try? self.onStreamDisconnect(key, with: attachment)
    }
}
