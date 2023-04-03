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
import Logging
import NIO

public typealias PresenceMap = [ActorID: Presence]

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

public enum SyncMode {
    case pushPull
    case pushOnly
    case pullOnly
}

struct Attachment {
    var doc: Document
    var docID: String
    var isRealtimeSync: Bool
    var realtimeSyncMode: SyncMode
    var peerPresenceMap: [ActorID: PresenceInfo]
    var remoteChangeEventReceived: Bool
    var remoteWatchStream: GRPCAsyncServerStreamingCall<WatchDocumentRequest, WatchDocumentResponse>?
    var watchLoopReconnectTimer: Timer?
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
        static let maximumAttachmentTimeout = 5000 // millisecond
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

    /**
     * `maximumAttachmentTimeout` is the latest time to wait for a initialization of attached document.
     * The default value is `5000`(ms).
     */
    var maximumAttachmentTimeout: Int

    public init(key: String? = nil, apiKey: String? = nil, token: String? = nil, syncLoopDuration: Int? = nil, reconnectStreamDelay: Int? = nil, attachTimeout: Int? = nil) {
        self.key = key
        self.apiKey = apiKey
        self.token = token
        self.syncLoopDuration = syncLoopDuration ?? DefaultClientOptions.syncLoopDuration
        self.reconnectStreamDelay = reconnectStreamDelay ?? DefaultClientOptions.reconnectStreamDelay
        self.maximumAttachmentTimeout = attachTimeout ?? DefaultClientOptions.maximumAttachmentTimeout
    }
}

public struct RPCAddress {
    public static let tlsPort = 443

    let host: String
    let port: Int

    public var isSecured: Bool {
        self.port == Self.tlsPort
    }

    public init(host: String, port: Int = Self.tlsPort) {
        self.host = host
        self.port = port
    }
}

/**
 * `Client` is a normal client that can communicate with the server.
 * It has documents and sends changes of the documents in local
 * to the server to synchronize with other replicas in remote.
 */
