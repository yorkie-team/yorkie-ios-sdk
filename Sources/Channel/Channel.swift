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
 * `ChannelStatus` represents the status of the channel.
 */
public enum ChannelStatus: String {
    case detached
    case attached
    case removed
}

/**
 * `BroadcastOptions` are the options for broadcasting a message.
 */
public struct BroadcastOptions {
    /**
     * `error` is called when an error occurs.
     */
    public let error: ErrorFn?

    /**
     * `maxRetries` is the maximum number of retries.
     */
    public let maxRetries: Int?

    public init(error: ErrorFn? = nil, maxRetries: Int? = nil) {
        self.error = error
        self.maxRetries = maxRetries
    }
}

/**
 * `ChannelEventType` represents the type of channel event.
 */
public enum ChannelEventType: String {
    /**
     * `presenceChanged` means that the channel presence count has changed.
     */
    case presenceChanged = "presence-changed"

    /**
     * `initialized` means that the channel watch has been initialized.
     */
    case initialized

    /**
     * `broadcast` means that a broadcast message has been received from a remote client.
     */
    case broadcast

    /**
     * `localBroadcast` means that a broadcast message has been sent by the local client.
     */
    case localBroadcast = "local-broadcast"

    /**
     * `authError` means that an authentication error has occurred.
     */
    case authError = "auth-error"

    /**
     * `syncError` means that a non-recoverable sync (RefreshChannel) error occurred.
     * Subscribers can use this to render an error state in the UI without polling
     * internal SDK state. The SDK still retries via its sync loop, so subsequent
     * successful events can be treated as recovery.
     */
    case syncError = "sync-error"
}

/**
 * `ChannelEvent` is the base protocol for events occurring on a channel.
 */
public protocol ChannelEvent {
    var type: ChannelEventType { get }
}

/**
 * `ChannelPresenceEvent` represents a presence count change on a channel.
 */
public struct ChannelPresenceEvent: ChannelEvent {
    public let type: ChannelEventType
    public let count: Int
}

/**
 * `ChannelBroadcastEvent` represents a broadcast event received from a remote client.
 */
public struct ChannelBroadcastEvent: ChannelEvent {
    public let type: ChannelEventType = .broadcast
    public let clientID: ActorID
    public let topic: String
    public let payload: Payload
    public let options: BroadcastOptions?
}

/**
 * `ChannelLocalBroadcastEvent` represents a broadcast event sent from the local client.
 */
public struct ChannelLocalBroadcastEvent: ChannelEvent {
    public let type: ChannelEventType = .localBroadcast
    public let clientID: ActorID
    public let topic: String
    public let payload: Payload
    public let options: BroadcastOptions?
}

/**
 * `ChannelAuthErrorEvent` represents an authentication error on a channel.
 */
public struct ChannelAuthErrorEvent: ChannelEvent {
    public let type: ChannelEventType = .authError
    public let reason: String
    public let method: String
}

/**
 * `ChannelSyncErrorEvent` represents a non-recoverable sync (RefreshChannel) error.
 * Subsequent successful events on the channel imply recovery — there is no separate
 * "recovered" event.
 */
public struct ChannelSyncErrorEvent: ChannelEvent {
    public let type: ChannelEventType = .syncError
    public let error: Error
    public let method: String
}

/**
 * `Channel` represents a lightweight channel for presence and messaging.
 * It implements `Attachable` so it can be managed by `Attachment`.
 */
@MainActor
public class Channel: Attachable, @unchecked Sendable {
    public typealias EventCallback = @MainActor (any ChannelEvent) -> Void
    public typealias BroadcastEventCallback = @MainActor (ChannelBroadcastEvent) -> Void
    public typealias LocalBroadcastEventCallback = @MainActor (ChannelLocalBroadcastEvent) -> Void
    public typealias PresenceEventCallback = @MainActor (ChannelPresenceEvent) -> Void
    public typealias AuthErrorEventCallback = @MainActor (ChannelAuthErrorEvent) -> Void
    public typealias SyncErrorEventCallback = @MainActor (ChannelSyncErrorEvent) -> Void

    private static let keyPathSeparator: Character = "."

