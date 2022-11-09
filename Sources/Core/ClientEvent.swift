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
 * `ClientEventType` is client event types
 */
public enum ClientEventType: String {
    /**
     * client event type when status changed.
     */
    case statusChanged = "status-changed"
    /**
     * client event type when documents changed.
     */
    case documentsChanged = "documents-changed"
    /**
     * client event type when peers changed.
     */
    case peersChanged = "peers-changed"
    /**
     * client event type when stream connection changed.
     */
    case streamConnectionStatusChanged = "stream-connection-status-changed"
    /**
     * client event type when document synced.
     */
    case documentSynced = "document-synced"
}

public protocol BaseClientEvent {
    var type: ClientEventType { get }
}

/**
 * `StatusChangedEvent` is an event that occurs when the Client's state changes.
 */
struct StatusChangedEvent: BaseClientEvent {
    /**
     * enum {@link ClientEventType}.StatusChanged
     */
    var type: ClientEventType = .statusChanged
    /**
     * `DocumentsChangedEvent` value
     */
    var value: ClientStatus
}

/**
 * `DocumentsChangedEvent` is an event that occurs when documents attached to
 * the client changes.
 */
struct DocumentsChangedEvent: BaseClientEvent {
    /**
     * enum {@link ClientEventType}.DocumentsChangedEvent
     */
    var type: ClientEventType = .documentsChanged
    /**
     * `DocumentsChangedEvent` value
     */
    var value: [String]
}

/**
 * `PeersChangedEvent` is an event that occurs when the states of another peers
 * of the attached documents changes.
 */
struct PeerChangedEvent: BaseClientEvent {
    /**
     * `PeerChangedEvent` type
     * enum {@link ClientEventType}.PeersChangedEvent
     */
    var type: ClientEventType = .peersChanged
    /**
     * `PeersChangedEvent` value
     */
    var value: [String: [String: Presence]]
}

/**
 * `StreamConnectionStatusChangedEvent` is an event that occurs when
 * the client's stream connection state changes.
 */
struct StreamConnectionStatusChangedEvent: BaseClientEvent {
    /**
     * `StreamConnectionStatusChangedEvent` type
     * enum {@link ClientEventType}.StreamConnectionStatusChangedEvent
     */
    var type: ClientEventType = .streamConnectionStatusChanged
    /**
     * `StreamConnectionStatusChangedEvent` value
     */
    var value: StreamConnectionStatus
}

/**
 * `DocumentSyncedEvent` is an event that occurs when documents
 * attached to the client are synced.
 */
struct DocumentSyncedEvent: BaseClientEvent {
    /**
     * `DocumentSyncedEvent` type
     * enum {@link ClientEventType}.DocumentSyncedEvent
     */
    var type: ClientEventType = .documentSynced
    /**
     * `DocumentSyncedEvent` value
     */
    var value: DocumentSyncResultType
}

/**
 * `DocumentSyncResultType` is document sync result types
 */
enum DocumentSyncResultType: String {
    /**
     * type when Document synced.
     */
    case synced
    /**
     * type when Document sync failed.
     */
    case syncFailed = "sync-failed"
}