public actor Client {
    private var presenceInfo: PresenceInfo
    private var attachmentMap: [DocumentKey: Attachment]
    private let syncLoopDuration: Int
    private let reconnectStreamDelay: Int
    private let maximumAttachmentTimeout: Int

    private let rpcClient: YorkieServiceAsyncClient

    private let group: EventLoopGroup

    private var semaphoresForInitialzation = [DocumentKey: DispatchSemaphore]()

    // Public variables.
    public private(set) var id: ActorID?
    public nonisolated let key: String
    public var isActive: Bool { self.status == .activated }
    public private(set) var status: ClientStatus
    public var presence: Presence { self.presenceInfo.data }
    public nonisolated let eventStream: PassthroughSubject<BaseClientEvent, Never>

    /**
     * @param rpcAddr - the address of the RPC server.
     * @param opts - the options of the client.
     */
    public init(rpcAddress: RPCAddress, options: ClientOptions) {
        self.key = options.key ?? UUID().uuidString
        self.presenceInfo = PresenceInfo(clock: 0, data: options.presence ?? [String: Any]())

        self.status = .deactivated
        self.attachmentMap = [String: Attachment]()
        self.syncLoopDuration = options.syncLoopDuration
        self.reconnectStreamDelay = options.reconnectStreamDelay
        self.maximumAttachmentTimeout = options.maximumAttachmentTimeout

        self.group = PlatformSupport.makeEventLoopGroup(loopCount: 1) // EventLoopGroup helpers

        let builder: ClientConnection.Builder
        if rpcAddress.isSecured {
            builder = ClientConnection.usingTLSBackedByNetworkFramework(on: self.group)
        } else {
            builder = ClientConnection.insecure(group: self.group)
        }

        var gRPCLogger = Logging.Logger(label: "gRPC")
        gRPCLogger.logLevel = .info
        builder.withBackgroundActivityLogger(gRPCLogger)

        let channel = builder.connect(host: rpcAddress.host, port: rpcAddress.port)

        let authInterceptors: AuthClientInterceptors?
        if options.apiKey != nil || options.token != nil {
            authInterceptors = AuthClientInterceptors(apiKey: options.apiKey, token: options.token)
        } else {
            authInterceptors = nil
        }

        self.rpcClient = YorkieServiceAsyncClient(channel: channel, interceptors: authInterceptors)
        self.eventStream = PassthroughSubject()
    }

    deinit {
        try? self.group.syncShutdownGracefully()
        try? self.rpcClient.channel.close().wait()
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

        try self.attachmentMap.forEach {
            try self.stopWatchLoop($0.key)
        }

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
    public func attach(_ doc: Document, _ isRealtimeSync: Bool = true) async throws -> Document {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        guard let clientID = self.id, let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard await doc.status == .detached else {
            throw YorkieError.documentNotDetached(message: "\(doc) is not detached.")
        }

        await doc.setActor(clientID)

        var attachDocumentRequest = AttachDocumentRequest()
        attachDocumentRequest.clientID = clientIDData
        attachDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack())

        do {
            let docKey = doc.getKey()
            let semaphore = DispatchSemaphore(value: 0)

            self.semaphoresForInitialzation[docKey] = semaphore

            let result = try await self.rpcClient.attachDocument(attachDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack: pack, clientID: clientID)

            if await doc.status == .removed {
                throw YorkieError.documentRemoved(message: "\(doc) is removed.")
            }

            await doc.setStatus(.attached)

            self.attachmentMap[doc.getKey()] = Attachment(doc: doc, docID: result.documentID, isRealtimeSync: isRealtimeSync, realtimeSyncMode: .pushPull, peerPresenceMap: [String: PresenceInfo](), remoteChangeEventReceived: false)
            try self.runWatchLoop(docKey)

            Logger.info("[AD] c:\"\(self.key))\" attaches d:\"\(doc.getKey())\"")

            if isRealtimeSync {
                try await self.waitForInitialization(semaphore, docKey)
            }

            self.semaphoresForInitialzation.removeValue(forKey: docKey)

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

        guard let attachment = attachmentMap[doc.getKey()] else {
            throw YorkieError.documentNotAttached(message: "\(doc) is not attached.")
        }

        var detachDocumentRequest = DetachDocumentRequest()
        detachDocumentRequest.clientID = clientIDData
        detachDocumentRequest.documentID = attachment.docID
        detachDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack())

        do {
            let result = try await self.rpcClient.detachDocument(detachDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack: pack, clientID: clientID)

            if await doc.status != .removed {
                await doc.setStatus(.detached)
            }

            try self.stopWatchLoop(doc.getKey())

            self.attachmentMap.removeValue(forKey: doc.getKey())

            Logger.info("[DD] c:\"\(self.key)\" detaches d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request detach document(\(self.key)).", error: error)
            throw error
        }
    }

    /**
     * `pause` pause the realtime syncronization of the given document.
     */
    public func pause(_ doc: Document) throws {
        try self.changeRealtimeSyncSetting(doc, false)
    }

    /**
     * `resume` resume the realtime syncronization of the given document.
     */
    public func resume(_ doc: Document) throws {
        try self.changeRealtimeSyncSetting(doc, true)
    }

    /**
     * `remove` mrevoes the given document.
     */
    @discardableResult
    public func remove(_ doc: Document) async throws -> Document {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        guard let clientID = self.id, let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = attachmentMap[doc.getKey()] else {
            throw YorkieError.documentNotAttached(message: "\(doc) is not attached.")
        }

        var removeDocumentRequest = RemoveDocumentRequest()
        removeDocumentRequest.clientID = clientIDData
        removeDocumentRequest.documentID = attachment.docID
        removeDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack(.pushPull, true))

        do {
            let result = try await self.rpcClient.removeDocument(removeDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack: pack, clientID: clientID)

            try self.stopWatchLoop(doc.getKey())

            self.attachmentMap.removeValue(forKey: doc.getKey())

            Logger.info("[DD] c:\"\(self.key)\" removed d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request remove document(\(self.key)).", error: error)
            throw error
        }
    }

    public func changeRealtimeSyncMode(_ doc: Document, _ mode: SyncMode) {
        self.attachmentMap[doc.getKey()]?.realtimeSyncMode = mode
    }

    private func changeRealtimeSyncSetting(_ doc: Document, _ isRealtimeSync: Bool) throws {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        let docKey = doc.getKey()

        guard self.attachmentMap[docKey] != nil else {
            throw YorkieError.unexpected(message: "Can't find attachment by docKey! [\(docKey)]")
        }

        self.attachmentMap[docKey]?.isRealtimeSync = isRealtimeSync

        if isRealtimeSync {
            try self.runWatchLoop(docKey)
        } else {
            try self.stopWatchLoop(docKey)
        }
    }

    /**
     * `sync` pushes local changes of the attached documents to the server and
     * receives changes of the remote replica from the server then apply them to
     * local documents.
     */
    @discardableResult
    public func sync(_ syncModes: [DocumentKey: SyncMode] = [:]) async throws -> [Document] {
        let attachments = self.attachmentMap.values

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                attachments.forEach { attachment in
                    group.addTask {
                        try await self.syncInternal(attachment, syncModes[attachment.doc.getKey()] ?? .pushPull)
                    }
                }

                try await group.waitForAll()
            }

            return attachments.compactMap { $0.doc }
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

        for (docKey, attachment) in self.attachmentMap {
            if attachment.isRealtimeSync == false {
                continue
            }

            self.attachmentMap[docKey]?.peerPresenceMap[id] = self.presenceInfo

            var updatePresenceRequest = UpdatePresenceRequest()
            updatePresenceRequest.client = Converter.toClient(id: id, presence: self.presenceInfo)
            updatePresenceRequest.documentID = attachment.docID

            self.sendPeerChangeEvent(.presenceChanged, [docKey], id)

            do {
                _ = try await self.rpcClient.updatePresence(updatePresenceRequest)
                Logger.info("[UM] c\"\(self.key)\" updated")
            } catch {
                Logger.error("[UM] c\"\(self.key)\" err : \(error)")
            }
        }
    }

    /**
     * `getPeers` returns the peers of the given document.
     */
    public func getPeers(key: String) -> PresenceMap {
        var peers = PresenceMap()
        self.attachmentMap[key]?.peerPresenceMap.forEach {
            peers[$0.key] = $0.value.data
        }
        return peers
    }

    /**
     * `getPeersWithDocKey` returns the peers of the given document wrapped in an object.
     */
    private func getPeersWithDocKey(peersMap: [DocumentKey: PresenceMap], docKey: DocumentKey, actorID: ActorID?) -> [DocumentKey: PresenceMap] {
        var newPeerMap = peersMap
        var peers = PresenceMap()

        if let actorID, let value = self.attachmentMap[docKey]?.peerPresenceMap[actorID] {
            peers[actorID] = value.data
        } else {
            self.attachmentMap[docKey]?.peerPresenceMap.forEach {
                peers[$0.key] = $0.value.data
            }
        }
        newPeerMap[docKey] = peers
        return newPeerMap
    }

    private func clearAttachmentRemoteChangeEventReceived(_ docKey: DocumentKey) {
        self.attachmentMap[docKey]?.remoteChangeEventReceived = false
    }

    private func setSyncTimer(_ reconnect: Bool) {
        let isDisconnectedWatchStream = self.attachmentMap.values.first(where: { $0.remoteWatchStream == nil }) != nil
        let syncLoopDuration = (reconnect || isDisconnectedWatchStream) ? self.reconnectStreamDelay : self.syncLoopDuration

        let timer = Timer(timeInterval: Double(syncLoopDuration) / 1000, repeats: false) { _ in
            Task {
                await self.doSyncLoop()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
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

                    if docChanged || (attachment.remoteChangeEventReceived && attachment.realtimeSyncMode != .pullOnly) {
                        self.clearAttachmentRemoteChangeEventReceived(key)
                        group.addTask {
                            try await self.syncInternal(attachment, attachment.realtimeSyncMode)
                        }
                    }
                }

                try await group.waitForAll()
            }

            self.setSyncTimer(false)
        } catch {
            Logger.error("[SL] c:\"\(self.key)\" sync failed: \(error)")

            let event = DocumentSyncedEvent(value: .syncFailed)
            self.eventStream.send(event)

            self.setSyncTimer(true)
        }
    }

    private func runSyncLoop() async {
        Logger.debug("[SL] c:\"\(self.key)\" run sync loop")
        await self.doSyncLoop()
    }

    private func doWatchLoop(_ docKey: DocumentKey) throws {
        self.attachmentMap[docKey]?.watchLoopReconnectTimer?.invalidate()
        self.attachmentMap[docKey]?.watchLoopReconnectTimer = nil

        guard self.isActive, let id = self.id else {
            Logger.debug("[WL] c:\"\(self.key)\" exit watch loop")
            return
        }

        guard self.attachmentMap[docKey]?.isRealtimeSync ?? false, let docID = self.attachmentMap[docKey]?.docID else {
            Logger.debug("[WL] c:\"\(self.key)\" exit watch loop")
            return
        }

        var request = WatchDocumentRequest()
        request.client = Converter.toClient(id: id, presence: self.presenceInfo)
        request.documentID = docID

        self.attachmentMap[docKey]?.remoteWatchStream = self.rpcClient.makeWatchDocumentCall(request)

        let event = StreamConnectionStatusChangedEvent(value: .connected)
        self.eventStream.send(event)

        Task {
            if let stream = self.attachmentMap[docKey]?.remoteWatchStream?.responseStream {
                do {
                    for try await response in stream {
                        self.handleWatchDocumentsResponse(docKey: docKey, response: response)
                    }
                } catch {
                    if let status = error as? GRPCStatus, status.code == .cancelled {
                        // Canceled by Client by detach. so there is No need to reconnect.
                    } else {
                        Logger.warning("[WL] c:\"\(self.key)\" has Error \(error)")

                        try self.onStreamDisconnect(docKey)
                    }
                }
            }
        }
    }

    private func runWatchLoop(_ docKey: DocumentKey) throws {
        Logger.debug("[WL] c:\"\(self.key)\" run watch loop")

        try self.doWatchLoop(docKey)
    }

    private func stopWatchLoop(_ docKey: DocumentKey) throws {
        try self.disconnectWatchStream(docKey)
    }

    private func waitForInitialization(_ semaphore: DispatchSemaphore, _ docKey: String) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global().async {
                if semaphore.wait(timeout: DispatchTime.now() + DispatchTimeInterval.milliseconds(self.maximumAttachmentTimeout)) == .timedOut {
                    let message = "[AD] Time out for Initialization. d:\"\(docKey)\""
                    Logger.warning(message)
                    continuation.resume(throwing: YorkieError.timeout(message: message))
                } else {
                    Logger.info("[AD] got Initialization. d:\"\(docKey)\"")
                    continuation.resume(returning: docKey)
                }
            }
        }
    }

    private func handleWatchDocumentsResponse(docKey: DocumentKey, response: WatchDocumentResponse) {
        Logger.debug("[WL] c:\"\(self.key)\" got response \(response)")

        guard let body = response.body else {
            return
        }

        switch body {
        case .initialization(let initialization):
            initialization.peers.forEach { pbClient in
                self.attachmentMap[docKey]?.peerPresenceMap[pbClient.id.toHexString] = Converter.fromPresence(pbPresence: pbClient.presence)

                self.semaphoresForInitialzation[docKey]?.signal()
            }

            self.sendPeerChangeEvent(.initialized, [docKey])
        case .event(let pbWatchEvent):
            let publisher = pbWatchEvent.publisher.id.toHexString
            let presence = Converter.fromPresence(pbPresence: pbWatchEvent.publisher.presence)

            switch pbWatchEvent.type {
            case .documentsWatched:
                self.attachmentMap[docKey]?.peerPresenceMap[publisher] = presence

                self.sendPeerChangeEvent(.watched, [docKey], publisher)
            case .documentsUnwatched:
                self.sendPeerChangeEvent(.unwatched, [docKey], publisher)

                self.attachmentMap[docKey]?.peerPresenceMap.removeValue(forKey: publisher)
            case .documentsChanged:
                self.attachmentMap[docKey]?.remoteChangeEventReceived = true

                let event = DocumentsChangedEvent(value: [docKey])
                self.eventStream.send(event)
            case .presenceChanged:
                if let peerPresence = self.attachmentMap[docKey]?.peerPresenceMap[publisher], peerPresence.clock > presence.clock {
                    break
                }

                self.attachmentMap[docKey]?.peerPresenceMap[publisher] = presence

                self.sendPeerChangeEvent(.presenceChanged, [docKey], publisher)
            case .UNRECOGNIZED:
                break
            }
        }
    }

    private func sendPeerChangeEvent(_ type: PeersChangedValue.`Type`, _ keys: [DocumentKey], _ actorID: ActorID? = nil) {
        let value = PeersChangedValue(type: type, peers: keys.reduce([DocumentKey: PresenceMap]()) {
            self.getPeersWithDocKey(peersMap: $0, docKey: $1, actorID: actorID)
        })
        let event = PeerChangedEvent(value: value)

        self.eventStream.send(event)
    }

    private func disconnectWatchStream(_ docKey: DocumentKey) throws {
        guard self.attachmentMap[docKey] != nil else {
            throw YorkieError.documentNotAttached(message: "\(docKey) is not attached.")
        }

        guard self.attachmentMap[docKey]?.remoteWatchStream != nil else {
            return
        }

        self.attachmentMap[docKey]?.remoteWatchStream?.cancel()
        self.attachmentMap[docKey]?.remoteWatchStream = nil

        self.attachmentMap[docKey]?.watchLoopReconnectTimer?.invalidate()
        self.attachmentMap[docKey]?.watchLoopReconnectTimer = nil

        Logger.debug("[WD] c:\"\(self.key)\" unwatches")

        let event = StreamConnectionStatusChangedEvent(value: .disconnected)
        self.eventStream.send(event)
    }

    private func onStreamDisconnect(_ docKey: DocumentKey) throws {
        try self.disconnectWatchStream(docKey)

        self.attachmentMap[docKey]?.watchLoopReconnectTimer = Timer(timeInterval: Double(self.reconnectStreamDelay) / 1000, repeats: false) { _ in
            Task {
                try await self.doWatchLoop(docKey)
            }
        }

        if let watchLoopReconnectTimer = self.attachmentMap[docKey]?.watchLoopReconnectTimer {
            RunLoop.main.add(watchLoopReconnectTimer, forMode: .common)
        }
    }

    @discardableResult
    private func syncInternal(_ attachment: Attachment, _ syncMode: SyncMode) async throws -> Document {
        guard let clientID = self.id, let clientIDData = clientID.toData else {
            throw YorkieError.unexpected(message: "Invalid Client ID!")
        }

        var pushPullRequest = PushPullChangeRequest()
        pushPullRequest.clientID = clientIDData

        let doc = attachment.doc
        let requestPack = await doc.createChangePack(syncMode)
        let localSize = requestPack.getChangeSize()

        pushPullRequest.changePack = Converter.toChangePack(pack: requestPack)
        pushPullRequest.documentID = attachment.docID
        pushPullRequest.pushOnly = syncMode == .pushOnly

        do {
            let response = try await self.rpcClient.pushPullChanges(pushPullRequest)

            let responsePack = try Converter.fromChangePack(response.changePack)
            try await doc.applyChangePack(pack: responsePack, syncMode: syncMode, clientID: clientID)

            if await doc.status == .removed {
                self.attachmentMap.removeValue(forKey: doc.getKey())
            }

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
