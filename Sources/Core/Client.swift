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
import Connect
import Foundation
import Logging
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
 * `SyncMode` defines synchronization modes for the PushPullChanges API.
 */
public enum SyncMode {
    /**
     * `manual` mode indicates that changes are not automatically pushed or pulled.
     */
    case manual

    /**
     * `realtime` mode indicates that changes are automatically pushed and pulled.
     */
    case realtime

    /**
     * `realtimePushonly` mode indicates that only local changes are automatically pushed.
     */
    case realtimePushOnly

    /**
     * `realtimeSyncoff` mode indicates that changes are not automatically pushed or pulled,
     * but the watch stream is kept active.
     */
    case realtimeSyncOff
}

/**
 * `ClientCondition` represents the condition of the client.
 */
public enum ClientCondition: String {
    /**
     * `SyncLoop` is a key of the sync loop condition.
     */
    case syncLoop = "SyncLoop"

    /**
     * `WatchLoop` is a key of the watch loop condition.
     */
    case watchLoop = "WatchLoop"
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

/**
 * `DefaultBroadcastOptions` is the default options for broadcast.
 */
enum DefaultBroadcastOptions {
    static let maxRetries: Int = .max
    static let initialRetryInterval: Double = 1000 // milliseconds
    static let maxBackoff: Double = 20000 // milliseconds
}

/**
 * `Client` is a normal client that can communicate with the server.
 * It has documents and sends changes of the documents in local
 * to the server to synchronize with other replicas in remote.
 */
@MainActor
public class Client {
    private var attachmentMap = [DocumentKey: Attachment]()
    private var conditions: [ClientCondition: Bool] = [
        ClientCondition.syncLoop: false,
        ClientCondition.watchLoop: false
    ]

    private let syncLoopDuration: Int
    private let reconnectStreamDelay: Int
    private let maximumAttachmentTimeout: Int

    private var yorkieService: YorkieService
    private var authHeader: AuthHeader
    private var semaphoresForInitialzation = [DocumentKey: DispatchSemaphore]()
    private let syncSemaphore = AsyncSemaphore(value: 1)

    // Public variables.
    public private(set) var id: ActorID?
    public nonisolated let key: String
    public var isActive: Bool { self.status == .activated }
    public private(set) var status: ClientStatus = .deactivated

    /**
     * @param rpcAddr - the address of the RPC server.
     * @param opts - the options of the client.
     */
    public nonisolated init(_ urlString: String, _ options: ClientOptions = ClientOptions(), isMockingEnabled: Bool = false) {
        self.key = options.key ?? UUID().uuidString
        self.syncLoopDuration = options.syncLoopDuration
        self.reconnectStreamDelay = options.reconnectStreamDelay
        self.maximumAttachmentTimeout = options.maximumAttachmentTimeout

        let protocolClient = ProtocolClient(httpClient: URLSessionHTTPClient(),
                                            config: ProtocolClientConfig(host: urlString,
                                                                         networkProtocol: .connect,
                                                                         codec: ProtoCodec()))

        self.yorkieService = YorkieService(rpcClient: YorkieServiceClient(client: protocolClient), isMockingEnabled: isMockingEnabled)
        self.authHeader = AuthHeader(apiKey: options.apiKey, token: options.token)
    }

