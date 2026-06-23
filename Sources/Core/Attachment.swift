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

/**
 * `Attachment` is a class that manages the state of an attachable resource (Document or Channel).
 */
@MainActor
final class Attachment<R: Attachable>: @unchecked Sendable {
    var resource: R
    var resourceID: String
    var syncMode: SyncMode?
    var changeEventReceived: Bool?
    var lastHeartbeatTime: TimeInterval
    var pollInterval: TimeInterval
    var pollIntervalPinned: Bool
    var remoteWatchStream: YorkieServerStream?
    var watchLoopReconnectTimer: Timer?
    var cancelled: Bool
    private var isDisconnected: Bool

    init(
        resource: R,
        resourceID: String,
        syncMode: SyncMode? = nil,
        changeEventReceived: Bool? = nil,
        watchLoopReconnectTimer: Timer? = nil,
        cancelled: Bool = false,
        pollInterval: TimeInterval = 0,
        pollIntervalPinned: Bool = false
    ) {
        self.resource = resource
        self.resourceID = resourceID
        self.syncMode = syncMode
        self.changeEventReceived = changeEventReceived
        self.lastHeartbeatTime = Date().timeIntervalSince1970
        self.pollInterval = pollInterval
        self.pollIntervalPinned = pollIntervalPinned
        self.watchLoopReconnectTimer = watchLoopReconnectTimer
        self.isDisconnected = false
        self.cancelled = cancelled
    }

    /**
     * `needRealtimeSync` returns whether the resource needs to be synced in real time.
     * Only applicable to Document resources with syncMode defined.
     */
    func needRealtimeSync() async -> Bool {
        // If syncMode is not defined (e.g., for Channel), no sync is needed
        guard let syncMode = self.syncMode else {
            return false
        }

        if syncMode == .realtimeSyncOff {
            return false
        }

        if syncMode == .realtimePushOnly {
            return await self.resource.hasLocalChanges()
        }

        if syncMode == .polling {
            // Time-based: pull at every poll interval, regardless of local changes.
            return Date().timeIntervalSince1970 - self.lastHeartbeatTime >= self.pollInterval
        }

        let hasLocalChanges = await self.resource.hasLocalChanges()

        return syncMode != .manual && (hasLocalChanges || (self.changeEventReceived ?? false))
    }

    /// Updates the last heartbeat timestamp to the current time.
    func updateHeartbeatTime() {
        self.lastHeartbeatTime = Date().timeIntervalSince1970
    }

    func connectStream(_ stream: YorkieServerStream?) {
        // Cancel the old stream if it exists to prevent it from interfering
        if let oldStream = self.remoteWatchStream {
            oldStream.cancel()
        }

        self.remoteWatchStream = stream
        self.isDisconnected = false
        // NOTE: Don't reset cancelled here to prevent race conditions
        // when an old stream completes after a new one is created
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
        self.resetWatchLoopTimer()
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
}
