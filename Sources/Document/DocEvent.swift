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
}

public protocol DocEvent {
    var type: DocEventType { get }
}

/**
 * `SnapshotEvent` is an event that occurs when a snapshot is received from
 * the server.
 *
 */
struct SnapshotEvent: DocEvent {
    /**
     * ``DocEventType.snapshot``
     */
    let type: DocEventType = .snapshot
    /**
     * SnapshotEvent type
     */
    var value: Data
}

/**
 * `ChangeInfo` represents a pair of `Change` and the JsonPath of the changed
 * element.
 */
struct ChangeInfo {
    let change: Change
    let paths: [String]
}

/**
 * `LocalChangeEvent` is an event that occurs when the document is changed
 * by local changes.
 *
 */
struct LocalChangeEvent: DocEvent {
    /**
     * ``DocEventType/localChange``
     */
    let type: DocEventType = .localChange
    /**
     * LocalChangeEvent type
     */
    var value: [ChangeInfo]
}

/**
 * `RemoteChangeEvent` is an event that occurs when the document is changed
 * by remote changes.
 *
 */
struct RemoteChangeEvent: DocEvent {
    /**
     * ``DocEventType/remoteChange``
     */
    let type: DocEventType = .remoteChange
    /**
     * RemoteChangeEvent type
     */
    var value: [ChangeInfo]
}