    /**
     * @param url - the url of the RPC server.
     * @param opts - the options of the client.
     */
    convenience init?(_ url: URL, _ options: ClientOptions = ClientOptions()) {
        self.init(url.absoluteString, options)
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

        do {
            let activateRequest = ActivateClientRequest.with { $0.clientKey = self.key }
            let activateResponse = await self.yorkieService.activateClient(request: activateRequest, headers: self.authHeader.makeHeader(nil))

            guard activateResponse.error == nil, let message = activateResponse.message else {
                throw self.handleErrorResponse(activateResponse.error, defaultMessage: "Unknown activate error")
            }

            self.id = message.clientID

            self.status = .activated
            await self.runSyncLoop()

            Logger.debug("Client(\(self.key)) activated")
        } catch {
            Logger.error("Failed to request activate client(\(self.key)).")
            self.handleConnectError(error)
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

        do {
            let deactivateRequest = DeactivateClientRequest.with { $0.clientID = clientID }

            let deactivateResponse = await self.yorkieService.deactivateClient(request: deactivateRequest)

            guard deactivateResponse.error == nil else {
                throw self.handleErrorResponse(deactivateResponse.error, defaultMessage: "Unknown deactivate error")
            }

            try self.deactivateInternal()

            Logger.info("Client(\(self.key) deactivated.")
        } catch {
            Logger.error("Failed to request deactivate client(\(self.key)).")
            self.handleConnectError(error)
            throw error
        }
    }

    /**
     *   `attach` attaches the given document to this client. It tells the server that
     *   the client will synchronize the given document.
     */
    @discardableResult
    public func attach(_ doc: Document, _ initialPresence: PresenceData = [:], _ syncMode: SyncMode = .realtime) async throws -> Document {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard doc.status == .detached else {
            throw YorkieError(code: .errDocumentNotDetached, message: "\(self.key) is not detached.")
        }

        doc.setActor(clientID)
        try doc.update { _, presence in
            presence.set(initialPresence)
        }

        doc.subscribeLocalBroadcast { [weak self] event, doc in
            guard let self else { return }
            guard let broadcastEvent = event as? LocalBroadcastEvent else {
                return
            }
            let topic = broadcastEvent.value.topic
            let payload = broadcastEvent.value.payload
            let errorFn = broadcastEvent.options?.error

            Task {
                do {
                    try await self.broadcast(doc.getKey(), topic: topic, payload: payload, options: broadcastEvent.options)
                } catch {
                    errorFn?(error)
                }
            }
        }

        var attachRequest = AttachDocumentRequest()
        attachRequest.clientID = clientID
        attachRequest.changePack = Converter.toChangePack(pack: doc.createChangePack())

        do {
            let docKey = doc.getKey()
            let semaphore = DispatchSemaphore(value: 0)

            self.semaphoresForInitialzation[docKey] = semaphore

            let attachResponse = await self.yorkieService.attachDocument(request: attachRequest, headers: self.authHeader.makeHeader(docKey))

            guard attachResponse.error == nil, let message = attachResponse.message else {
                throw self.handleErrorResponse(attachResponse.error, defaultMessage: "Unknown attach error")
            }

            let pack = try Converter.fromChangePack(message.changePack)
            try doc.applyChangePack(pack)

            if doc.status == .removed {
                throw YorkieError(code: .errDocumentRemoved, message: "\(doc) is removed.")
            }

            doc.applyStatus(.attached)

            self.attachmentMap[doc.getKey()] = Attachment(doc: doc,
                                                          docID: message.documentID,
                                                          syncMode: syncMode,
                                                          remoteChangeEventReceived: false)

            if syncMode != .manual {
                try self.runWatchLoop(docKey)
                try await self.waitForInitialization(semaphore, docKey)
            }

            Logger.info("[AD] c:\"\(self.key))\" attaches d:\"\(doc.getKey())\"")

            self.semaphoresForInitialzation.removeValue(forKey: docKey)

            return doc
        } catch {
            Logger.error("Failed to request attach document(\(self.key)).", error: error)
            self.handleConnectError(error)
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
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = attachmentMap[doc.getKey()] else {
            throw YorkieError(code: .errDocumentNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        try doc.update { _, presence in
            presence.clear()
        }

        var detachDocumentRequest = DetachDocumentRequest()
        detachDocumentRequest.clientID = clientID
        detachDocumentRequest.documentID = attachment.docID
        detachDocumentRequest.changePack = Converter.toChangePack(pack: doc.createChangePack())

        do {
            let detachDocumentResponse = await self.yorkieService.detachDocument(request: detachDocumentRequest, headers: self.authHeader.makeHeader(doc.getKey()))

            guard detachDocumentResponse.error == nil, let message = detachDocumentResponse.message else {
                throw self.handleErrorResponse(detachDocumentResponse.error, defaultMessage: "Unknown detach error")
            }

            let pack = try Converter.fromChangePack(message.changePack)

            try doc.applyChangePack(pack)

            if doc.status != .removed {
                doc.applyStatus(.detached)
            }

            try self.detachInternal(doc.getKey())

            Logger.info("[DD] c:\"\(self.key)\" detaches d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request detach document(\(self.key)).", error: error)
            self.handleConnectError(error)
            throw error
        }
    }

    /**
     * `remove` mrevoes the given document.
     */
    @discardableResult
    public func remove(_ doc: Document) async throws -> Document {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = attachmentMap[doc.getKey()] else {
            throw YorkieError(code: .errDocumentNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var removeDocumentRequest = RemoveDocumentRequest()
        removeDocumentRequest.clientID = clientID
        removeDocumentRequest.documentID = attachment.docID
        removeDocumentRequest.changePack = Converter.toChangePack(pack: doc.createChangePack(true))

        do {
            let removeDocumentResponse = await self.yorkieService.removeDocument(request: removeDocumentRequest, headers: self.authHeader.makeHeader(doc.getKey()))

            guard removeDocumentResponse.error == nil, let message = removeDocumentResponse.message else {
                throw self.handleErrorResponse(removeDocumentResponse.error, defaultMessage: "Unknown remove error")
            }

            let pack = try Converter.fromChangePack(message.changePack)
            try doc.applyChangePack(pack)

            try self.detachInternal(doc.getKey())

            self.attachmentMap.removeValue(forKey: doc.getKey())

            Logger.info("[DD] c:\"\(self.key)\" removed d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request remove document(\(self.key)).", error: error)
            self.handleConnectError(error)
            throw error
        }
    }

    /**
     * `getCondition` returns the condition of this client.
     */
    public func getCondition(_ condition: ClientCondition) -> Bool {
        return self.conditions[condition] ?? false
    }

    /**
     * `setCondition` set the condition of this client.
     */
    public func setCondition(_ condition: ClientCondition, value: Bool) {
        self.conditions[condition] = value
    }

    /**
     * `broadcast` broadcasts the given payload to the given topic.
     */
    public func broadcast(_ docKey: DocumentKey, topic: String, payload: Payload, options: BroadcastOptions?) async throws {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let attachment = self.attachmentMap[docKey] else {
            throw YorkieError(code: .errDocumentNotAttached, message: "\(docKey) is not attached when \(#function).")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID: \(String(describing: self.id))")
        }

        guard let payloadData = try? payload.toJSONData() else {
            throw YorkieError(code: .errInvalidArgument, message: "payload is not serializable")
        }

        let maxRetries = options?.maxRetries ?? DefaultBroadcastOptions.maxRetries

        var request = BroadcastRequest()
        request.clientID = clientID
        request.documentID = attachment.docID
        request.topic = topic
        request.payload = payloadData

        try await self.broadcast(request: request, maxRetries: maxRetries)
    }

    /**
     * `changeSyncMode` changes the synchronization mode of the given document.
     */
    @discardableResult
    public func changeSyncMode(_ doc: Document, _ syncMode: SyncMode) throws -> Document {
        let docKey = doc.getKey()

        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(docKey) is not active")
        }

        guard let attachment = self.attachmentMap[docKey] else {
            throw YorkieError(code: .errDocumentNotAttached, message: "Can't find attachment by docKey! [\(docKey)]")
        }

        let prevSyncMode = attachment.syncMode
        if prevSyncMode == syncMode {
            return doc
        }

        self.attachmentMap[docKey]?.syncMode = syncMode

        // realtime to manual
        if syncMode == .manual {
            try self.stopWatchLoop(docKey, with: attachment)
            return doc
        }

        if syncMode == .realtime {
            // NOTE(hackerwins): In non-pushpull mode, the client does not receive change events
            // from the server. Therefore, we need to set `remoteChangeEventReceived` to true
            // to sync the local and remote changes. This has limitations in that unnecessary
            // syncs occur if the client and server do not have any changes.
            self.attachmentMap[docKey]?.remoteChangeEventReceived = true
        }

        // manual to realtime
        if prevSyncMode == .manual {
            try self.runWatchLoop(docKey)
        }

        return doc
    }

    /**
     * `sync` pushes local changes of the attached documents to the server and
     * receives changes of the remote replica from the server then apply them to
     * local documents.
     */
    @discardableResult
    public func sync(_ doc: Document? = nil) async throws -> [Document] {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        var attachment: Attachment?

        if let doc {
            attachment = self.attachmentMap[doc.getKey()]
            guard attachment != nil else {
                throw YorkieError(code: .errDocumentNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
            }
        }

        do {
            return try await self.performSyncInternal(false, attachment)
        } catch {
            self.handleConnectError(error)
            throw error
        }
    }

    private func clearAttachmentRemoteChangeEventReceived(_ docKey: DocumentKey) {
        self.attachmentMap[docKey]?.remoteChangeEventReceived = false
    }

    private func setSyncTimer(_ reconnect: Bool) {
        let isDisconnectedWatchStream = self.attachmentMap.values.first(where: { $0.isDisconnectedStream }) != nil
        let syncLoopDuration = (reconnect || isDisconnectedWatchStream) ? self.reconnectStreamDelay : self.syncLoopDuration

        let timer = Timer(timeInterval: Double(syncLoopDuration) / 1000, repeats: false) { _ in
            Task {
                await self.doSyncLoop()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    private func performSyncInternal(_ isRealtimeSync: Bool, _ attachment: Attachment? = nil) async throws -> [Document] {
        await self.syncSemaphore.wait()

        defer {
            self.syncSemaphore.signal()
        }

        var result = [Document]()

        do {
            if isRealtimeSync {
                for (key, attachment) in self.attachmentMap where await attachment.needRealtimeSync() {
                    self.clearAttachmentRemoteChangeEventReceived(key)
                    result.append(attachment.doc)
                    try await self.syncInternal(attachment, attachment.syncMode)
                }
            } else {
                if let attachment {
                    result.append(attachment.doc)
                    try await self.syncInternal(attachment, .realtime)
                } else {
                    for (_, attachment) in self.attachmentMap {
                        result.append(attachment.doc)
                        try await self.syncInternal(attachment, attachment.syncMode)
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
            self.setCondition(.syncLoop, value: false)
            return
        }

        do {
            try await self.performSyncInternal(true)

            self.setSyncTimer(false)
        } catch {
            if self.handleConnectError(error) {
                self.setSyncTimer(true)
            } else {
                self.setCondition(.syncLoop, value: false)
            }
        }
    }

    /**
     * `runSyncLoop` runs the sync loop. The sync loop pushes local changes to
     * the server and pulls remote changes from the server.
     */
    private func runSyncLoop() async {
        Logger.debug("[SL] c:\"\(self.key)\" run sync loop")
        self.setCondition(.syncLoop, value: true)
        await self.doSyncLoop()
    }

    private func doWatchLoop(_ docKey: DocumentKey, with attachment: Attachment) throws {
        attachment.resetWatchLoopTimer()

        guard self.isActive, let id = self.id else {
            Logger.debug("[WL] c:\"\(self.key)\" exit watch loop")
            self.setCondition(.watchLoop, value: false)
            throw YorkieError(code: .errClientNotActivated, message: "$\(docKey) is not active")
        }

        let stream = self.yorkieService.watchDocument(headers: self.authHeader.makeHeader(docKey), onResult: { result in
            Task {
                switch result {
                case .headers:
                    break
                case .message(let message):
                    await self.handleWatchDocumentsResponse(docKey: docKey, response: message)
                case .complete(_, let error, _):
                    if error != nil {
                        await attachment.doc.resetOnlineClients()
                        await attachment.doc.publishInitializedEvent()
                        await attachment.doc.publishConnectionEvent(.disconnected)
                    }

                    Logger.debug("[WD] c:\"\(self.key)\" unwatches")

                    if await self.handleConnectError(error) {
                        Logger.warning("[WL] c:\"\(self.key)\" has Error \(String(describing: error))")
                        try await self.onStreamDisconnect(docKey, with: attachment)
                    } else {
                        await self.setCondition(.watchLoop, value: false)
                        try await self.onStreamDisconnect(docKey, with: attachment)
                    }
                }
            }
        })

        let request = WatchDocumentRequest.with {
            $0.clientID = id
            $0.documentID = attachment.docID
        }

        stream.send(request)

        attachment.connectStream(stream)

        attachment.doc.publishConnectionEvent(.connected)
    }

    /**
     * `runWatchLoop` runs the watch loop for the given document. The watch loop
     * listens to the events of the given document from the server.
     */
    private func runWatchLoop(_ docKey: DocumentKey) throws {
        Logger.debug("[WL] c:\"\(self.key)\" run watch loop")
        guard let attachment = self.attachmentMap[docKey] else {
            throw YorkieError(code: .errDocumentNotAttached, message: "\(docKey) is not attached")
        }

        self.setCondition(.watchLoop, value: true)
        try self.doWatchLoop(docKey, with: attachment)
    }

    private func stopWatchLoop(_ docKey: DocumentKey, with attachment: Attachment) throws {
        try self.disconnectWatchStream(docKey, with: attachment)
    }

    private func waitForInitialization(_ semaphore: DispatchSemaphore, _ docKey: String) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global().async {
                if semaphore.wait(timeout: DispatchTime.now() + DispatchTimeInterval.milliseconds(self.maximumAttachmentTimeout)) == .timedOut {
                    let message = "[AD] Time out for Initialization. d:\"\(docKey)\""
                    Logger.warning(message)
                    continuation.resume(throwing: YorkieError(code: .errUnexpected, message: message))
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
            let actorID = self.attachmentMap[docKey]?.doc.actorID

            for pbClientID in initialization.clientIds.filter({ $0 != actorID }) {
                onlineClients.insert(pbClientID)
            }

            self.semaphoresForInitialzation[docKey]?.signal()

            self.attachmentMap[docKey]?.doc.setOnlineClients(onlineClients)
            self.attachmentMap[docKey]?.doc.publishPresenceEvent(.initialized)
        case .event(let pbWatchEvent):
            let publisher = pbWatchEvent.publisher

            switch pbWatchEvent.type {
            case .documentChanged:
                self.attachmentMap[docKey]?.remoteChangeEventReceived = true
            case .documentWatched:
                self.attachmentMap[docKey]?.doc.addOnlineClient(publisher)
                // NOTE(chacha912): We added to onlineClients, but we won't trigger watched event
                // unless we also know their initial presence data at this point.
                if let presence = self.attachmentMap[docKey]?.doc.getPresence(publisher) {
                    self.attachmentMap[docKey]?.doc.publishPresenceEvent(.watched, publisher, presence)
                }
            case .documentUnwatched:
                // NOTE(chacha912): There is no presence, when PresenceChange(clear) is applied before unwatching.
                // In that case, the 'unwatched' event is triggered while handling the PresenceChange.
                let presence = self.attachmentMap[docKey]?.doc.getPresence(publisher)

                self.attachmentMap[docKey]?.doc.removeOnlineClient(publisher)

                if let presence {
                    self.attachmentMap[docKey]?.doc.publishPresenceEvent(.unwatched, publisher, presence)
                }
            case .documentBroadcast:
                let topic = pbWatchEvent.body.topic
                let payloadData = pbWatchEvent.body.payload
                let payload = Payload(jsonData: payloadData)
                self.attachmentMap[docKey]?.doc.publishBroadcastEvent(clientID: publisher, topic: topic, payload: payload)
            default:
                break
            }
        }
    }

    private func disconnectWatchStream(_ docKey: DocumentKey, with attachment: Attachment) throws {
        guard !attachment.isDisconnectedStream else {
            return
        }
        attachment.disconnectStream()
        attachment.resetWatchLoopTimer()

        Logger.debug("[WL] c:\"\(self.key)\" disconnected watch stream")
    }

    private func onStreamDisconnect(_ docKey: DocumentKey, with attachment: Attachment) throws {
        try self.disconnectWatchStream(docKey, with: attachment)

        // check if watch loop is stopped
        guard self.attachmentMap[docKey] != nil, attachment.syncMode != .manual else {
            return
        }

        attachment.watchLoopReconnectTimer = Timer(timeInterval: Double(self.reconnectStreamDelay) / 1000, repeats: false) { _ in
            Task {
                Logger.debug("[WL] c:\"\(self.key)\" reconnect timer fired. do watch loop")
                try await self.doWatchLoop(docKey, with: attachment)
            }
        }

        if let watchLoopReconnectTimer = attachment.watchLoopReconnectTimer {
            RunLoop.main.add(watchLoopReconnectTimer, forMode: .common)
        }
    }

    private func deactivateInternal() throws {
        self.status = .deactivated

        for (key, attachment) in self.attachmentMap {
            try self.detachInternal(key)
            attachment.doc.applyStatus(.detached)
        }
    }

    private func detachInternal(_ docKey: DocumentKey) throws {
        guard let attachment = self.attachmentMap[docKey] else {
            return
        }

        attachment.unsubscribeBroadcastEvent()

        try self.stopWatchLoop(docKey, with: attachment)

        self.attachmentMap.removeValue(forKey: docKey)
    }

    @discardableResult
    private func syncInternal(_ attachment: Attachment, _ syncMode: SyncMode) async throws -> Document {
        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid Client ID!")
        }

        var pushPullRequest = PushPullChangeRequest()
        pushPullRequest.clientID = clientID

        let doc = attachment.doc
        let requestPack = doc.createChangePack()
        let localSize = requestPack.getChangeSize()

        pushPullRequest.changePack = Converter.toChangePack(pack: requestPack)
        pushPullRequest.documentID = attachment.docID
        pushPullRequest.pushOnly = syncMode == .realtimePushOnly

        do {
            let docKey = doc.getKey()

            let pushpullResponse = await self.yorkieService.pushPullChanges(request: pushPullRequest, headers: self.authHeader.makeHeader(docKey))

            guard pushpullResponse.error == nil, let message = pushpullResponse.message else {
                throw self.handleErrorResponse(pushpullResponse.error, defaultMessage: "Unknown pushpull error")
            }

            let responsePack = try Converter.fromChangePack(message.changePack)

            // NOTE(chacha912, hackerwins): If syncLoop already executed with
            // PushPull, ignore the response when the syncMode is PushOnly.
            if responsePack.hasChanges() && (attachment.syncMode == .realtimePushOnly || attachment.syncMode == .realtimeSyncOff) {
                return doc
            }

            try doc.applyChangePack(responsePack)

            if doc.status == .removed {
                self.attachmentMap.removeValue(forKey: docKey)
            }

            doc.publishSyncEvent(.synced)

            let remoteSize = responsePack.getChangeSize()
            Logger.info("[PP] c:\"\(self.key)\" sync d:\"\(docKey)\", push:\(localSize) pull:\(remoteSize) cp:\(responsePack.getCheckpoint().toTestString)")

            return doc
        } catch {
            doc.publishSyncEvent(.syncFailed)

            Logger.error("[PP] c:\"\(self.key)\" err : \(error)")

            throw error
        }
    }

    /**
     * `handleConnectError` handles the given error. If the given error can be
     * retried after handling, it returns true.
     */
    @discardableResult
    private func handleConnectError(_ error: Error?) -> Bool {
        guard let connectError = error as? ConnectError else {
            return false
        }

        // NOTE(hackerwins): These errors are retryable.
        // Connect guide indicates that for error codes like `ResourceExhausted` and
        // `Unavailable`, retries should be attempted following their guidelines.
        // Additionally, `Unknown` and `Canceled` are added separately as it
        // typically occurs when the server is stopped.
        if connectError.code == .canceled ||
            connectError.code == .unknown ||
            connectError.code == .resourceExhausted ||
            connectError.code == .unavailable
        {
            return true
        }

        // NOTE(hackerwins): Some errors should fix the state of the client.
        let yorkieErrorCode = YorkieError.Code(rawValue: errorCodeOf(error: connectError))
        if yorkieErrorCode == YorkieError.Code.errClientNotActivated ||
            yorkieErrorCode == YorkieError.Code.errClientNotFound
        {
            do {
                try self.deactivateInternal()
            } catch {
                Logger.error("Failed deactivateInternal for client (\(self.key)) with error: \(error)")
            }
        }

        return false
    }

    private func handleErrorResponse(_ error: Error?, defaultMessage: String) -> Error {
        if let error = error {
            return error
        } else {
            return YorkieError(code: .errRPC, message: defaultMessage)
        }
    }
}

public extension Client {
    /**
     * `setMockError` sets a mock error for a specific method.
     */
    func setMockError(for method: Connect.MethodSpec, error: ConnectError, count: Int = 1) {
        self.yorkieService.setMockError(for: method, error: error, count: count)
    }

    /**
     * Calculates an exponential backoff interval based on the retry count
     */
    func exponentialBackoff(retryCount: Int) -> Double {
        return min(DefaultBroadcastOptions.initialRetryInterval * pow(2, Double(retryCount)), DefaultBroadcastOptions.maxBackoff)
    }

    private func broadcast(request: BroadcastRequest, maxRetries: Int) async throws {
        var retryCount = 0

        while retryCount <= maxRetries {
            let message = await self.yorkieService.broadcast(request: request)

            switch message.result {
            case .success:
                Logger.info("[BC] c:\(self.key) broadcasted to d: \(request.documentID) t: \(request.topic)")
                return
            case .failure(let error):
                Logger.error("[BC] c:\(self.key)", error: error)

                if !self.handleConnectError(error) || retryCount >= maxRetries {
                    throw error
                }

                let retryInterval = self.exponentialBackoff(retryCount: retryCount)
                try await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000))
                retryCount += 1
            }
        }
    }
}
