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

import Combine
import Foundation
import GRPC
import NIO

/**
 * `ClientStatus` represents the status of the client.
 */
public enum ClientStatus: String {
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

struct Attachment {
    var doc: Document
    var isRealtimeSync: Bool
    var peerPresenceMap: [String: PresenceInfo]
    var remoteChangeEventReceived: Bool?
}

/**
 * `PresenceInfo` is presence information of this client.
 */
struct PresenceInfo {
    var clock: Int32
    var data: Presence
}

/**
 * `ClientOptions` are user-settable options used when defining clients.
 */
public struct ClientOptions {
    private enum DefaultClientOptions {
        static let syncLoopDuration = 50
        static let reconnectStreamDelay = 1000 // 1000 millisecond
    }

    /**
     * `key` is the client key. It is used to identify the client.
     * If not set, a random key is generated.
     */
    var key: String?

    /**
     * `presence` is the presence information of this client. If the client
     * attaches a document, the presence information is sent to the other peers
     * attached to the document.
     */
    var presence: Presence?

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

    public init(key: String? = nil, apiKey: String? = nil, token: String? = nil, syncLoopDuration: Int? = nil, reconnectStreamDelay: Int? = nil) {
        self.key = key
        self.apiKey = apiKey
        self.token = token
        self.syncLoopDuration = syncLoopDuration ?? DefaultClientOptions.syncLoopDuration
        self.reconnectStreamDelay = reconnectStreamDelay ?? DefaultClientOptions.reconnectStreamDelay
    }
}

public struct RPCAddress {
    let host: String
    let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/**
 * `Client` is a normal client that can communicate with the server.
 * It has documents and sends changes of the documents in local
 * to the server to synchronize with other replicas in remote.
 */
public final class Client {
    private var presenceInfo: PresenceInfo
    private var attachmentMap: [String: Attachment]
    private let syncLoopDuration: Int
    private let reconnectStreamDelay: Int

    private let rpcClient: YorkieServiceAsyncClient
    private var watchLoopReconnectTimer: Timer?
    private var watchLoopTask: Task<Void, Never>?

    private let group: EventLoopGroup
    private let loopQueue = DispatchQueue.global()

    // Public variables.
    public private(set) var id: ActorID?
    public let key: String
    public var isActive: Bool { self.status == .activated }
    public private(set) var status: ClientStatus
    public var presence: Presence { self.presenceInfo.data }
    public let eventStream: PassthroughSubject<BaseClientEvent, Error>

    /**
     * @param rpcAddr - the address of the RPC server.
     * @param opts - the options of the client.
     */
    public init(rpcAddress: RPCAddress, options: ClientOptions) throws {
        self.key = options.key ?? UUID().uuidString
        self.presenceInfo = PresenceInfo(clock: 0, data: options.presence ?? [String: Any]())

        self.status = .deactivated
        self.attachmentMap = [String: Attachment]()
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

        self.rpcClient = YorkieServiceAsyncClient(channel: channel)
        self.eventStream = PassthroughSubject()
    }

    deinit {
        try? self.group.syncShutdownGracefully()
    }

    /**
     * `ativate` activates this client. That is, it register itself to the server
     * and receives a unique ID from the server. The given ID is used to
     * distinguish different clients.
     */
    public func activate() async throws {
        guard self.isActive == false else {
            return
        }

        var activateRequest = ActivateClientRequest()
        activateRequest.clientKey = self.key

        do {
            let activateResponse = try await self.rpcClient.activateClient(activateRequest, callOptions: nil)

            self.id = activateResponse.clientID.toHexString

            self.status = .activated
            await self.runSyncLoop()
            self.runWatchLoop()

            let changeEvent = StatusChangedEvent(value: self.status)
            self.eventStream.send(changeEvent)

            Logger.debug("Client(\(self.key)) activated")
        } catch {
            Logger.error("Failed to request activate client(\(self.key)).", error: error)
            throw error
        }
    }

