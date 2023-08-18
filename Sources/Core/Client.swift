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
import Semaphore

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

/**
 * `SyncMode` is the mode of synchronization. It is used to determine
 * whether to push and pull changes in PushPullChanges API.
 */
public enum SyncMode {
    /**
     * `PushPull` is the mode that pushes and pulls changes.
     */
    case pushPull

    /**
     * `PushOnly` is the mode that pushes changes only.
     */
    case pushOnly
}

struct Attachment {
    var doc: Document
    var docID: String
    var isRealtimeSync: Bool
    var realtimeSyncMode: SyncMode
    var remoteChangeEventReceived: Bool
    var remoteWatchStream: GRPCAsyncServerStreamingCall<WatchDocumentRequest, WatchDocumentResponse>?
    var watchLoopReconnectTimer: Timer?
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
    private var attachmentMap: [DocumentKey: Attachment]
    private let syncLoopDuration: Int
    private let reconnectStreamDelay: Int
    private let maximumAttachmentTimeout: Int

    private var rpcClient: YorkieServiceAsyncClient

    private let group: EventLoopGroup

    private var semaphoresForInitialzation = [DocumentKey: DispatchSemaphore]()
    private let syncSemaphore = AsyncSemaphore(value: 1)

    // Public variables.
    public private(set) var id: ActorID?
    public nonisolated let key: String
    public var isActive: Bool { self.status == .activated }
    public private(set) var status: ClientStatus
    public nonisolated let eventStream: PassthroughSubject<BaseClientEvent, Never>

    /**
     * @param rpcAddr - the address of the RPC server.
     * @param opts - the options of the client.
     */
    public init(rpcAddress: RPCAddress, options: ClientOptions) {
        self.key = options.key ?? UUID().uuidString

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

        let authInterceptors = AuthClientInterceptors(apiKey: options.apiKey, token: options.token)

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
            self.changeDocKeyOfAuthInterceptors(nil)
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
            self.changeDocKeyOfAuthInterceptors(nil)
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
    public func attach(_ doc: Document, _ initialPresence: PresenceData = [:], _ isRealtimeSync: Bool = true) async throws -> Document {
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
        try await doc.update { _, presence in
            presence.set(presence: initialPresence)
        }

        var attachDocumentRequest = AttachDocumentRequest()
        attachDocumentRequest.clientID = clientIDData
        attachDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack())

        do {
            let docKey = doc.getKey()
            let semaphore = DispatchSemaphore(value: 0)

            self.semaphoresForInitialzation[docKey] = semaphore

            self.changeDocKeyOfAuthInterceptors(docKey)
            let result = try await self.rpcClient.attachDocument(attachDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack)

            if await doc.status == .removed {
                throw YorkieError.documentRemoved(message: "\(doc) is removed.")
            }

            await doc.setStatus(.attached)

            self.attachmentMap[doc.getKey()] = Attachment(doc: doc, docID: result.documentID, isRealtimeSync: isRealtimeSync, realtimeSyncMode: .pushPull, remoteChangeEventReceived: false)
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
            throw YorkieError.documentNotAttached(message: "\(doc.getKey()) is not attached when \(#function).")
        }

        try await doc.update { _, presence in
            presence.clear()
        }

        var detachDocumentRequest = DetachDocumentRequest()
        detachDocumentRequest.clientID = clientIDData
        detachDocumentRequest.documentID = attachment.docID
        detachDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack())

        do {
            self.changeDocKeyOfAuthInterceptors(doc.getKey())
            let result = try await self.rpcClient.detachDocument(detachDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack)

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
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        try self.changeRealtimeSync(doc, false)
    }

