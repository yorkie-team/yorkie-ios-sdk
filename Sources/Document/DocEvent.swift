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
}

/**
 * An event that occurs in ``Document``. It can be delivered
 * using ``Document/eventStream``.
 */
public protocol DocEvent {
    var type: DocEventType { get }
}

/**
 * `SnapshotEvent` is an event that occurs when a snapshot is received from
 * the server.
 *
 */
public struct SnapshotEvent: DocEvent {
    /**
     * ``DocEventType.snapshot``
     */
    public let type: DocEventType = .snapshot
    /**
     * SnapshotEvent type
     */
    public var value: Data
}

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
    public var value: [PeerElement]
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
