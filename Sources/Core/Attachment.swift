/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

final class Attachment: @unchecked Sendable {
    var doc: Document
    var docID: String
    var syncMode: SyncMode
    var remoteChangeEventReceived: Bool
    var remoteWatchStream: (any YorkieServerStream)?
    var watchLoopReconnectTimer: Timer?
    var cancelled: Bool
    private var isDisconnected: Bool

    init(
        doc: Document,
        docID: String,
        syncMode: SyncMode,
        remoteChangeEventReceived: Bool,
        watchLoopReconnectTimer: Timer? = nil,
        cancelled: Bool = false
    ) {
        self.doc = doc
        self.docID = docID
        self.syncMode = syncMode
        self.remoteChangeEventReceived = remoteChangeEventReceived
        self.watchLoopReconnectTimer = watchLoopReconnectTimer
        self.isDisconnected = false
        self.cancelled = cancelled
    }

    /**
     * `needRealtimeSync` returns whether the document needs to be synced in real time.
     */
    func needRealtimeSync() async -> Bool {
        if self.syncMode == .realtimeSyncOff {
            return false
        }

        if self.syncMode == .realtimePushOnly {
            return await self.doc.hasLocalChanges()
        }

        let hasLocalChanges = await doc.hasLocalChanges()

        return self.syncMode != .manual && (hasLocalChanges || self.remoteChangeEventReceived)
    }

    func connectStream(_ stream: (any YorkieServerStream)?) {
        self.remoteWatchStream = stream
        self.isDisconnected = false
        self.cancelled = false
    }

    func disconnectStream() {
        self.remoteWatchStream?.cancel()
        self.remoteWatchStream = nil

        self.isDisconnected = true
    }

    /**
     * `cancelWatchStream` cancels the watch stream.
     */
    func cancelWatchStream() {
        self.cancelled = true

        self.disconnectStream()
    }

    func resetWatchLoopTimer() {
        self.watchLoopReconnectTimer?.invalidate()
        self.watchLoopReconnectTimer = nil
    }

    var isDisconnectedStream: Bool {
        if #available(iOS 16.0.0, *) {
            return self.remoteWatchStream == nil
        } else {
            return self.isDisconnected
        }
    }

    @MainActor func unsubscribeBroadcastEvent() {
        self.doc.unsubscribeLocalBroadcast()
    }
}
