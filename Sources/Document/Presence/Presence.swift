/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

/**
 * `PresenceStatus` represents the status of the presence.
 */
public enum PresenceStatus: String {
    case detached
    case attached
    case removed
}

/**
 * `LocalPresenceEventType` represents the type of presence event.
 */
public enum LocalPresenceEventType: String {
    case initialized
    case countChanged = "count-changed"
}

/**
 * `LocalPresenceEvent` represents an event that occurs in presence.
 */
public protocol LocalPresenceEvent {
    var type: LocalPresenceEventType { get }
}

/**
 * `PresenceInitializedEvent` is an event that occurs when presence is initialized.
 */
public struct PresenceInitializedEvent: LocalPresenceEvent {
    public let type = LocalPresenceEventType.initialized
    public let count: Int
}

/**
 * `PresenceCountChangedEvent` is an event that occurs when presence count changes.
 */
public struct PresenceCountChangedEvent: LocalPresenceEvent {
    public let type = LocalPresenceEventType.countChanged
    public let count: Int
}

/**
 * `Presence` represents a lightweight presence counter for tracking online users.
 * It provides real-time count updates through the watch stream.
 * It implements Attachable interface to be managed by Attachment.
 */
@MainActor
public class Presence: Attachable, @unchecked Sendable {
    private nonisolated(unsafe) var key: String
    private var status: PresenceStatus
    private var actorID: ActorID?
    private var presenceID: String?
    private var count: Int
    private var seq: Int64
    private var isRealtimeSync: Bool
    private var eventHandlers: [LocalPresenceEventType: [(LocalPresenceEvent) -> Void]] = [:]

    /**
     * Creates a new instance of Presence.
     *
     * @param key - The key of the presence.
     * @param isRealtime - Whether to sync presence in realtime (default: true).
     */
    public init(key: String, isRealtime: Bool = true) {
        self.key = key
        self.status = .detached
        self.count = 0
        self.seq = 0
        self.isRealtimeSync = isRealtime
    }

    /**
     * `getKey` returns the key of this presence.
     */
    public nonisolated func getKey() -> String {
        return self.key
    }

    /**
     * `getStatus` returns the status of this presence.
     */
    public func getStatus() -> ResourceStatus {
        switch self.status {
        case .detached:
            return .detached
        case .attached:
            return .attached
        case .removed:
            return .removed
        }
    }

    /**
     * `setActor` sets the actor ID of this presence.
     */
    public func setActor(_ actorID: ActorID) {
        self.actorID = actorID
    }

    /**
     * `hasLocalChanges` returns whether this presence has local changes.
     * Always returns false as presence is server-managed.
     */
    public func hasLocalChanges() async -> Bool {
        return false
    }

    /**
     * `publish` publishes an event to notify observers about changes in this presence.
     */
    public func publish(_: any DocEvent) {
        // Presence uses its own event system
        // This is here for Attachable protocol conformance
    }

    /**
     * `getCount` returns the current presence count.
     */
    public func getCount() -> Int {
        return self.count
    }

    /**
     * `setPresenceID` sets the presence ID.
     */
    func setPresenceID(_ id: String) {
        self.presenceID = id
    }

    /**
     * `getPresenceID` returns the presence ID.
     */
    func getPresenceID() -> String? {
        return self.presenceID
    }

    /**
     * `setStatus` sets the status of this presence.
     */
    func setStatus(_ status: PresenceStatus) {
        self.status = status
    }

    /**
     * `isRealtime` returns whether this presence uses realtime sync.
     */
    public func isRealtime() -> Bool {
        return self.isRealtimeSync
    }

    /**
     * `updateCount` updates the count and sequence number if the sequence is newer.
     * Returns true if the count was updated, false if the update was ignored.
     */
    public func updateCount(_ count: Int, _ seq: Int64) -> Bool {
        // Always accept initialization (seq === 0)
        if seq == 0 || seq > self.seq {
            self.count = count
            self.seq = seq

            // Emit count-changed event
            if seq > 0 {
                self.emitEvent(PresenceCountChangedEvent(count: count))
            } else {
                self.emitEvent(PresenceInitializedEvent(count: count))
            }

            return true
        }
        return false
    }

    /**
     * `on` registers an event handler for the given event type.
     */
    public func on(_ eventType: LocalPresenceEventType, handler: @escaping (LocalPresenceEvent) -> Void) {
        if self.eventHandlers[eventType] == nil {
            self.eventHandlers[eventType] = []
        }
        self.eventHandlers[eventType]?.append(handler)
    }

    /**
     * `off` unregisters event handlers for the given event type.
     */
    public func off(_ eventType: LocalPresenceEventType) {
        self.eventHandlers[eventType] = nil
    }

    /**
     * `emitEvent` emits an event to all registered handlers.
     */
    private func emitEvent(_ event: LocalPresenceEvent) {
        if let handlers = eventHandlers[event.type] {
            for handler in handlers {
                handler(event)
            }
        }
    }
}