    /**
     * `deactivate` deactivates this client.
     */
    public func deactivate() async throws {
        guard self.status == .activated, let clientID = self.id else {
            return
        }

        self.watchLoopTask?.cancel()
        self.watchLoopTask = nil

        var deactivateRequest = DeactivateClientRequest()

        guard let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "ClientID is not Hex String!")
        }
        deactivateRequest.clientID = clientIDData

        do {
            _ = try await self.rpcClient.deactivateClient(deactivateRequest)
        } catch {
            Logger.error("Failed to request deactivate client(\(self.key)).", error: error)
            throw error
        }

        self.status = .deactivated

        let changeEvent = StatusChangedEvent(value: self.status)
        self.eventStream.send(changeEvent)

        Logger.info("Client(\(self.key) deactivated.")
    }

    /**
     *   `attach` attaches the given document to this client. It tells the server that
     *   the client will synchronize the given document.
     */
    @discardableResult
    public func attach(_ doc: Document, _ isManualSync: Bool = false) async throws -> Document {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        guard let clientID = self.id, let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        await doc.setActor(clientID)

        var attachDocumentRequest = AttachDocumentRequest()
        attachDocumentRequest.clientID = clientIDData
        attachDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack())

        do {
            let result = try await self.rpcClient.attachDocument(attachDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack: pack)

            self.attachmentMap[doc.getKey()] = Attachment(doc: doc, isRealtimeSync: !isManualSync, peerPresenceMap: [String: PresenceInfo]())
            self.runWatchLoop()

            Logger.info("[AD] c:\"\(self.key))\" attaches d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request attach document(\(self.key)).", error: error)
            throw error
        }
    }

    /**
     * `detach` detaches the given document from this client. It tells the
     * server that this client will no longer synchronize the given document.
     *
     * To collect garbage things like CRDT tombstones left on the document, all
     * the changes should be applied to other replicas before GC time. For this,
     * if the document is no longer used by this client, it should be detached.
     */
    @discardableResult
    public func detach(_ doc: Document) async throws -> Document {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        guard let clientID = self.id, let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        var detachDocumentRequest = DetachDocumentRequest()
        detachDocumentRequest.clientID = clientIDData
        detachDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack())

        do {
            let result = try await self.rpcClient.detachDocument(detachDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack: pack)

            self.attachmentMap.removeValue(forKey: doc.getKey())

            self.runWatchLoop()

            Logger.info("[DD] c:\"\(self.key)\" detaches d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request detach document(\(self.key)).", error: error)
            throw error
        }
    }

    /**
     * `sync` pushes local changes of the attached documents to the server and
     * receives changes of the remote replica from the server then apply them to
     * local documents.
     */
    @discardableResult
    public func sync() async throws -> [Document] {
        let documents = self.attachmentMap.values.compactMap { $0.doc }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                documents.forEach { document in
                    group.addTask {
                        try await self.syncInternal(document)
                    }
                }

                try await group.waitForAll()
            }

            return documents
        } catch {
            let event = DocumentSyncedEvent(value: .syncFailed)
            self.eventStream.send(event)

            throw error
        }
    }

    /**
     * `updatePresence` updates the presence of this client.
     */
    public func updatePresence(_ key: Presence.Key, _ value: Any) async throws {
        guard self.isActive, let id = self.id else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        self.presenceInfo.clock += 1
        self.presenceInfo.data[key] = value

        if self.attachmentMap.isEmpty {
            return
        }

        var keys = [String]()

        for (key, attachment) in self.attachmentMap {
            if attachment.isRealtimeSync == false {
                continue
            }

            self.attachmentMap[key]?.peerPresenceMap[id] = self.presenceInfo

            keys.append(attachment.doc.getKey())
        }

        var updatePresenceRequest = UpdatePresenceRequest()
        updatePresenceRequest.client = Converter.toClient(id: id, presence: self.presenceInfo)
        updatePresenceRequest.documentKeys = keys

        let event = PeerChangedEvent(value: keys.reduce([String: [String: Presence]](), self.getPeersWithDocKey(peersMap:key:)))
        self.eventStream.send(event)

        do {
            _ = try await self.rpcClient.updatePresence(updatePresenceRequest)
            Logger.info("[UM] c\"\(self.key)\" updated")
        } catch {
            Logger.error("[UM] c\"\(self.key)\" err : \(error)")
        }
    }

    /**
     * `getPeers` returns the peers of the given document.
     */
    public func getPeers(key: String) -> [String: Presence] {
        var peers = [String: Presence]()
        self.attachmentMap[key]?.peerPresenceMap.forEach {
            peers[$0.key] = $0.value.data
        }
        return peers
    }

    /**
     * `getPeersWithDocKey` returns the peers of the given document wrapped in an object.
     */
    private func getPeersWithDocKey(peersMap: [String: [String: Presence]], key: String) -> [String: [String: Presence]] {
        var newPeerMap = peersMap
        var peers = [String: Presence]()
        self.attachmentMap[key]?.peerPresenceMap.forEach {
            peers[$0.key] = $0.value.data
        }
        newPeerMap[key] = peers
        return newPeerMap
    }

    private func doSyncLoop() async {
        guard self.isActive else {
            Logger.debug("[SL] c:\"\(self.key)\" exit sync loop")
            return
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (key, attachment) in self.attachmentMap where attachment.isRealtimeSync {
                    let docChanged = await attachment.doc.hasLocalChanges()

                    if docChanged || attachment.remoteChangeEventReceived ?? false {
                        self.attachmentMap[key]?.remoteChangeEventReceived = false
                        group.addTask {
                            try await self.syncInternal(attachment.doc)
                        }
                    }
                }

                try await group.waitForAll()
            }

            DispatchQueue.main.async {
                let syncLoopDuration = self.watchLoopTask != nil ? self.syncLoopDuration : self.reconnectStreamDelay
                Timer.scheduledTimer(withTimeInterval: Double(syncLoopDuration) / 1000, repeats: false) { _ in
                    self.loopQueue.sync {
                        Task {
                            await self.doSyncLoop()
                        }
                    }
                }
            }

        } catch {
            Logger.error("[SL] c:\"\(self.key)\" sync failed: \(error)")

            let event = DocumentSyncedEvent(value: .syncFailed)
            self.eventStream.send(event)

            DispatchQueue.main.async {
                Timer.scheduledTimer(withTimeInterval: Double(self.reconnectStreamDelay) / 1000, repeats: false) { _ in
                    self.loopQueue.sync {
                        Task {
                            await self.doSyncLoop()
                        }
                    }
                }
            }
        }
    }

    private func runSyncLoop() async {
        Logger.debug("[SL] c:\"\(self.key)\" run sync loop")
        await self.doSyncLoop()
    }

    private func doWatchLoop() {
        self.watchLoopTask?.cancel()
        self.watchLoopTask = nil

        self.watchLoopReconnectTimer?.invalidate()
        self.watchLoopReconnectTimer = nil

        guard self.isActive, let id = self.id else {
            Logger.debug("[WL] c:\"\(self.key)\" exit watch loop")
            return
        }

        let realtimeSyncDocKeys = self.attachmentMap.values
            .filter { $0.isRealtimeSync }
            .compactMap { $0.doc.getKey() }

        if realtimeSyncDocKeys.isEmpty {
            Logger.debug("[WL] c:\"\(self.key)\" exit watch loop")
            return
        }

        var request = WatchDocumentsRequest()
        request.client = Converter.toClient(id: id, presence: self.presenceInfo)
        request.documentKeys = realtimeSyncDocKeys

        let stream = self.rpcClient.watchDocuments(request)

        self.watchLoopTask = Task {
            do {
                for try await response in stream {
                    self.loopQueue.sync {
                        self.handleWatchDocumentsResponse(keys: realtimeSyncDocKeys, response: response)
                    }
                }
            } catch {
                switch error {
                case is CancellationError:
                    break
                default:
                    Logger.warn("[WL] c:\"\(self.key)\" has Error \(error)")

                    self.onStreamDisconnect()
                }
            }
        }
    }

    private func runWatchLoop() {
        Logger.debug("[WL] c:\"\(self.key)\" run watch loop")

        self.doWatchLoop()
    }

    private func handleWatchDocumentsResponse(keys: [String], response: WatchDocumentsResponse) {
        Logger.debug("[WL] c:\"\(self.key)\" got response \(response)")

        guard let body = response.body else {
            return
        }

        switch body {
        case .initialization(let initialization):
            initialization.peersMapByDoc.forEach { docID, pbPeers in
                for pbClient in pbPeers.clients {
                    self.attachmentMap[docID]?.peerPresenceMap[pbClient.id.toHexString] = Converter.fromPresence(pbPresence: pbClient.presence)
                }
            }

            let event = PeerChangedEvent(value: keys.reduce([String: [String: Presence]](), self.getPeersWithDocKey(peersMap:key:)))
            self.eventStream.send(event)
        case .event(let pbWatchEvent):
            let responseKeys = pbWatchEvent.documentKeys
            let publisher = pbWatchEvent.publisher.id.toHexString
            let presence = Converter.fromPresence(pbPresence: pbWatchEvent.publisher.presence)

            for key in responseKeys {
                switch pbWatchEvent.type {
                case .documentsWatched:
                    self.attachmentMap[key]?.peerPresenceMap[publisher] = presence
                case .documentsUnwatched:
                    self.attachmentMap[key]?.peerPresenceMap.removeValue(forKey: publisher)
                case .documentsChanged:
                    self.attachmentMap[key]?.remoteChangeEventReceived = true
                case .presenceChanged:
                    if let peerPresence = self.attachmentMap[key]?.peerPresenceMap[publisher], peerPresence.clock > presence.clock {
                        break
                    }

                    self.attachmentMap[key]?.peerPresenceMap[publisher] = presence
                case .UNRECOGNIZED:
                    break
                }
            }

            switch pbWatchEvent.type {
            case .documentsChanged:
                let event = DocumentsChangedEvent(value: responseKeys)
                self.eventStream.send(event)
            case .documentsWatched, .documentsUnwatched, .presenceChanged:
                let event = PeerChangedEvent(value: keys.reduce([String: [String: Presence]](), self.getPeersWithDocKey(peersMap:key:)))
                self.eventStream.send(event)
            case .UNRECOGNIZED:
                break
            }
        }
    }

    private func onStreamDisconnect() {
        self.watchLoopTask?.cancel()
        self.watchLoopTask = nil

        DispatchQueue.main.async {
            self.watchLoopReconnectTimer = Timer.scheduledTimer(withTimeInterval: Double(self.reconnectStreamDelay) / 1000, repeats: false) { _ in
                self.doWatchLoop()
            }
        }

        let event = StreamConnectionStatusChangedEvent(value: .disconnected)
        self.eventStream.send(event)
    }

    @discardableResult
    private func syncInternal(_ doc: Document) async throws -> Document {
        guard let clientID = self.id, let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "Invalid Client ID!")
        }

        var pushPullRequest = PushPullRequest()
        pushPullRequest.clientID = clientIDData

        let requestPack = await doc.createChangePack()
        let localSize = requestPack.getChangeSize()

        pushPullRequest.changePack = Converter.toChangePack(pack: requestPack)

        do {
            let response = try await self.rpcClient.pushPull(pushPullRequest)

            let responsePack = try Converter.fromChangePack(response.changePack)
            try await doc.applyChangePack(pack: responsePack)

            let event = DocumentSyncedEvent(value: .synced)
            self.eventStream.send(event)

            let docKey = doc.getKey()
            let remoteSize = responsePack.getChangeSize()
            Logger.info("[PP] c:\"\(self.key)\" sync d:\"\(docKey)\", push:\(localSize) pull:\(remoteSize) cp:\(responsePack.getCheckpoint().structureAsString)")

            return doc
        } catch {
            Logger.error("[PP] c:\"\(self.key)\" err : \(error)")

            throw error
        }
    }
}