    private nonisolated(unsafe) var key: String
    private var status: ChannelStatus
    private var actorID: ActorID?
    private var sessionID: String?
    private var sessionCount: Int
    private var seq: Int64
    private var isRealtimeSync: Bool

    private var broadcastCallback: BroadcastEventCallback?
    private var localBroadcastCallback: LocalBroadcastEventCallback?
    private var presenceCallback: PresenceEventCallback?
    private var authErrorCallback: AuthErrorEventCallback?
    private var syncErrorCallback: SyncErrorEventCallback?
    private var allCallback: EventCallback?
    private var topicCallbacks: [String: BroadcastEventCallback] = [:]

    /**
     * Creates a new instance of `Channel`.
     *
     * @param key - the key of the channel.
     * @param isRealtime - whether to sync the channel in realtime (default: true).
     */
    public init(key: String, isRealtime: Bool = true) throws {
        try Channel.validateChannelKey(key)
        self.key = key
        self.status = .detached
        self.sessionCount = 0
        self.seq = 0
        self.isRealtimeSync = isRealtime
    }

    /**
     * `getKey` returns the key of this channel.
     */
    public nonisolated func getKey() -> String {
        return self.key
    }

    /**
     * `getFirstKeyPath` returns the first key path segment of the channel key.
     */
    public func getFirstKeyPath() -> String {
        return String(self.key.split(separator: Channel.keyPathSeparator, maxSplits: 1).first ?? "")
    }

    /**
     * `getStatus` returns the status of this channel as a `ResourceStatus`.
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
     * `getChannelStatus` returns the status of this channel.
     */
    public func getChannelStatus() -> ChannelStatus {
        return self.status
    }

    /**
     * `applyStatus` applies the channel status into this channel.
     */
    func applyStatus(_ status: ChannelStatus) {
        self.status = status
    }

    /**
     * `setStatus` sets the status of this channel.
     */
    func setStatus(_ status: ChannelStatus) {
        self.status = status
    }

    /**
     * `isAttached` returns whether this channel is attached or not.
     */
    public func isAttached() -> Bool {
        return self.status == .attached
    }

    /**
     * `getActorID` returns the actor ID of this channel.
     */
    public func getActorID() -> ActorID? {
        return self.actorID
    }

    /**
     * `setActor` sets the actor ID of this channel.
     */
    public func setActor(_ actorID: ActorID) {
        self.actorID = actorID
    }

    /**
     * `getSessionID` returns the session ID from the server.
     */
    public func getSessionID() -> String? {
        return self.sessionID
    }

    /**
     * `setSessionID` sets the session ID from the server.
     */
    func setSessionID(_ id: String) {
        self.sessionID = id
    }

    /**
     * `getSessionCount` returns the current channel online session count value.
     */
    public func getSessionCount() -> Int {
        return self.sessionCount
    }

    /**
     * `updateSessionCount` updates the session count and sequence number if the sequence
     * is newer. Returns true if the count was updated, false if the update was ignored.
     */
    @discardableResult
    public func updateSessionCount(_ sessionCount: Int, _ seq: Int64) -> Bool {
        // Always accept initialization (seq == 0)
        if seq == 0 || seq > self.seq {
            self.sessionCount = sessionCount
            self.seq = seq
            return true
        }
        return false
    }

    /**
     * `isRealtime` returns whether this channel uses realtime sync.
     */
    public func isRealtime() -> Bool {
        return self.isRealtimeSync
    }

    /**
     * `hasLocalChanges` returns whether this channel has local changes.
     * Always returns false as the channel is server-managed.
     */
    public func hasLocalChanges() async -> Bool {
        return false
    }

    /**
     * `publish` for `Attachable` protocol conformance. Channel uses its own event
     * system, so `DocEvent` instances received here are ignored.
     */
    public func publish(_: any DocEvent) {
        // Channel uses its own event system.
    }

    // MARK: - Subscribe

    /**
     * `subscribeBroadcast` registers a callback for broadcast events received from
     * remote clients on this channel.
     */
    public func subscribeBroadcast(_ callback: @escaping BroadcastEventCallback) {
        self.broadcastCallback = callback
    }

