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

/// `Number.MAX_SAFE_INTEGER` (2^53 - 1), the cap yorkie-js-sdk applies to the heartbeat interval.
private let jsMaxSafeInteger: Int64 = 9_007_199_254_740_991

// MARK: - Watch requests

extension Client {
    /// Converts ``ClientOptions/watchHeartbeatInterval`` into the `heartbeat_interval_ms` a Watch
    /// request carries.
    ///
    /// Zero or a negative value asks for no heartbeat. A value past the largest integer a JS
    /// number holds exactly is capped, as yorkie-js-sdk does, so the same option asks the same of
    /// the server on every SDK. The option is whole milliseconds, so there is no fraction to round.
    static func toHeartbeatIntervalMs(_ interval: Int) -> Int64 {
        guard interval > 0 else {
            return 0
        }
        return min(Int64(interval), jsMaxSafeInteger)
    }

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
    ///   - heartbeatIntervalMs: The heartbeat interval to ask the server for, or `0` for none.
    static func makeDocumentWatchRequest(
        clientID: String,
        actorID: ActorID?,
        documentID: String,
        heartbeatIntervalMs: Int64
    ) -> WatchRequest {
        return WatchRequest.with {
            $0.clientID = clientID
            $0.actorID = actorID ?? ""
            $0.heartbeatIntervalMs = heartbeatIntervalMs
            $0.resources = [
                ResourceDescriptor.with {
                    $0.document = DocumentDescriptor.with {
                        $0.documentID = documentID
                    }
                }
            ]
        }
    }

    /// Builds the Watch request for a channel.
    ///
    /// Unlike ``makeDocumentWatchRequest(clientID:actorID:documentID:heartbeatIntervalMs:)`` it
    /// declares no actor: a channel session is not a document actor, and yorkie-js-sdk v0.7.25
    /// sends only the client id, the heartbeat interval and the resource.
    ///
    /// - Parameters:
    ///   - clientID: The session id of this client.
    ///   - channelKey: The key of the channel to watch.
    ///   - heartbeatIntervalMs: The heartbeat interval to ask the server for, or `0` for none.
    static func makeChannelWatchRequest(
        clientID: String,
        channelKey: String,
        heartbeatIntervalMs: Int64
    ) -> WatchRequest {
        return WatchRequest.with {
            $0.clientID = clientID
            $0.heartbeatIntervalMs = heartbeatIntervalMs
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

extension Client {
    /// Builds the Watch request for a document with this client's actor and heartbeat interval.
    func makeDocumentWatchRequest(clientID: String, documentID: String) -> WatchRequest {
        Self.makeDocumentWatchRequest(clientID: clientID, actorID: self.getActorID(), documentID: documentID, heartbeatIntervalMs: self.watchHeartbeatIntervalMs)
    }

    /// Builds the Watch request for a channel with this client's heartbeat interval.
    func makeChannelWatchRequest(clientID: String, channelKey: String) -> WatchRequest {
        Self.makeChannelWatchRequest(clientID: clientID, channelKey: channelKey, heartbeatIntervalMs: self.watchHeartbeatIntervalMs)
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

        let watchdog = WatchIdleWatchdog(now: self.watchIdleClock.now, sleep: self.watchIdleClock.sleep) { [weak self, weak attachment] in
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

        do {
            try self.onStreamDisconnect(key, with: attachment)
        } catch {
            Logger.warning("[WL] c:\"\(self.key)\" failed to reconnect an idle watch stream: \(error)")
        }
    }
}

// MARK: - Watch stream results

extension Client {
    /// Handles one result of a document Watch stream.
    ///
    /// Runs on the main actor from the first line to the first suspension, so the generation check
    /// and the synchronous work it guards happen in one hop: a watchdog bump cannot land between
    /// them. A stream that was abandoned or replaced must not reach the handlers, since its
    /// completion would otherwise disconnect, and then reconnect, its successor.
    func handleDocumentWatchResult(
        _ result: StreamResult<WatchResponse>,
        key: String,
        attachment: Attachment<Document>,
        generation: Int
    ) async {
        guard attachment.watchGeneration == generation else {
            return
        }

        switch result {
        case .headers:
            break
        case .message(let message):
            self.recordWatchActivity(of: message, key: key, on: attachment, generation: generation)
            self.handleWatchDocumentsResponse(docKey: key, response: message)
        case .complete(_, let error, _):
            // The stream is over, so the watchdog must not fire during the awaits below: it would
            // bump the generation and reconnect, and this completion would then tear the successor down.
            attachment.cancelWatchIdleWatchdog()

            if error != nil {
                attachment.resource.resetOnlineClients()
                attachment.resource.publishInitializedEvent()
                attachment.resource.publishConnectionEvent(.disconnected)
            }

            Logger.debug("[WD] c:\"\(self.key)\" unwatches")

            let retryable = await self.handleConnectError(error)
            // Handling the error can suspend (an auth token refresh): the stream may have been
            // replaced meanwhile, and a replaced stream owns nothing to disconnect.
            guard attachment.watchGeneration == generation else {
                return
            }

            if retryable {
                Logger.warning("[WL] c:\"\(self.key)\" has Error \(String(describing: error))")
                self.publishAuthErrorIfNeeded(error: error as? ConnectError, attachment: attachment, method: .watch)
            } else {
                self.setCondition(.watchLoop, value: false)
            }
            self.finishWatchStream(key, with: attachment)
        }
    }

    /// Handles one result of a channel Watch stream. See ``handleDocumentWatchResult(_:key:attachment:generation:)``.
    func handleChannelWatchResult(
        _ result: StreamResult<WatchResponse>,
        key: String,
        attachment: Attachment<Channel>,
        generation: Int
    ) async {
        guard attachment.watchGeneration == generation else {
            return
        }

        switch result {
        case .headers:
            break
        case .message(let message):
            self.recordWatchActivity(of: message, key: key, on: attachment, generation: generation)
            self.handleWatchChannelResponse(channelKey: key, response: message)
        case .complete(_, let error, _):
            attachment.cancelWatchIdleWatchdog()

            Logger.debug("[WC] c:\"\(self.key)\" unwatches")

            let retryable = await self.handleConnectError(error)
            guard attachment.watchGeneration == generation else {
                return
            }

            if retryable {
                Logger.warning("[WL] c:\"\(self.key)\" channel has Error \(String(describing: error))")
                self.publishChannelAuthErrorIfNeeded(error: error as? ConnectError, channel: attachment.resource, method: "Watch")
            } else {
                if let error = error as? ConnectError {
                    attachment.resource.publish(ChannelSyncErrorEvent(error: error, method: "Watch"))
                }
                self.setCondition(.watchLoop, value: false)
            }
            self.finishWatchStream(key, with: attachment)
        }
    }

    private func finishWatchStream<R: Attachable>(_ key: String, with attachment: Attachment<R>) {
        do {
            try self.onStreamDisconnect(key, with: attachment)
        } catch {
            Logger.warning("[WL] c:\"\(self.key)\" failed to settle a finished watch stream: \(error)")
        }
    }
}
