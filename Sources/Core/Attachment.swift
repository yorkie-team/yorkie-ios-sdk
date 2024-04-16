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

import Foundation
import GRPC

class Attachment {
    var doc: Document
    var docID: String
    var syncMode: SyncMode
    var remoteChangeEventReceived: Bool
    var remoteWatchStream: GRPCAsyncServerStreamingCall<WatchDocumentRequest, WatchDocumentResponse>?
    var watchLoopReconnectTimer: Timer?

    init(doc: Document, docID: String, syncMode: SyncMode, remoteChangeEventReceived: Bool, remoteWatchStream: GRPCAsyncServerStreamingCall<WatchDocumentRequest, WatchDocumentResponse>? = nil, watchLoopReconnectTimer: Timer? = nil) {
        self.doc = doc
        self.docID = docID
        self.syncMode = syncMode
        self.remoteChangeEventReceived = remoteChangeEventReceived
        self.remoteWatchStream = remoteWatchStream
        self.watchLoopReconnectTimer = watchLoopReconnectTimer
    }

    /**
     * `needRealtimeSync` returns whether the document needs to be synced in real time.
     */
    func needRealtimeSync() async -> Bool {
        if self.syncMode == .realtimeSyncOff {
            return false
        }

        let hasLocalChanges = await doc.hasLocalChanges()

        return self.syncMode != .manual && (hasLocalChanges || self.remoteChangeEventReceived)
    }
}