    /**
     * `resume` resume the realtime syncronization of the given document.
     */
    public func resume(_ doc: Document) throws {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        try self.changeRealtimeSync(doc, true)
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
            throw YorkieError.documentNotAttached(message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var removeDocumentRequest = RemoveDocumentRequest()
        removeDocumentRequest.clientID = clientIDData
        removeDocumentRequest.documentID = attachment.docID
        removeDocumentRequest.changePack = Converter.toChangePack(pack: await doc.createChangePack(true))

        do {
            self.changeDocKeyOfAuthInterceptors(doc.getKey())
            let result = try await self.rpcClient.removeDocument(removeDocumentRequest)

            let pack = try Converter.fromChangePack(result.changePack)
            try await doc.applyChangePack(pack)

            try self.stopWatchLoop(doc.getKey())

            self.attachmentMap.removeValue(forKey: doc.getKey())

            Logger.info("[DD] c:\"\(self.key)\" removed d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request remove document(\(self.key)).", error: error)
            throw error
        }
    }

    /**
     * `changeRealtimeSync` changes the synchronization mode of the given document.
     */
    private func changeRealtimeSync(_ doc: Document, _ isRealtimeSync: Bool) throws {
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
     * `pauseRemoteChanges` pauses the synchronization of remote changes,
     * allowing only local changes to be applied.
     */
    public func pauseRemoteChanges(_ doc: Document) throws {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        let docKey = doc.getKey()

        guard self.attachmentMap[docKey] != nil else {
            throw YorkieError.documentNotAttached(message: "\(doc.getKey()) is not attached when \(#function).")
        }

        self.attachmentMap[docKey]?.realtimeSyncMode = .pushOnly
    }

    /**
     * `resumeRemoteChanges` resumes the synchronization of remote changes,
     * allowing both local and remote changes to be applied.
     */
    public func resumeRemoteChanges(_ doc: Document) throws {
        guard self.isActive else {
            throw YorkieError.clientNotActive(message: "\(self.key) is not active")
        }

        let docKey = doc.getKey()

        guard self.attachmentMap[docKey] != nil else {
            throw YorkieError.documentNotAttached(message: "\(doc.getKey()) is not attached when \(#function).")
        }

        self.attachmentMap[docKey]?.realtimeSyncMode = .pushPull
        self.attachmentMap[docKey]?.remoteChangeEventReceived = true
    }

    /**
     * `sync` pushes local changes of the attached documents to the server and
     * receives changes of the remote replica from the server then apply them to
     * local documents.
     */
    @discardableResult
    public func sync(_ doc: Document? = nil, _ syncMode: SyncMode = .pushPull) async throws -> [Document] {
        var attachment: Attachment?

        if let doc {
            attachment = self.attachmentMap[doc.getKey()]
            guard attachment != nil else {
                throw YorkieError.documentNotAttached(message: "\(doc.getKey()) is not attached when \(#function).")
            }
        }

        do {
            return try await self.performSyncInternal(false, attachment, syncMode)
        } catch {
            let event = DocumentSyncedEvent(value: .syncFailed)
            self.eventStream.send(event)

            throw error
        }
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

    @discardableResult
    private func performSyncInternal(_ isRealtimeSync: Bool, _ attachment: Attachment? = nil, _ syncMode: SyncMode = .pushPull) async throws -> [Document] {
        await self.syncSemaphore.wait()

        defer {
            self.syncSemaphore.signal()
        }

        var result = [Document]()

        do {
            if isRealtimeSync {
                for (key, attachment) in self.attachmentMap.filter({ $0.value.isRealtimeSync }) {
                    let docChanged = await attachment.doc.hasLocalChanges()

                    if docChanged || attachment.remoteChangeEventReceived {
                        self.clearAttachmentRemoteChangeEventReceived(key)
                        result.append(attachment.doc)
                        try await self.syncInternal(attachment, attachment.realtimeSyncMode)
                    }
                }
            } else {
                if let attachment {
                    result.append(attachment.doc)
                    try await self.syncInternal(attachment, syncMode)
                } else {
                    for (_, attachment) in self.attachmentMap {
                        result.append(attachment.doc)
                        try await self.syncInternal(attachment, attachment.realtimeSyncMode)
                    }
                }
            }
        } catch {
            throw error
        }

        return result
    }

    private func doSyncLoop() async {
        guard self.isActive else {
            Logger.debug("[SL] c:\"\(self.key)\" exit sync loop")
            return
        }

        do {
            try await self.performSyncInternal(true)

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

        guard let idData = id.toData else {
            throw YorkieError.unexpected(message: "Can't convert id to Data \(id)")
        }

        var request = WatchDocumentRequest()

        request.clientID = idData
        request.documentID = docID

        self.changeDocKeyOfAuthInterceptors(docKey)
        self.attachmentMap[docKey]?.remoteWatchStream = self.rpcClient.makeWatchDocumentCall(request)

        let event = StreamConnectionStatusChangedEvent(value: .connected)
        self.eventStream.send(event)

        Task {
            if let stream = self.attachmentMap[docKey]?.remoteWatchStream?.responseStream {
                do {
                    for try await response in stream {
                        await self.handleWatchDocumentsResponse(docKey: docKey, response: response)
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

    private func handleWatchDocumentsResponse(docKey: DocumentKey, response: WatchDocumentResponse) async {
        Logger.debug("[WL] c:\"\(self.key)\" got response \(response)")

        guard let body = response.body else {
            return
        }

        switch body {
        case .initialization(let initialization):
            var onlineClients = Set<ActorID>()
            initialization.clientIds.forEach { pbClientID in
                onlineClients.insert(pbClientID.toHexString)
            }

            self.semaphoresForInitialzation[docKey]?.signal()

            await self.attachmentMap[docKey]?.doc.setOnlineClients(onlineClients)
            await self.attachmentMap[docKey]?.doc.publish(.initialized, nil)
        case .event(let pbWatchEvent):
            let publisher = pbWatchEvent.publisher.toHexString

            switch pbWatchEvent.type {
            case .documentsChanged:
                self.attachmentMap[docKey]?.remoteChangeEventReceived = true

                let event = DocumentsChangedEvent(value: [docKey])
                self.eventStream.send(event)
            case .documentsWatched:
                await self.attachmentMap[docKey]?.doc.addOnlineClient(publisher)
                await self.attachmentMap[docKey]?.doc.publish(.watched, publisher)
            case .documentsUnwatched:
                await self.attachmentMap[docKey]?.doc.removeOnlineClient(publisher)
                await self.attachmentMap[docKey]?.doc.publish(.unwatched, publisher)
            case .UNRECOGNIZED:
                break
            }
        }
    }

    private func disconnectWatchStream(_ docKey: DocumentKey) throws {
        guard self.attachmentMap[docKey] != nil else {
            return
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
        let requestPack = await doc.createChangePack()
        let localSize = requestPack.getChangeSize()

        pushPullRequest.changePack = Converter.toChangePack(pack: requestPack)
        pushPullRequest.documentID = attachment.docID
        pushPullRequest.pushOnly = syncMode == .pushOnly

        do {
            let docKey = doc.getKey()

            self.changeDocKeyOfAuthInterceptors(docKey)
            let response = try await self.rpcClient.pushPullChanges(pushPullRequest)

            let responsePack = try Converter.fromChangePack(response.changePack)

            // NOTE(chacha912, hackerwins): If syncLoop already executed with
            // PushPull, ignore the response when the syncMode is PushOnly.
            if responsePack.hasChanges(), syncMode == .pushOnly {
                return doc
            }

            try await doc.applyChangePack(responsePack)

            if await doc.status == .removed {
                self.attachmentMap.removeValue(forKey: docKey)
            }

            let event = DocumentSyncedEvent(value: .synced)
            self.eventStream.send(event)

            let remoteSize = responsePack.getChangeSize()
            Logger.info("[PP] c:\"\(self.key)\" sync d:\"\(docKey)\", push:\(localSize) pull:\(remoteSize) cp:\(responsePack.getCheckpoint().toTestString)")

            return doc
        } catch {
            Logger.error("[PP] c:\"\(self.key)\" err : \(error)")

            throw error
        }
    }

    private func changeDocKeyOfAuthInterceptors(_ docKey: String?) {
        self.rpcClient.interceptors = (self.rpcClient.interceptors as? AuthClientInterceptors)?.docKeyChangedInterceptors(docKey)
    }
}
