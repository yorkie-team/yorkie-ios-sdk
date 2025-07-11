/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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
 * `DocEventType` is document event types
 */
public enum DocEventType: String {
    /**
     * status changed event type
     */
    case statusChanged = "status-changed"

    /**
     * `connectionChanged` means that the watch stream connection status has changed.
     */
    case connectionChanged = "connection-changed"

    /**
     * `syncStatusChanged` means that the document sync status has changed.
     */
    case syncStatusChanged = "sync-status-changed"

    /**
     * snapshot event type
     */
    case snapshot

    /**
     * local document change event type
     */
    case localChange = "local-change"

    /**
     * remote document change event type
     */
    case remoteChange = "remote-change"

    /**
     * `initialized` means that online clients have been loaded from the server.
     */
    case initialized

    /**
     * `watched` means that the client has established a connection with the server,
     * enabling real-time synchronization.
     */
    case watched

    /**
     * `unwatched` means that the connection has been disconnected.
     */
    case unwatched

    /**
     * `presenceChanged` means that the presences of the client has updated.
     */
    case presenceChanged = "presence-changed"

    /**
     * `broadcast` means that the broadcast event is received from the remote client.
     */
    case broadcast

    /**
     * `localBroadcast` means that the broadcast event is sent from the local client.
     */
    case localBroadcast = "local-broadcast"

    /**
     * `authError` indicates an authorization failure in syncLoop or watchLoop.
     */
    case authError = "auth-error"
}

/**
 * An event that occurs in ``Document``. It can be delivered
 */
public protocol DocEvent {
    var type: DocEventType { get }
}

public struct StatusInfo {
    public let status: DocStatus
    public let actorID: ActorID?
}

/**
 * `StatusChangedEvent` is an event that occurs when
 * the client's stream connection state changes.
 */
public struct StatusChangedEvent: DocEvent {
    public let type: DocEventType = .statusChanged
    /**
     * StatusChangedEvent type
     */
    var source: OpSource
    var value: StatusInfo
}

/**
 * `StreamConnectionStatus` is stream connection status types
 */
public enum StreamConnectionStatus {
    /**
     * stream connected
     */
    case connected
    /**
     * stream disconnected
     */
    case disconnected
}

/**
 * `ConnectionChangedEvent` is an event that occurs when
 * the client's stream connection state changes.
 */
public struct ConnectionChangedEvent: DocEvent {
    public let type: DocEventType = .connectionChanged
    /**
     * ConnectionChanged type
     */
    public var value: StreamConnectionStatus
}

/**
 * `DocSyncStatus` is document sync result types
 */
public enum DocSyncStatus: String {
    /**
     * type when Document synced.
     */
    case synced
    /**
     * type when Document sync failed.
     */
    case syncFailed = "sync-failed"
}

/**
 * `SyncStatusChangedEvent` is an event that occurs when document
 * attached to the client are synced.
 */
public struct SyncStatusChangedEvent: DocEvent {
    public let type: DocEventType = .syncStatusChanged
    /**
     * SyncStatusChangedEvent type
     */
    public var value: DocSyncStatus
}

/**
 * `SnapshotEvent` is an event that occurs when a snapshot is received from
 * the server.
 */
public struct SnapshotEvent: DocEvent {
    public let type: DocEventType = .snapshot
    /**
     * SnapshotEvent type
     */
    public var value: SnapshotInfo
}

/**
 * `SnapshotInfo` contains the full snapshot data of a document received from the server
 * at a given server sequence, along with the corresponding vector clock for synchronization.
 */
public struct SnapshotInfo {
    public let serverSeq: Int64
    public let snapshot: Data?
    public let snapshotVector: String
}

/**
 * `ChangeEvent` is an event that occurs when the document is changed
 * by local or remote changes.
 */
protocol ChangeEvent: DocEvent {
    var type: DocEventType { get }
    var value: ChangeInfo { get }
}

/**
 * `ChangeInfo` represents the modifications made during a document update
 * and the message passed.
 */
public struct ChangeInfo {
    public let message: String
    public let operations: [any OperationInfo]
    public let actorID: ActorID?
    public let clientSeq: UInt32
    public let serverSeq: String
}

/**
 * `LocalChangeEvent` is an event that occurs when the document is changed
 * by local changes.
 *
 */
public struct LocalChangeEvent: ChangeEvent {
    /**
     * ``DocEventType/localChange``
     */
    public let type: DocEventType = .localChange
    /**
     * LocalChangeEvent type
     */
    public var value: ChangeInfo
}

/**
 * `RemoteChangeEvent` is an event that occurs when the document is changed
 * by remote changes.
 *
 */
public struct RemoteChangeEvent: ChangeEvent {
    /**
     * ``DocEventType/remoteChange``
     */
    public let type: DocEventType = .remoteChange
    /**
     * RemoteChangeEvent type
     */
    public var value: ChangeInfo
}

/**
 * `PeersChangedValue` represents the value of the PeersChanged event.
 */
public typealias PeerElement = (clientID: ActorID, presence: [String: Any])

public struct InitializedEvent: DocEvent {
    /**
     * ``DocEventType/initialized``
     */
    public let type: DocEventType = .initialized
    /**
     * InitializedEvent type
     */
    public let source: OpSource = .local
    public let value: [PeerElement]
}

public struct WatchedEvent: DocEvent {
    /**
     * ``DocEventType/watched``
     */
    public let type: DocEventType = .watched
    /**
     * WatchedEvent type
     */
    public var value: PeerElement
}

public struct UnwatchedEvent: DocEvent {
    /**
     * ``DocEventType/unwatched``
     */
    public let type: DocEventType = .unwatched
    /**
     * UnwatchedEvent type
     */
    public var value: PeerElement
}

public struct PresenceChangedEvent: DocEvent {
    /**
     * ``DocEventType/presenceChanged``
     */
    public let type: DocEventType = .presenceChanged
    /**
     * PresenceChangedEvent type
     */
    public var value: PeerElement
}

public typealias ErrorFn = (Error) -> Void

public struct LocalBroadcastValue {
    let topic: String
    let payload: Payload
}

public struct BroadcastValue {
    let clientID: ActorID
    let topic: String
    let payload: Payload
}

public struct BroadcastEvent: DocEvent {
    /**
     * ``DocEventType/broadcast``
     */
    public let type: DocEventType = .broadcast
    /**
     * BroadcastEvent type
     */
    public let value: BroadcastValue
    public let options: BroadcastOptions?
}

public struct LocalBroadcastEvent: DocEvent {
    /**
     * ``DocEventType/localBroadcast``
     */
    public let type: DocEventType = .localBroadcast
    /**
     * LocalBroadcastEvent type
     */
    public let value: LocalBroadcastValue
    public let options: BroadcastOptions?
}

public struct AuthErrorValue: Equatable {
    public enum Method: CustomStringConvertible {
        case pushPull
        case watchDocuments
        case other(String)
        case broadcast

        public var description: String {
            switch self {
            case .pushPull:
                return "PushPull"
            case .watchDocuments:
                return "WatchDocuments"
            case .other(let name):
                return name
            case .broadcast:
                return "Broadcast"
            }
        }
    }

    public let reason: String
    public let method: Method

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.reason == rhs.reason else {
            return false
        }

        return String(describing: lhs.method) == String(describing: rhs.method)
    }
}

public struct AuthErrorEvent: DocEvent {
    /**
     * ``DocEventType/authError``
     */
    public let type: DocEventType = .authError
    /**
     * AuthErrorEvent type
     */
    public let value: AuthErrorValue
}
