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
import GRPC
import NIO

/**
 * `ClientStatus` represents the status of the client.
 */
enum ClientStatus: String {
    /**
     * Deactivated means that the client is not registered to the server.
     */
    case deactivated
    /**
     * Activated means that the client is registered to the server.
     * So, the client can sync documents with the server.
     */
    case activated
}

/**
 * `StreamConnectionStatus` is stream connection status types
 */
enum StreamConnectionStatus {
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

/**
 * `ClientEventType` is client event types
 */
enum ClientEventType: String {
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

protocol BaseClientEvent {
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
 * `PresenceInfo` is presence information of this client.
 */
struct PresenceInfo<P> {
    var clock: Int
    var data: P
}

/**
 * `ClientOptions` are user-settable options used when defining clients.
 */
struct ClientOptions {
    /**
     * `key` is the client key. It is used to identify the client.
     * If not set, a random key is generated.
     */
    var key: String?

    /**
     * `apiKey` is the API key of the project. It is used to identify the project.
     * If not set, API key of the default project is used.
     */
    var apiKey: String?

    /**
     * `token` is the authentication token of this client. It is used to identify
     * the user of the client.
     */
    var token: String?

    /**
     * `syncLoopDuration` is the duration of the sync loop. After each sync loop,
     * the client waits for the duration to next sync. The default value is
     * `50`(ms).
     */
    var syncLoopDuration: Int

    /**
     * `reconnectStreamDelay` is the delay of the reconnect stream. If the stream
     * is disconnected, the client waits for the delay to reconnect the stream. The
     * default value is `1000`(ms).
     */
    var reconnectStreamDelay: Int

    init(key: String? = nil, apiKey: String? = nil, token: String? = nil, syncLoopDuration: Int = 50, reconnectStreamDelay: Int = 1000) {
        self.key = key
        self.apiKey = apiKey
        self.token = token
        self.syncLoopDuration = syncLoopDuration
        self.reconnectStreamDelay = reconnectStreamDelay
    }
}

struct RPCAddress {
    let host: String
    let port: Int
}

/**
 * `Client` is a normal client that can communicate with the server.
 * It has documents and sends changes of the documents in local
 * to the server to synchronize with other replicas in remote.
 */
final class Client {
    private(set) var id: Data? // To be ActorID
    let key: String
    private(set) var status: ClientStatus

    var isActive: Bool {
        self.status == .activated
    }

    private let syncLoopDuration: Int
    private let reconnectStreamDelay: Int
    private let rpcClient: Yorkie_V1_YorkieServiceAsyncClient
    private let group: EventLoopGroup

    /**
     * @param rpcAddr - the address of the RPC server.
     * @param opts - the options of the client.
     */
    init(rpcAddress: RPCAddress, options: ClientOptions) throws {
        self.key = options.key ?? UUID().uuidString
        self.status = .deactivated
        self.syncLoopDuration = options.syncLoopDuration
        self.reconnectStreamDelay = options.reconnectStreamDelay

        self.group = PlatformSupport.makeEventLoopGroup(loopCount: 1) // EventLoopGroup helpers

        let channel: GRPCChannel
        do {
            channel = try GRPCChannelPool.with(target: .host(rpcAddress.host, port: rpcAddress.port),
                                               transportSecurity: .plaintext,
                                               eventLoopGroup: self.group)
        } catch {
            Logger.error("Failed to initialize client", error: error)
            throw error
        }

        self.rpcClient = Yorkie_V1_YorkieServiceAsyncClient(channel: channel)
    }

    deinit {
        try? self.group.syncShutdownGracefully()
    }

    /**
     * `ativate` activates this client. That is, it register itself to the server
     * and receives a unique ID from the server. The given ID is used to
     * distinguish different clients.
     */
    func activate() async throws {
        guard self.isActive == false else {
            return
        }

        var activateRequest = Yorkie_V1_ActivateClientRequest()
        activateRequest.clientKey = self.key

        let activateResponse: Yorkie_V1_ActivateClientResponse
        do {
            activateResponse = try await self.rpcClient.activateClient(activateRequest, callOptions: nil)
        } catch {
            Logger.error("Failed to request activate client(\(self.key)).", error: error)
            throw error
        }

        self.id = activateResponse.clientID

        self.status = .activated

        Logger.debug("Client(\(self.key)) activated")
    }

    /**
     * `deactivate` deactivates this client.
     */
    func deactivate() async throws {
        guard self.status == .activated, let clientId = self.id else {
            return
        }

        var deactivateRequest = Yorkie_V1_DeactivateClientRequest()
        deactivateRequest.clientID = clientId

        do {
            _ = try await self.rpcClient.deactivateClient(deactivateRequest)
        } catch {
            Logger.error("Failed to request deactivate client(\(self.key)).", error: error)
            throw error
        }

        self.status = .deactivated
        Logger.info("Client(\(self.key) deactivated.")
    }
}