    /**
     * `subscribeLocalBroadcast` registers a callback for broadcast events sent by
     * this client on this channel.
     */
    public func subscribeLocalBroadcast(_ callback: @escaping LocalBroadcastEventCallback) {
        self.localBroadcastCallback = callback
    }

    /**
     * `subscribePresenceChange` registers a callback for presence count change events.
     */
    public func subscribePresenceChange(_ callback: @escaping PresenceEventCallback) {
        self.presenceCallback = callback
    }

    /**
     * `subscribeAuthError` registers a callback for authentication errors.
     */
    public func subscribeAuthError(_ callback: @escaping AuthErrorEventCallback) {
        self.authErrorCallback = callback
    }

    /**
     * `subscribeSyncError` registers a callback for non-recoverable sync errors.
     * Subsequent successful events imply recovery — there is no separate
     * "recovered" event.
     */
    public func subscribeSyncError(_ callback: @escaping SyncErrorEventCallback) {
        self.syncErrorCallback = callback
    }

    /**
     * `subscribeAll` registers a callback for every channel event.
     */
    public func subscribeAll(_ callback: @escaping EventCallback) {
        self.allCallback = callback
    }

    /**
     * `subscribeTopic` registers a callback for broadcast events matching a specific topic.
     */
    public func subscribeTopic(_ topic: String, _ callback: @escaping BroadcastEventCallback) {
        self.topicCallbacks[topic] = callback
    }

    // MARK: - Unsubscribe

    public func unsubscribeBroadcast() { self.broadcastCallback = nil }
    public func unsubscribeLocalBroadcast() { self.localBroadcastCallback = nil }
    public func unsubscribePresenceChange() { self.presenceCallback = nil }
    public func unsubscribeAuthError() { self.authErrorCallback = nil }
    public func unsubscribeSyncError() { self.syncErrorCallback = nil }
    public func unsubscribeAll() { self.allCallback = nil }
    public func unsubscribeTopic(_ topic: String) { self.topicCallbacks.removeValue(forKey: topic) }

    // MARK: - Publish / broadcast

    /**
     * `publish` dispatches an event to all matching callbacks.
     */
    public func publish(_ event: any ChannelEvent) {
        self.allCallback?(event)

        if let event = event as? ChannelBroadcastEvent {
            self.broadcastCallback?(event)
            self.topicCallbacks[event.topic]?(event)
        } else if let event = event as? ChannelLocalBroadcastEvent {
            self.localBroadcastCallback?(event)
        } else if let event = event as? ChannelPresenceEvent {
            self.presenceCallback?(event)
        } else if let event = event as? ChannelAuthErrorEvent {
            self.authErrorCallback?(event)
        } else if let event = event as? ChannelSyncErrorEvent {
            self.syncErrorCallback?(event)
        }
    }

    /**
     * `broadcast` sends a message to all clients watching this channel.
     */
    public func broadcast(topic: String, payload: Payload, options: BroadcastOptions? = nil) throws {
        guard self.status == .attached else {
            throw YorkieError(
                code: .errNotAttached,
                message: "channel is not attached: \(self.status)"
            )
        }
        guard let actorID = self.actorID else {
            throw YorkieError(code: .errInvalidArgument, message: "actorID is not set")
        }

        self.publish(
            ChannelLocalBroadcastEvent(
                clientID: actorID,
                topic: topic,
                payload: payload,
                options: options
            )
        )
    }

    // MARK: - Validation

    private static func validateChannelKey(_ key: String) throws {
        if key.isEmpty {
            throw YorkieError(code: .errInvalidArgument, message: "channel key must not be empty")
        }
        if key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw YorkieError(code: .errInvalidArgument, message: "channel key must not contain a whitespace")
        }
        let sep = String(Channel.keyPathSeparator)
        if key.hasPrefix(sep) {
            throw YorkieError(code: .errInvalidArgument, message: "channel key must not start with a period")
        }
        if key.hasSuffix(sep) {
            throw YorkieError(code: .errInvalidArgument, message: "channel key must not end with a period")
        }
        if key.contains("\(sep)\(sep)") {
            throw YorkieError(code: .errInvalidArgument, message: "channel key path must not empty")
        }
    }
}
