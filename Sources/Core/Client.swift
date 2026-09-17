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

    /// `polling` mode runs the sync loop without opening a watch stream.
    /// `PushPullChanges` runs at the polling interval; remote changes arrive on the next tick
    /// (latency = interval). Not suitable for collaborative editing — use `realtime` for that.
    case polling
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
        static let retrySyncLoopDelay = 1000 // 1000 millisecond
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
     * `authTokenInjector` is a function that provides a token for the auth webhook.
     * When the webhook response status code is 401, this function is called to refresh the token.
     * The `reason` parameter is the reason from the webhook response.
     */
    var authTokenInjector: AuthTokenInjector?

    /**
     * `syncLoopDuration` is the duration of the sync loop. After each sync loop,
     * the client waits for the duration to next sync. The default value is
     * `50`(ms).
     */
    var syncLoopDuration: Int

    /**
     * `retrySyncLoopDelay` is the delay of the retry sync loop. If the sync loop
     * fails, the client waits for the delay to retry the sync loop. The default
     * value is `1000`(ms).
     */
    var retrySyncLoopDelay: Int

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

    private(set) var metadata: [String: String]

    /// The store that persists attached documents between sessions.
    ///
    /// When set, the client writes ``Document/toBytes()`` after every local change and
    /// restores from the store on the next attach, so changes made offline are re-pushed.
    /// Leaving it `nil` keeps the previous behaviour: nothing is persisted.
    public var store: DocStore?

    /// The guard that keeps two sessions from resuming the same persisted document.
    ///
    /// Consulted only when ``store`` is set. Defaults to ``NoopSessionLock``, which grants
    /// every lease — correct for a single process. Supply your own when a persistent store
    /// is shared across processes, such as an app and its extensions.
    public var sessionLock: SessionLock

    public init(key: String? = nil,
                apiKey: String? = nil,
                authTokenInjector: AuthTokenInjector? = nil,
                syncLoopDuration: Int? = nil,
                retrySyncLoopDelay: Int? = nil,
                reconnectStreamDelay: Int? = nil,
                attachTimeout: Int? = nil,
                store: DocStore? = nil,
                sessionLock: SessionLock? = nil)
    {
        self.key = key
        self.apiKey = apiKey
        self.authTokenInjector = authTokenInjector
        self.syncLoopDuration = syncLoopDuration ?? DefaultClientOptions.syncLoopDuration
        self.retrySyncLoopDelay = retrySyncLoopDelay ?? DefaultClientOptions.retrySyncLoopDelay
        self.reconnectStreamDelay = reconnectStreamDelay ?? DefaultClientOptions.reconnectStreamDelay
        self.maximumAttachmentTimeout = attachTimeout ?? DefaultClientOptions.maximumAttachmentTimeout
        self.metadata = [:]
        self.store = store
        self.sessionLock = sessionLock ?? NoopSessionLock()
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
    private var attachmentMap = [String: Any]() // Stores Attachment<Document> and Attachment<Channel>
    /// The stable actor stamped into this client's document changes.
    ///
    /// Supplied by the server on activate and derived from the project and client key, so it
    /// survives across sessions where the session id does not. Falls back to the session id
    /// when the server does not send one, which is how an older server behaves.
    private var actorID: ActorID?
    /// The project API key, used to scope the session lease name.
    private let apiKey: String
    /// The store that persists attached documents, when offline persistence is enabled.
    private let store: DocStore?
    /// The guard that keeps two sessions from resuming the same persisted document.
    private let sessionLock: SessionLock
    /// The in-flight persist for each store key, so writes for one document stay ordered.
    private var persistTasks = [String: Task<Void, Never>]()

    /// Keys with an in-flight attach.
    ///
    /// `attachmentMap` is only populated once the attach round trip resolves, so this
    /// set is what rejects a concurrent duplicate attach of the same key.
    private var attachingDocs = Set<String>()
    private var conditions: [ClientCondition: Bool] = [
        ClientCondition.syncLoop: false,
        ClientCondition.watchLoop: false
    ]

    private let syncLoopDuration: Int
    private let reconnectStreamDelay: Int
    private let retrySyncLoopDelay: Int
    private let maximumAttachmentTimeout: Int
    private let channelHeartbeatInterval: TimeInterval = 5.0 // 5 seconds
    private let defaultPollingInterval: TimeInterval = 3.0 // 3 seconds

    private var yorkieService: YorkieService
    private var authTokenInjector: AuthTokenInjector?
    private var authHeader: AuthHeader
    private var semaphoresForInitialzation = [String: DispatchSemaphore]()
    private let syncSemaphore = AsyncSemaphore(value: 1)
    private var channelHeartbeatTimer: Timer?

    // Public variables.
    public private(set) var id: ActorID?
    public nonisolated let key: String
    public var isActive: Bool { self.status == .activated }
    public private(set) var status: ClientStatus = .deactivated

    private(set) var metadata: [String: String]

    // MARK: - Helper methods for typed attachments

    private func getDocumentAttachment(_ key: String) -> Attachment<Document>? {
        return self.attachmentMap[key] as? Attachment<Document>
    }

    private func getChannelAttachment(_ key: String) -> Attachment<Channel>? {
        return self.attachmentMap[key] as? Attachment<Channel>
    }

    /// Returns the stable actor this client stamps into document changes.
    ///
    /// Supplied by the server on activate and derived from the project and client key, so it
    /// is stable across sessions where ``id`` is not. Returns `nil` before activation, and the
    /// session id when the server does not supply one.
    ///
    /// - Returns: The stable actor, or `nil` when the client is not activated.
    public func getActorID() -> ActorID? {
        self.actorID
    }

    /**
     * `has` checks whether the given resource is attached to this client or not.
     */
    public func has(_ key: String) -> Bool {
        return self.attachmentMap[key] != nil
    }

    /**
     * @param rpcAddr - the address of the RPC server.
     * @param opts - the options of the client.
     */
    public init(
        _ urlString: String,
        _ options: ClientOptions = ClientOptions(),
        isMockingEnabled: Bool = false
    ) {
        self.key = options.key ?? UUID().uuidString
        self.syncLoopDuration = options.syncLoopDuration
        self.retrySyncLoopDelay = options.retrySyncLoopDelay
        self.reconnectStreamDelay = options.reconnectStreamDelay
        self.maximumAttachmentTimeout = options.maximumAttachmentTimeout

        let protocolClient = ProtocolClient(httpClient: URLSessionHTTPClient(),
                                            config: ProtocolClientConfig(host: urlString,
                                                                         networkProtocol: .connect,
                                                                         codec: ProtoCodec()))

        self.yorkieService = YorkieService(rpcClient: YorkieServiceClient(client: protocolClient), isMockingEnabled: isMockingEnabled)
        self.authTokenInjector = options.authTokenInjector
        self.authHeader = AuthHeader(apiKey: options.apiKey, token: "")
        self.metadata = options.metadata
        self.store = options.store
        self.sessionLock = options.sessionLock
        self.apiKey = options.apiKey ?? ""
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

        if let authTokenInjector {
            try await injectAuthTokenAfterGet(with: authTokenInjector, reason: nil)
        }

        do {
            let activateRequest = ActivateClientRequest.with {
                $0.clientKey = self.key
                $0.metadata = self.metadata
            }

            let activateResponse = await self.yorkieService.activateClient(
                request: activateRequest,
                headers: self.authHeader.makeHeader(self.key)
            )

            guard activateResponse.error == nil, let message = activateResponse.message else {
                throw self.handleErrorResponse(activateResponse.error, defaultMessage: "Unknown activate error")
            }

            self.id = message.clientID
            // The server's stable actor, derived from the project and client key. An older
            // server leaves it empty, in which case the session id remains the actor.
            self.actorID = message.actorID.isEmpty ? message.clientID : message.actorID

            self.status = .activated
            await self.runSyncLoop()

            Logger.debug("Client(\(self.key)) activated")
        } catch {
            Logger.error("Failed to request activate client(\(self.key)).")
            await self.handleConnectError(error)
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

            let deactivateResponse = await self.yorkieService.deactivateClient(request: deactivateRequest,
                                                                               headers: self.authHeader.makeHeader(self.key))

            guard deactivateResponse.error == nil else {
                throw self.handleErrorResponse(deactivateResponse.error, defaultMessage: "Unknown deactivate error")
            }

            // Before `deactivateInternal`, which drops the attachments this reads. Held
            // leases must not outlive the client: with a cross-process ``SessionLock`` a
            // leaked lease locks the document key out of every later activate for the
            // lifetime of the process. The stored copies stay, so a later session can resume
            // the changes they carry.
            await self.releaseAllSessions()
            try self.deactivateInternal()

            Logger.info("Client(\(self.key) deactivated.")
        } catch {
            Logger.error("Failed to request deactivate client(\(self.key)).")
            await self.handleConnectError(error)
            throw error
        }
    }

    /**
     *   `attach` attaches the given document to this client. It tells the server that
     *   the client will synchronize the given document.
     *
     *   - Parameter documentPollInterval: The poll interval in **seconds** (iOS `TimeInterval`),
     *     used only when `syncMode` is `.polling`. Unlike the JS SDK's millisecond `documentPollInterval`
     *     (default 3000), this is seconds (default `3.0`). Must be greater than 0.
     */
    @discardableResult
    public func attach(_ doc: Document,
                       _ initialPresence: PresenceData = [:],
                       _ syncMode: SyncMode = .realtime,
                       _ schema: String = "",
                       initialRoot: [String: JSONValuable?]? = nil,
                       documentPollInterval: TimeInterval? = nil,
                       disableGC: Bool = false,
                       disablePresence: Bool? = nil) async throws -> Document
    {
        // 01. Check if the client is ready to attach documents.
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard doc.status == .detached else {
            throw YorkieError(code: .errNotDetached, message: "\(self.key) is not detached.")
        }

        // Reject a duplicate attach of the same key on this client. Without this guard
        // the request reaches the server, which reports the already-attached key as a
        // misleading `ErrClientNotFound`; `handleConnectError` then escalates that into
        // deactivating the whole client. `attachmentMap` covers the resolved case and
        // `attachingDocs` covers a concurrent in-flight attach.
        guard self.attachmentMap[doc.getKey()] == nil, self.attachingDocs.contains(doc.getKey()) == false else {
            throw YorkieError(code: .errAlreadyAttached, message: "\(doc.getKey()) is already attached.")
        }

        // Marked in flight here, before the first suspension point, so a concurrent attach of
        // the same key is rejected by the guard above. Marking it later would leave the whole
        // offline-resume preamble — which really suspends on `sessionLock.acquire` and
        // `store.load` — as a window in which a second call sees both containers still empty,
        // passes the guard, and reaches the server, where the duplicate surfaces as a
        // misleading `ErrClientNotFound` that deactivates the entire client. Cleared however
        // this attach ends.
        self.attachingDocs.insert(doc.getKey())
        defer { self.attachingDocs.remove(doc.getKey()) }

        if let interval = documentPollInterval, interval <= 0 {
            throw YorkieError(code: .errInvalidArgument, message: "documentPollInterval must be greater than 0")
        }
        let pollIntervalPinned = documentPollInterval != nil
        let pollInterval = self.resolvePollInterval(documentPollInterval, syncMode)

        doc.setActor(self.actorID ?? clientID)

        // Resolve the effective presence-disabled state at attach time. The
        // explicit option wins; absent that, the Document's seeded value (from
        // construction or a prior attach response on this instance) is used. The
        // server is authoritative — the attach response overwrites this with the
        // fixated value — so this purely controls whether to push the initial
        // presence and what to send on the request.
        let resolvedDisablePresence = disablePresence ?? doc.isPresenceDisabled()

        var attachRequest = AttachDocumentRequest()
        attachRequest.clientID = clientID
        // Offline persistence preamble: take the session lease and restore any stored copy,
        // both before the change pack is built below.
        let resume = try await self.prepareOfflineResume(for: doc)
        var pendingSessionLockHandle = resume.handle
        let didRestore = resume.didRestore

        // Seeded after the restore, and skipped when one happened: a restore brings the
        // presence map back with it, so setting the initial presence here would append a
        // spurious local change on every resume. Seeding it before the restore would be
        // worse still — the restore overwrites the map and the change is silently lost.
        if !resolvedDisablePresence, !didRestore {
            try await self.seedInitialPresence(doc, initialPresence, lease: pendingSessionLockHandle)
        }

        // Built AFTER any restore, so the change pack carries the un-acknowledged local
        // changes the restore brought back. Building it first would push an empty pack and
        // silently strand everything the previous session left unsynced.
        attachRequest.changePack = Converter.toChangePack(pack: doc.createChangePack())
        attachRequest.schemaKey = schema
        attachRequest.disableGc = disableGC
        attachRequest.disablePresence = resolvedDisablePresence
        do {
            let docKey = doc.getKey()
            let semaphore = DispatchSemaphore(value: 0)

            self.semaphoresForInitialzation[docKey] = semaphore

            var attachResponse = await self.yorkieService.attachDocument(request: attachRequest, headers: self.authHeader.makeHeader(docKey))

            // A restored document whose epoch the server has since compacted past cannot be
            // resumed: the un-acknowledged changes it carries are anchored to a state the
            // server no longer has. Re-anchor from scratch and retry once as a fresh attach,
            // surfacing the discarded changes so the app can decide what to do about them.
            var resumed = didRestore
            // Gated on the store, not on whether a restore happened, matching upstream. A
            // Document instance reused across attaches keeps the epoch it learned last time,
            // so it can present a stale one with nothing restored; a store-backed client
            // should re-anchor from that too rather than surfacing the rejection. Clients
            // without a store keep today's app-driven epoch-mismatch behaviour.
            if self.store != nil, self.isEpochMismatch(attachResponse.error) {
                attachResponse = await self.retryAttachAfterReanchor(doc: doc,
                                                                     request: &attachRequest,
                                                                     initialPresence: initialPresence,
                                                                     disablePresence: resolvedDisablePresence)
                // The retry is a fresh attach, so the purge guard below has nothing persisted
                // left to compare against.
                resumed = false
            }

            guard attachResponse.error == nil, let message = attachResponse.message else {
                throw self.handleErrorResponse(attachResponse.error, defaultMessage: "Unknown attach error")
            }

            let maxSizePerDocument = message.maxSizePerDocument
            if maxSizePerDocument > 0 {
                doc.setMaxSizePerDocument(Int(maxSizePerDocument))
            }

            if let schemaRules = attachResponse.message?.schemaRules, !schemaRules.isEmpty {
                doc.setSchemaRules(Converter.fromSchemaRules(schemaRules))
            }

            // Record the opt-out decision before applying the attach response so the
            // first applyChangePack already routes remote changes through the
            // lamport-only sync path.
            doc.setDisableGC(disableGC)
            // Align the document's presence gating to the server-fixated value
            // before applying the pack, so any subsequent update sees it settled.
            doc.setDisablePresence(message.disablePresence)

            let pack = try Converter.fromChangePack(message.changePack)

            if resumed {
                await self.dropPurgedOfflineState(doc: doc,
                                                  pack: pack,
                                                  documentID: message.documentID,
                                                  disableGC: disableGC,
                                                  disablePresence: message.disablePresence)
            }

            try doc.applyChangePack(pack)
            // Record the server-assigned document id so the next persisted envelope carries it
            // for the purge guard on a later restore.
            doc.setDocID(message.documentID)

            if doc.status == .removed {
                throw YorkieError(code: .errDocumentRemoved, message: "\(doc) is removed.")
            }

            doc.applyStatus(.attached)

            self.attachmentMap[doc.getKey()] = Attachment<Document>(resource: doc,
                                                                    resourceID: message.documentID,
                                                                    syncMode: syncMode,
                                                                    changeEventReceived: false,
                                                                    pollInterval: pollInterval,
                                                                    pollIntervalPinned: pollIntervalPinned,
                                                                    disableGC: disableGC,
                                                                    disablePresence: message.disablePresence)
            if let attachment = self.getDocumentAttachment(doc.getKey()) {
                self.installOfflinePersistence(on: attachment, doc: doc, lease: pendingSessionLockHandle)
                // Ownership of the lease has moved to the attachment, which releases it on
                // detach. Cleared so the failure path below cannot release it a second time.
                pendingSessionLockHandle = nil
            }

            // Polling mode opens no watch stream; the timer-driven sync loop drives pushpull
            // via needRealtimeSync. Skip waitForInitialization too — no stream to wait for.
            if syncMode != .manual && syncMode != .polling {
                try self.runWatchLoop(docKey)
                try await self.waitForInitialization(semaphore, docKey)
            }

            Logger.info("[AD] c:\"\(self.key))\" attaches d:\"\(doc.getKey())\"")

            self.semaphoresForInitialzation.removeValue(forKey: docKey)

            let crdtObject = doc.getRootObject()
            if let initialRoot {
                try doc.update { root, _ in
                    for key in initialRoot.keys where !crdtObject.has(key: key) {
                        root.set(key: key, value: initialRoot[key])
                    }
                }
            }

            // Clear undo/redo stacks so that initialRoot setup operations
            // are not reachable via undo.
            doc.clearHistory()

            return doc
        } catch {
            // No attachment took ownership of the lease, so release it here rather than
            // holding it for the process lifetime and locking the key out of every retry.
            await pendingSessionLockHandle?.release()
            Logger.error("Failed to request attach document(\(self.key)).", error: error)
            await self.handleConnectError(error)
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

        guard let attachment = getDocumentAttachment(doc.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        try doc.update { _, presence in
            presence.clear()
        }

        var detachDocumentRequest = DetachDocumentRequest()
        detachDocumentRequest.clientID = clientID
        detachDocumentRequest.documentID = attachment.resourceID
        detachDocumentRequest.changePack = Converter.toChangePack(pack: doc.createChangePack())

        do {
            let detachDocumentResponse = await self.yorkieService.detachDocument(request: detachDocumentRequest,
                                                                                 headers: self.authHeader.makeHeader(doc.getKey()))

            guard detachDocumentResponse.error == nil, let message = detachDocumentResponse.message else {
                throw self.handleErrorResponse(detachDocumentResponse.error, defaultMessage: "Unknown detach error")
            }

            let pack = try Converter.fromChangePack(message.changePack)

            try doc.applyChangePack(pack)

            if doc.status != .removed {
                doc.applyStatus(.detached)
            }

            let releasedAttachment = self.getDocumentAttachment(doc.getKey())
            try self.detachInternal(doc.getKey())
            await self.releasePersistence(for: doc, attachment: releasedAttachment)

            Logger.info("[DD] c:\"\(self.key)\" detaches d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request detach document(\(self.key)).", error: error)
            await self.handleConnectError(error)
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

        guard let attachment = getDocumentAttachment(doc.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var removeDocumentRequest = RemoveDocumentRequest()
        removeDocumentRequest.clientID = clientID
        removeDocumentRequest.documentID = attachment.resourceID
        removeDocumentRequest.changePack = Converter.toChangePack(pack: doc.createChangePack(true))

        do {
            let removeDocumentResponse = await self.yorkieService.removeDocument(request: removeDocumentRequest, headers: self.authHeader.makeHeader(doc.getKey()))

            guard removeDocumentResponse.error == nil, let message = removeDocumentResponse.message else {
                throw self.handleErrorResponse(removeDocumentResponse.error, defaultMessage: "Unknown remove error")
            }

            let pack = try Converter.fromChangePack(message.changePack)
            try doc.applyChangePack(pack)

            try self.detachInternal(doc.getKey())

            let releasedAttachment = self.getDocumentAttachment(doc.getKey())
            self.attachmentMap.removeValue(forKey: doc.getKey())
            await self.releasePersistence(for: doc, attachment: releasedAttachment)

            Logger.info("[DD] c:\"\(self.key)\" removed d:\"\(doc.getKey())\"")

            return doc
        } catch {
            Logger.error("Failed to request remove document(\(self.key)).", error: error)
            await self.handleConnectError(error)
            throw error
        }
    }

    // MARK: - Revision Methods

    /**
     * `createRevision` creates a new revision for the given document.
     */
    @discardableResult
    public func createRevision(_ doc: Document, label: String, description: String = "") async throws -> RevisionSummary {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = getDocumentAttachment(doc.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var request = CreateRevisionRequest()
        request.clientID = clientID
        request.documentID = attachment.resourceID
        request.label = label
        request.description_p = description

        do {
            let response = await self.yorkieService.createRevision(request: request, headers: self.authHeader.makeHeader(doc.getKey()))

            guard response.error == nil, let message = response.message else {
                throw self.handleErrorResponse(response.error, defaultMessage: "Unknown create revision error")
            }

            guard message.hasRevision else {
                throw YorkieError(code: .errInvalidArgument, message: "revision is not returned")
            }

            Logger.info("[CR] c:\"\(self.key)\" creates revision d:\"\(doc.getKey())\" l:\"\(label)\"")

            return Converter.fromRevisionSummary(message.revision)
        } catch {
            Logger.error("Failed to request create revision(\(self.key)).", error: error)
            await self.handleConnectError(error)
            throw error
        }
    }

    /**
     * `listRevisions` lists all revisions for the given document.
     */
    public func listRevisions(_ doc: Document, pageSize: Int32 = 10, offset: Int32 = 0, isForward: Bool = false) async throws -> [RevisionSummary] {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = getDocumentAttachment(doc.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var request = ListRevisionsRequest()
        request.clientID = clientID
        request.documentID = attachment.resourceID
        request.pageSize = pageSize
        request.offset = offset
        request.isForward = isForward

        do {
            let response = await self.yorkieService.listRevisions(request: request, headers: self.authHeader.makeHeader(doc.getKey()))

            guard response.error == nil, let message = response.message else {
                throw self.handleErrorResponse(response.error, defaultMessage: "Unknown list revisions error")
            }

            Logger.info("[LR] c:\"\(self.key)\" lists revisions d:\"\(doc.getKey())\" count:\(message.revisions.count)")

            return message.revisions.map(Converter.fromRevisionSummary)
        } catch {
            Logger.error("Failed to request list revisions(\(self.key)).", error: error)
            await self.handleConnectError(error)
            throw error
        }
    }

    /**
     * `getRevision` retrieves a specific revision by its ID with full snapshot data.
     */
    public func getRevision(_ doc: Document, revisionID: String) async throws -> RevisionSummary {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = getDocumentAttachment(doc.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var request = GetRevisionRequest()
        request.clientID = clientID
        request.documentID = attachment.resourceID
        request.revisionID = revisionID

        do {
            let response = await self.yorkieService.getRevision(request: request, headers: self.authHeader.makeHeader(doc.getKey()))

            guard response.error == nil, let message = response.message else {
                throw self.handleErrorResponse(response.error, defaultMessage: "Unknown get revision error")
            }

            guard message.hasRevision else {
                throw YorkieError(code: .errInvalidArgument, message: "revision is not returned")
            }

            Logger.info("[GR] c:\"\(self.key)\" gets revision d:\"\(doc.getKey())\" r:\"\(revisionID)\"")

            return Converter.fromRevisionSummary(message.revision)
        } catch {
            Logger.error("Failed to request get revision(\(self.key)).", error: error)
            await self.handleConnectError(error)
            throw error
        }
    }

    /**
     * `restoreRevision` restores the document to the given revision.
     */
    public func restoreRevision(_ doc: Document, revisionID: String) async throws {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard let attachment = getDocumentAttachment(doc.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        var request = RestoreRevisionRequest()
        request.clientID = clientID
        request.documentID = attachment.resourceID
        request.revisionID = revisionID

        do {
            let response = await self.yorkieService.restoreRevision(request: request, headers: self.authHeader.makeHeader(doc.getKey()))

            guard response.error == nil, response.message != nil else {
                throw self.handleErrorResponse(response.error, defaultMessage: "Unknown restore revision error")
            }

            Logger.info("[RR] c:\"\(self.key)\" restores revision d:\"\(doc.getKey())\" r:\"\(revisionID)\"")
        } catch {
            Logger.error("Failed to request restore revision(\(self.key)).", error: error)
            await self.handleConnectError(error)
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
     * `broadcast` broadcasts the given payload to the given topic over the channel
     * identified by the given key.
     */
    public func broadcast(_ channelKey: String, topic: String, payload: Payload, options: BroadcastOptions?) async throws {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard self.getChannelAttachment(channelKey) != nil else {
            throw YorkieError(code: .errNotAttached, message: "\(channelKey) is not attached when \(#function).")
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
        request.channelKey = channelKey
        request.topic = topic
        request.payload = payloadData

        try await self.broadcast(channelKey: channelKey, request: request, maxRetries: maxRetries)
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

        guard let docAttachment = getDocumentAttachment(docKey) else {
            throw YorkieError(code: .errNotAttached, message: "Can't find attachment by docKey! [\(docKey)]")
        }

        let prevSyncMode = docAttachment.syncMode
        if prevSyncMode == syncMode {
            return doc
        }

        // Set the mode first so an in-flight stream-disconnect callback observes
        // the new (stream-less) mode and does not reschedule a reconnect.
        docAttachment.syncMode = syncMode

        // Tear down stream when leaving a stream-using mode.
        if syncMode == .manual || syncMode == .polling {
            try self.stopWatchLoop(docKey, with: docAttachment)
        }

        if syncMode == .realtime {
            // NOTE(hackerwins): In non-pushpull mode, the client does not receive change events
            // from the server. Therefore, we need to set `changeEventReceived` to true
            // to sync the local and remote changes. This has limitations in that unnecessary
            // syncs occur if the client and server do not have any changes.
            docAttachment.changeEventReceived = true
        }

        // Recompute interval default if the user did not pin it.
        if !docAttachment.pollIntervalPinned {
            docAttachment.pollInterval = (syncMode == .polling) ? self.defaultPollingInterval : 0
        }

        // Start watch stream when entering a stream-using mode from a stream-less one.
        if (prevSyncMode == .manual || prevSyncMode == .polling)
            && syncMode != .manual && syncMode != .polling
        {
            // runWatchLoop already resets the attachment's `cancelled` flag, no extra reset needed.
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

        var attachment: Attachment<Document>?

        if let doc {
            attachment = self.getDocumentAttachment(doc.getKey())
            guard attachment != nil else {
                throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
            }
        }

        do {
            return try await self.performSyncInternal(false, attachment)
        } catch {
            await self.handleConnectError(error)
            throw error
        }
    }

    private func clearAttachmentRemoteChangeEventReceived(_ docKey: DocKey) {
        if let docAttachment = getDocumentAttachment(docKey) {
            docAttachment.changeEventReceived = false
        }
    }

    private func setSyncTimer(_ reconnect: Bool) {
        let isDisconnectedWatchStream = self.attachmentMap.values.contains { value in
            if let docAttachment = value as? Attachment<Document> {
                return docAttachment.isDisconnectedStream
            }
            return false
        }
        let syncLoopDuration = (reconnect || isDisconnectedWatchStream) ? self.reconnectStreamDelay : self.syncLoopDuration

        let timer = Timer(timeInterval: Double(syncLoopDuration) / 1000, repeats: false) { _ in
            Task {
                await self.doSyncLoop()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    private func performSyncInternal(_ isRealtimeSync: Bool, _ attachment: Attachment<Document>? = nil) async throws -> [Document] {
        await self.syncSemaphore.wait()

        defer {
            self.syncSemaphore.signal()
        }

        var result = [Document]()

        do {
            if isRealtimeSync {
                for (key, anyAttachment) in self.attachmentMap {
                    if let docAttachment = anyAttachment as? Attachment<Document>,
                       await docAttachment.needRealtimeSync()
                    {
                        self.clearAttachmentRemoteChangeEventReceived(key)
                        result.append(docAttachment.resource)
                        if let syncMode = docAttachment.syncMode {
                            try await self.syncInternal(docAttachment, syncMode)
                        }
                    }
                }
            } else {
                if let attachment {
                    result.append(attachment.resource)
                    try await self.syncInternal(attachment, .realtime)
                } else {
                    for (_, anyAttachment) in self.attachmentMap {
                        if let docAttachment = anyAttachment as? Attachment<Document> {
                            result.append(docAttachment.resource)
                            if let syncMode = docAttachment.syncMode {
                                try await self.syncInternal(docAttachment, syncMode)
                            }
                        }
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
            if await self.handleConnectError(error) {
                try? await Task.sleep(nanoseconds: UInt64(self.retrySyncLoopDelay * 1_000_000))
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

    private func doWatchLoop<R: Attachable>(_ key: String, with attachment: Attachment<R>) throws {
        attachment.resetWatchLoopTimer()

        guard self.isActive, let id = self.id else {
            Logger.debug("[WL] c:\"\(self.key)\" exit watch loop")
            self.setCondition(.watchLoop, value: false)
            throw YorkieError(code: .errClientNotActivated, message: "$\(key) is not active")
        }

        // NOTE: - Check if the resource is still attached to prevent
        // watch stream creation after detachment.
        if !self.attachmentMap.keys.contains(key) {
            self.conditions[ClientCondition.watchLoop] = false
            throw YorkieError(
                code: .errNotAttached,
                message: "\(key) is not attached"
            )
        }

        // NOTE: Don't create a new stream if one already exists and is connected
        // This prevents duplicate streams when mode switching happens rapidly
        if #available(iOS 16.0.0, *) {
            if attachment.remoteWatchStream != nil, !attachment.isDisconnectedStream {
                Logger.debug("[WL] c:\"\(self.key)\" stream already exists for \(key)")
                return
            }
        } else {
            // Fallback on earlier versions
        }

        // Handle Document watch streams. Uses the unified Watch RPC, sending a
        // single document ResourceDescriptor and consuming WatchResponse.
        if let docAttachment = attachment as? Attachment<Document> {
            let stream = self.yorkieService.watch(headers: self.authHeader.makeHeader(key), onResult: { result in
                Task {
                    switch result {
                    case .headers:
                        break
                    case .message(let message):
                        await self.handleWatchDocumentsResponse(docKey: key, response: message)
                    case .complete(_, let error, _):
                        if error != nil {
                            await docAttachment.resource.resetOnlineClients()
                            await docAttachment.resource.publishInitializedEvent()
                            await docAttachment.resource.publishConnectionEvent(.disconnected)
                        }

                        Logger.debug("[WD] c:\"\(self.key)\" unwatches")

                        if await self.handleConnectError(error) {
                            Logger.warning("[WL] c:\"\(self.key)\" has Error \(String(describing: error))")
                            await self.publishAuthErrorIfNeeded(error: error as? ConnectError, attachment: docAttachment, method: .watch)
                            try await self.onStreamDisconnect(key, with: docAttachment)
                        } else {
                            await self.setCondition(.watchLoop, value: false)
                            try await self.onStreamDisconnect(key, with: docAttachment)
                        }
                    }
                }
            })

            let request = WatchRequest.with {
                $0.clientID = id
                // Declaring the stable actor subscribes this client under it, so watch peer
                // ids and watched/unwatched events match the presence CRDT keying.
                $0.actorID = self.actorID ?? id
                $0.resources = [
                    ResourceDescriptor.with {
                        $0.document = DocumentDescriptor.with {
                            $0.documentID = docAttachment.resourceID
                        }
                    }
                ]
            }

            stream.send(request)

            docAttachment.connectStream(YorkieServerStream(stream))

            docAttachment.resource.publishConnectionEvent(.connected)
        }

        // Handle Channel watch streams. Uses the unified Watch RPC, sending a
        // single channel ResourceDescriptor and dispatching presence-count
        // updates + remote broadcast events to the Channel's event system.
        if let channelAttachment = attachment as? Attachment<Channel> {
            let stream = self.yorkieService.watch(headers: self.authHeader.makeHeader(channelAttachment.resource.getFirstKeyPath()), onResult: { result in
                Task {
                    switch result {
                    case .headers:
                        break
                    case .message(let message):
                        await self.handleWatchChannelResponse(channelKey: key, response: message)
                    case .complete(_, let error, _):
                        Logger.debug("[WC] c:\"\(self.key)\" unwatches")
                        if await self.handleConnectError(error) {
                            Logger.warning("[WL] c:\"\(self.key)\" channel has Error \(String(describing: error))")
                            await self.publishChannelAuthErrorIfNeeded(error: error as? ConnectError, channel: channelAttachment.resource, method: "Watch")
                            try await self.onStreamDisconnect(key, with: channelAttachment)
                        } else {
                            if let error = error as? ConnectError {
                                await channelAttachment.resource.publish(
                                    ChannelSyncErrorEvent(error: error, method: "Watch")
                                )
                            }
                            await self.setCondition(.watchLoop, value: false)
                            try await self.onStreamDisconnect(key, with: channelAttachment)
                        }
                    }
                }
            })

            let request = WatchRequest.with {
                $0.clientID = id
                $0.actorID = self.actorID ?? id
                $0.resources = [
                    ResourceDescriptor.with {
                        $0.channel = ChannelDescriptor.with {
                            $0.channelKey = channelAttachment.resource.getKey()
                        }
                    }
                ]
            }

            stream.send(request)
            channelAttachment.connectStream(YorkieServerStream(stream))
        }
    }

    /**
     * `runWatchLoop` runs the watch loop for the given resource. The watch loop
     * listens to the events of the given resource from the server.
     */
    private func runWatchLoop(_ key: String) throws {
        Logger.debug("[WL] c:\"\(self.key)\" run watch loop")
        guard let anyAttachment = self.attachmentMap[key] else {
            throw YorkieError(code: .errNotAttached, message: "\(key) is not attached")
        }

        self.setCondition(.watchLoop, value: true)

        if let docAttachment = anyAttachment as? Attachment<Document> {
            // Reset cancelled flag when starting a new watch loop
            docAttachment.cancelled = false
            try self.doWatchLoop(key, with: docAttachment)
        } else if let channelAttachment = anyAttachment as? Attachment<Channel> {
            // Reset cancelled flag when starting a new watch loop
            channelAttachment.cancelled = false
            try self.doWatchLoop(key, with: channelAttachment)
        }
    }

    private func stopWatchLoop<R: Attachable>(_ key: String, with attachment: Attachment<R>) throws {
        self.disconnectWatchStream(key, with: attachment)
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

    private func handleWatchDocumentsResponse(docKey: DocKey, response: WatchResponse) async {
        Logger.debug("[WL] c:\"\(self.key)\" got response \(response)")

        guard let body = response.body else {
            return
        }

        guard let docAttachment = getDocumentAttachment(docKey) else {
            return
        }

        switch body {
        case .initialization(let initialization):
            // Signal initialization once per init frame (mirrors JS `isInit`),
            // independent of the resource inits contained in it.
            self.semaphoresForInitialzation[docKey]?.signal()

            for resourceInit in initialization.resourceInits {
                guard case .documentInit(let documentInit) = resourceInit.init_p else { continue }

                var onlineClients = Set<ActorID>()
                let actorID = docAttachment.resource.actorID

                for pbClientID in documentInit.clientIds.filter({ $0 != actorID }) {
                    onlineClients.insert(pbClientID)
                }

                docAttachment.resource.setOnlineClients(onlineClients)
                // NOTE: stale presences are intentionally retained (not pruned) so a peer whose
                // watch stream reconnects becomes visible again — see `Document` presence handling.
                docAttachment.resource.publishPresenceEvent(.initialized)
            }
        case .event(let watchEvent):
            guard case .docEvent(let docWatchEvent) = watchEvent.event, docWatchEvent.hasEvent else { return }
            let pbWatchEvent = docWatchEvent.event
            let publisher = pbWatchEvent.publisher

            switch pbWatchEvent.type {
            case .documentChanged:
                docAttachment.changeEventReceived = true
            case .documentWatched:
                if docAttachment.resource.onlineClients.contains(pbWatchEvent.publisher),
                   docAttachment.resource.hasPresence(pbWatchEvent.publisher)
                {
                    return
                }

                docAttachment.resource.addOnlineClient(publisher)
                // NOTE(chacha912): We added to onlineClients, but we won't trigger watched event
                // unless we also know their initial presence data at this point.
                if let presence = docAttachment.resource.getPresence(publisher) {
                    docAttachment.resource.publishPresenceEvent(.watched, publisher, presence)
                }
            case .documentUnwatched:
                // NOTE(chacha912): There is no presence, when PresenceChange(clear) is applied before unwatching.
                // In that case, the 'unwatched' event is triggered while handling the PresenceChange.
                let presence = docAttachment.resource.getPresence(publisher)

                docAttachment.resource.removeOnlineClient(publisher)
                docAttachment.resource.removePresence(publisher)

                if let presence {
                    docAttachment.resource.publishPresenceEvent(.unwatched, publisher, presence)
                }
            default:
                break
            }
        }
    }

    private func disconnectWatchStream<R: Attachable>(_: String, with attachment: Attachment<R>) {
        guard !attachment.isDisconnectedStream else {
            return
        }
        attachment.disconnectStream()
        attachment.resetWatchLoopTimer()

        Logger.debug("[WL] c:\"\(self.key)\" disconnected watch stream")
    }

    private func onStreamDisconnect<R: Attachable>(_ key: String, with attachment: Attachment<R>) throws {
        let cancelled = attachment.cancelled
        self.disconnectWatchStream(key, with: attachment)
        // check if watch loop is stopped. `.manual` and `.polling` are stream-less
        // modes — never reschedule a watch-stream reconnect for them.
        guard self.attachmentMap[key] != nil,
              attachment.syncMode != .manual,
              attachment.syncMode != .polling
        else {
            return
        }
        // NOTE: Only schedule reconnect if the stream was not explicitly cancelled
        // The check in doWatchLoop will prevent duplicate streams
        if !cancelled {
            attachment.watchLoopReconnectTimer = Timer(timeInterval: Double(self.reconnectStreamDelay) / 1000, repeats: false) { _ in
                Task {
                    Logger.debug("[WL] c:\"\(self.key)\" reconnect timer fired. do watch loop")
                    try await self.doWatchLoop(key, with: attachment)
                }
            }

            if let watchLoopReconnectTimer = attachment.watchLoopReconnectTimer {
                RunLoop.main.add(watchLoopReconnectTimer, forMode: .common)
            }
        }
    }

    private func deactivateInternal() throws {
        self.status = .deactivated

        // Stop heartbeat timer
        self.channelHeartbeatTimer?.invalidate()
        self.channelHeartbeatTimer = nil

        for (key, _) in self.attachmentMap {
            // Update status based on resource type, but preserve removed status
            // IMPORTANT: Do this BEFORE detachInternal which removes from attachmentMap
            if let docAttachment = getDocumentAttachment(key) {
                if docAttachment.resource.getStatus() != .removed {
                    docAttachment.resource.applyStatus(.detached)
                }
            } else if let channelAttachment = getChannelAttachment(key) {
                if channelAttachment.resource.getStatus() != .removed {
                    channelAttachment.resource.setStatus(.detached)
                }
            }
            try self.detachInternal(key)
        }
    }

    private func detachInternal(_ key: String) throws {
        if let attachment = getDocumentAttachment(key) {
            attachment.resource.resetOnlineClients()
            try self.stopWatchLoop(key, with: attachment)
        } else if let attachment = getChannelAttachment(key) {
            // Tear down the local-broadcast forwarder installed by `attachChannel`
            // so a re-attach does not leave a stale forwarder behind.
            attachment.resource.unsubscribeLocalBroadcast()
            try self.stopWatchLoop(key, with: attachment)
        }

        self.attachmentMap.removeValue(forKey: key)
    }

    @discardableResult
    private func syncInternal(_ attachment: Attachment<Document>, _ syncMode: SyncMode) async throws -> Document {
        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid Client ID!")
        }

        var pushPullRequest = PushPullChangeRequest()
        pushPullRequest.clientID = clientID

        let doc = attachment.resource
        let requestPack = doc.createChangePack()
        let localSize = requestPack.getChangeSize()

        pushPullRequest.changePack = Converter.toChangePack(pack: requestPack)
        pushPullRequest.documentID = attachment.resourceID
        pushPullRequest.pushOnly = syncMode == .realtimePushOnly
        pushPullRequest.disableGc = attachment.disableGC

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
            attachment.updateHeartbeatTime()

            // Re-persist after a successful sync. A push that is merely acked, pulling
            // nothing, advances the checkpoint and drains the pushed changes from
            // `localChanges` without appending one — so the local-change hook never fires and
            // the stored envelope would keep an already-pushed change under a stale
            // checkpoint until the next edit. A resume from that envelope re-pushes a change
            // the server has already applied. This is a full overwrite, so it does not grow.
            if self.store != nil {
                self.enqueuePersist(doc)
            }

            if doc.status == .removed {
                // Nothing will call `detachInternal` for this document, so release what
                // offline persistence is holding before the attachment is dropped.
                await self.releaseSession(for: doc, attachment: attachment)
                self.attachmentMap.removeValue(forKey: docKey)
            }

            doc.publishSyncEvent(.synced)

            let remoteSize = responsePack.getChangeSize()
            Logger.info("[PP] c:\"\(self.key)\" sync d:\"\(docKey)\", push:\(localSize) pull:\(remoteSize) cp:\(responsePack.getCheckpoint().toTestString)")

            return doc
        } catch {
            doc.publishSyncEvent(.syncFailed)
            publishAuthErrorIfNeeded(error: error as? ConnectError, attachment: attachment, method: .pushPull)
            publishEpochMismatchIfNeeded(error: error as? ConnectError, attachment: attachment)

            Logger.error("[PP] c:\"\(self.key)\" err : \(error)")

            throw error
        }
    }

    /**
     * `handleConnectError` handles the given error. If the given error can be
     * retried after handling, it returns true.
     */
    @discardableResult
    private func handleConnectError(_ error: Error?) async -> Bool {
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

        // NOTE(chacha912): If the error is `Unauthenticated`, it means that the
        // token is invalid or expired. In this case, the client gets a new token
        // from the `authTokenInjector` and retries the api call.
        let yorkieErrorCode = YorkieError.Code(rawValue: errorCodeOf(error: connectError))
        if yorkieErrorCode == .errUnauthenticated, let authTokenInjector {
            let reason = errorMetadataOf(error: connectError)["reason"]
            try? await injectAuthTokenAfterGet(with: authTokenInjector, reason: reason)
            return true
        }

        // NOTE(hackerwins): If the error is `ErrEpochMismatch`, the document has been compacted and
        // the client's checkpoint is stale. The sync loop should stop, and the user must detach and
        // reattach the document to recover.
        if yorkieErrorCode == .errEpochMismatch {
            return false
        }

        // The client has reached the maximum number of allowed attachments.
        // In this case, the client should remove some attachments.
        if yorkieErrorCode == .errTooManyAttachments {
            Logger.error("Yorkie handle error with code: errTooManyAttachments")
            return false
        }

        // that the document has reached the maximum number of allowed subscriptions.
        // In this case, the client should retry the connection.
        if yorkieErrorCode == YorkieError.Code.errTooManySubscribers {
            Logger.error("Too many subscribers: \(String(describing: yorkieErrorCode))")
            return true
        }

        // NOTE(hackerwins): Some errors should fix the state of the client.
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
     * `peekChannel` reads the current session count of a channel without
     * creating a session on the server. Use this when the caller only needs to
     * display the count (e.g. "N people writing") without contributing to it
     * and without receiving broadcasts.
     *
     * Unlike attaching with read-only access, this does not occupy a session
     * entry on the server, does not generate heartbeat RPCs, and does not
     * subscribe to channel events. Polling is the caller's responsibility.
     *
     * - Parameter channelKey: The key of the channel to peek.
     * - Returns: The current online session count of the channel.
     * - Throws: ``YorkieError`` when the client is not active or the request fails.
     */
    func peekChannel(_ channelKey: String) async throws -> Int {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        let firstKeyPath = channelKey.components(separatedBy: ".").first ?? channelKey

        var request = PeekChannelRequest()
        request.channelKey = channelKey

        do {
            let response = await self.yorkieService.peekChannel(request: request, headers: self.authHeader.makeHeader(firstKeyPath))

            guard response.error == nil, let message = response.message else {
                throw self.handleErrorResponse(response.error, defaultMessage: "Unknown peek channel error")
            }

            return Int(message.sessionCount)
        } catch {
            await self.handleConnectError(error)
            throw error
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

    private func broadcast(channelKey: String, request: BroadcastRequest, maxRetries: Int) async throws {
        var retryCount = 0
        let channelAttachment = self.getChannelAttachment(channelKey)

        while retryCount <= maxRetries {
            let message = await self.yorkieService.broadcast(
                request: request,
                headers: self.authHeader.makeHeader(channelAttachment?.resource.getFirstKeyPath() ?? channelKey)
            )

            switch message.result {
            case .success:
                Logger.info("[BC] c:\(self.key) broadcasted to p: \(request.channelKey) t: \(request.topic)")
                return
            case .failure(let error):
                Logger.error("[BC] c:\(self.key)", error: error)

                let recovered = await self.handleConnectError(error)
                if YorkieError.Code(rawValue: errorCodeOf(error: error)) == .errUnauthenticated,
                   let channel = channelAttachment?.resource
                {
                    channel.publish(
                        ChannelAuthErrorEvent(
                            reason: errorMetadataOf(error: error)["reason"] ?? "AuthError",
                            method: "Broadcast"
                        )
                    )
                }
                if !recovered {
                    throw error
                }

                retryCount += 1

                if retryCount > maxRetries {
                    Logger.error("BROADCAST, Exceeded maximum retry attempts for topic $topic")
                    throw error
                }

                let retryInterval = self.exponentialBackoff(retryCount: retryCount - 1)
                try await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000))
            }
        }
    }

    private func injectAuthTokenAfterGet(with authTokenInjector: AuthTokenInjector, reason: String?) async throws {
        let token = try await authTokenInjector.getToken(reason: reason)
        self.authHeader.updateToken(token)
    }

    private func publishAuthErrorIfNeeded(error: ConnectError?, attachment: Attachment<Document>?, method: AuthErrorValue.Method) {
        guard let connectError = error, let attachment else { return }
        let rawValue = errorCodeOf(error: connectError)
        guard let code = YorkieError.Code(rawValue: rawValue), code == .errUnauthenticated else {
            return
        }

        let reason = errorMetadataOf(error: connectError)["reason"] ?? ""
        attachment.resource.publishAuthErrorEvent(reason: reason, method: method)
    }

    /// Reports whether a response error is the server's stale-epoch signal.
    private func isEpochMismatch(_ error: ConnectError?) -> Bool {
        guard let error else {
            return false
        }
        return YorkieError.Code(rawValue: errorCodeOf(error: error)) == .errEpochMismatch
    }

    private func publishEpochMismatchIfNeeded(error: ConnectError?, attachment: Attachment<Document>?) {
        guard let connectError = error, let attachment else { return }
        let rawValue = errorCodeOf(error: connectError)
        guard let code = YorkieError.Code(rawValue: rawValue), code == .errEpochMismatch else {
            return
        }

        attachment.resource.publishEpochMismatchEvent(method: "PushPull")
    }
}

// MARK: - Channel watch response handling

private extension Client {
    @MainActor
    func handleWatchChannelResponse(channelKey: String, response: WatchResponse) {
        guard let channel = getChannelAttachment(channelKey)?.resource else { return }

        switch response.body {
        case .initialization(let initialization):
            for resourceInit in initialization.resourceInits {
                guard case .channelInit(let channelInit) = resourceInit.init_p else { continue }
                if channel.updateSessionCount(Int(channelInit.sessionCount), channelInit.seq) {
                    channel.publish(ChannelPresenceEvent(type: .initialized, count: Int(channelInit.sessionCount)))
                }
            }
        case .event(let watchEvent):
            guard case .channelEvent(let channelWatchEvent) = watchEvent.event, channelWatchEvent.hasEvent else { return }
            let event = channelWatchEvent.event
            switch event.type {
            case .presence:
                if channel.updateSessionCount(Int(event.sessionCount), event.seq) {
                    channel.publish(ChannelPresenceEvent(type: .presenceChanged, count: Int(event.sessionCount)))
                }
            case .broadcast:
                let payload = Payload(jsonData: event.payload)
                channel.publish(
                    ChannelBroadcastEvent(
                        clientID: event.publisher,
                        topic: event.topic,
                        payload: payload,
                        options: nil
                    )
                )
            case .unspecified, .UNRECOGNIZED:
                break
            }
        case .none:
            break
        }
    }

    func publishChannelAuthErrorIfNeeded(error: ConnectError?, channel: Channel, method: String) {
        guard let connectError = error else { return }
        let rawValue = errorCodeOf(error: connectError)
        guard let code = YorkieError.Code(rawValue: rawValue), code == .errUnauthenticated else {
            return
        }
        let reason = errorMetadataOf(error: connectError)["reason"] ?? ""
        channel.publish(ChannelAuthErrorEvent(reason: reason, method: method))
    }
}

// MARK: - Channel Methods

extension Client {
    /**
     * `attachChannel` attaches the given channel to this client.
     *
     * The channel is registered locally and the server is notified on the first
     * ``refreshChannel(_:)`` (the "first-call", carrying `client_key` + `metadata`),
     * which attaches the session and returns its id. There is no longer a dedicated
     * AttachChannel RPC — the lifecycle is consolidated onto RefreshChannel
     * (yorkie 0.7.10). Detach likewise needs no RPC: the server reclaims the session
     * via TTL once heartbeats stop.
     */
    @discardableResult
    public func attachChannel(_ channel: Channel) async throws -> Channel {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let clientID = self.id else {
            throw YorkieError(code: .errUnexpected, message: "Invalid client ID! [\(self.id ?? "nil")]")
        }

        guard channel.getStatus() == .detached else {
            throw YorkieError(code: .errNotDetached, message: "\(channel.getKey()) is not detached.")
        }

        channel.setActor(clientID)

        // Register the attachment locally with an empty session id; the first-call
        // refresh below populates it from the server response.
        self.attachmentMap[channel.getKey()] = Attachment<Channel>(resource: channel, resourceID: "")

        // Forward local broadcasts to the server. The Channel publishes a
        // local-broadcast event when its `broadcast` method is called; here we
        // bridge that event to the Broadcast RPC. `detachInternal` clears this
        // callback so a re-attach does not leave a stale forwarder installed.
        channel.subscribeLocalBroadcast { [weak self, weak channel] event in
            guard let channel else { return }
            let topic = event.topic
            let payload = event.payload
            let errorFn = event.options?.error
            let channelKey = channel.getKey()

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.broadcast(channelKey, topic: topic, payload: payload, options: event.options)
                } catch {
                    errorFn?(error)
                }
            }
        }

        do {
            // First-call refresh attaches the session on the server and populates
            // the session id and session count.
            try await self.refreshChannel(channel)

            // A first-call refresh that returns without a session leaves the channel
            // `.detached`; treat that as a failed attach (the catch below rolls back)
            // so callers never receive a "successful" channel without an active session.
            guard channel.getStatus() == .attached, !(channel.getSessionID()?.isEmpty ?? true) else {
                throw YorkieError(code: .errUnexpected, message: "RefreshChannel did not establish a session for \(channel.getKey())")
            }

            try self.runWatchLoop(channel.getKey())

            // Start heartbeat timer if not already running
            self.startHeartbeatTimer()

            Logger.info("[AP] c:\"\(self.key)\" attaches p:\"\(channel.getKey())\"")

            return channel
        } catch {
            // Roll back the local registration if the first-call attach failed.
            try? self.detachInternal(channel.getKey())
            channel.setStatus(.detached)
            Logger.error("Failed to attach channel(\(channel.getKey())).", error: error)
            await self.handleConnectError(error)
            throw error
        }
    }

    /**
     * `detachChannel` detaches the given channel from this client.
     *
     * This is a local cleanup only: there is no DetachChannel RPC. The server
     * reclaims the session via TTL once heartbeats stop (RefreshChannel-only
     * lifecycle, yorkie 0.7.10).
     */
    @discardableResult
    public func detachChannel(_ channel: Channel) async throws -> Channel {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard self.getChannelAttachment(channel.getKey()) != nil else {
            throw YorkieError(code: .errNotAttached, message: "\(channel.getKey()) is not attached when \(#function).")
        }

        // NOTE: JS awaits `attachment.waitForSyncComplete()` before tearing down so an
        // in-flight first-call refresh cannot re-create the session after detach. iOS
        // does not need that barrier: `Client`/`Channel` are `@MainActor`, and a refresh
        // suspended at its await re-checks `getChannelAttachment` after resuming (see
        // `refreshChannel`), so it cannot mutate channel state post-detach. The only
        // residue is a server session reclaimed by TTL if detach lands inside the
        // first-call window — heartbeats have already stopped, so it does expire.
        try self.detachInternal(channel.getKey())
        channel.setStatus(.detached)

        Logger.info("[DP] c:\"\(self.key)\" detaches p:\"\(channel.getKey())\" (local)")

        return channel
    }

    /**
     * `refreshChannel` sends a heartbeat to keep the channel session alive, and on
     * the first call (when no session id is held yet) attaches the session on the
     * server by carrying `client_key` + `metadata`. It also recovers transparently
     * when the server has reclaimed the session.
     */
    private func refreshChannel(_ channel: Channel) async throws {
        guard let clientID = self.id else {
            return
        }

        guard let attachment = getChannelAttachment(channel.getKey()) else {
            return
        }

        // First call: no session id yet, so carry `client_key` + `metadata` so the
        // server activates/attaches and returns a session id. The server ignores
        // these fields once a session id is established.
        let isFirstCall = attachment.resourceID.isEmpty

        var refreshRequest = RefreshChannelRequest()
        refreshRequest.clientID = clientID
        refreshRequest.channelKey = channel.getKey()
        refreshRequest.sessionID = attachment.resourceID
        if isFirstCall {
            refreshRequest.clientKey = self.key
            refreshRequest.metadata = self.metadata
        }

        let refreshResponse = await self.yorkieService.refreshChannel(request: refreshRequest, headers: self.authHeader.makeHeader(channel.getFirstKeyPath()))

        // A detach (or deactivate) may have run while the RPC was suspended at the
        // await. Drop late responses/errors so we don't resurrect events on a channel
        // the app considers gone. Mirrors the JS `!deactivating && !isDetaching` guard
        // around both the success and error publishes.
        let stillAttached = self.getChannelAttachment(channel.getKey()) != nil

        if let error = refreshResponse.error {
            // The server reclaimed our session (TTL expiry, restart, etc.). Clear the
            // local session id so the next refresh re-enters the first-call branch and
            // re-attaches transparently; do not surface this to the caller.
            if isErrorCode(error, YorkieError.Code.errSessionNotFound.rawValue) {
                Logger.info("[RP] c:\"\(self.key)\" session expired for p:\"\(channel.getKey())\", re-attaching")
                channel.setSessionID("")
                attachment.resourceID = ""
                // Re-attach immediately rather than waiting for the next heartbeat. The
                // retry re-enters as a first-call (session id is now empty); only retry
                // from a heartbeat refresh (`!isFirstCall`) and while still attached, so a
                // failing first-call can't recurse and a detached channel is left alone.
                if !isFirstCall, stillAttached {
                    try await self.refreshChannel(channel)
                }
                return
            }
            // Surface non-recoverable sync errors to channel subscribers so a UI layer
            // can render an error state — but only while still attached, so a detach
            // mid-flight doesn't flash a spurious error. A later successful event
            // implies recovery (there is no separate "recovered" event).
            if stillAttached {
                channel.publish(ChannelSyncErrorEvent(error: error, method: "RefreshChannel"))
            }
            throw self.handleErrorResponse(error, defaultMessage: "Unknown refresh channel error")
        }

        // Tolerate an empty (non-error) heartbeat ack, and drop a late response whose
        // channel was detached while the RPC was in flight.
        guard stillAttached, let message = refreshResponse.message else {
            return
        }

        if isFirstCall, !message.sessionID.isEmpty {
            // Defer the Attached transition until a real session id arrives. An empty
            // one (protocol drift / partial response) leaves the channel Detached so
            // the next tick re-enters the first-call branch instead of flapping.
            channel.setSessionID(message.sessionID)
            attachment.resourceID = message.sessionID
            channel.setStatus(.attached)
        }

        let previousSessionCount = channel.getSessionCount()
        if channel.updateSessionCount(Int(message.sessionCount), 0), channel.getSessionCount() != previousSessionCount {
            channel.publish(ChannelPresenceEvent(type: .presenceChanged, count: channel.getSessionCount()))
        }
        attachment.lastHeartbeatTime = Date().timeIntervalSince1970
    }

    /**
     * `startHeartbeatTimer` starts the periodic heartbeat timer for all attached channels.
     */
    private func startHeartbeatTimer() {
        guard self.channelHeartbeatTimer == nil else {
            return // Timer already running
        }

        self.channelHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: self.channelHeartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                await self.sendHeartbeats()
            }
        }
    }

    /**
     * `sendHeartbeats` sends heartbeats for all attached channels.
     */
    private func sendHeartbeats() async {
        for (_, attachment) in self.attachmentMap {
            if let channelAttachment = attachment as? Attachment<Channel> {
                // Only send heartbeats for realtime channels
                if channelAttachment.resource.isRealtime() {
                    let now = Date().timeIntervalSince1970
                    if now - channelAttachment.lastHeartbeatTime >= self.channelHeartbeatInterval {
                        do {
                            try await self.refreshChannel(channelAttachment.resource)
                        } catch {
                            Logger.error("Failed heartbeat for channel(\(channelAttachment.resource.getKey())).", error: error)
                        }
                    }
                }
            }
        }
    }

    /**
     * `syncChannel` manually refreshes the channel count for manual mode channels.
     * Returns the updated count.
     */
    @discardableResult
    public func syncChannel(_ channel: Channel) async throws -> Int {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        guard let attachment = getChannelAttachment(channel.getKey()) else {
            throw YorkieError(code: .errNotAttached, message: "\(channel.getKey()) is not attached")
        }

        try await self.refreshChannel(attachment.resource)
        return attachment.resource.getSessionCount()
    }
}

/// Offline persistence: the store, the single-active-session lease, and the resume paths
/// that reconcile a restored document with what the server still has.
///
/// Internal rather than private so the tests can drive the persistence chain directly. These
/// are not part of the public API.
extension Client {
    /// Returns the store key under which `docKey` is persisted.
    func storeKey(_ docKey: String) -> String {
        "\(self.apiKey)/\(self.key)/\(docKey)"
    }

    /// Returns the session lease name guarding `docKey` for this client.
    func sessionLockName(_ docKey: String) -> String {
        "yorkie-session:\(self.apiKey)/\(self.key)/\(docKey)"
    }

    /// Drops a document's stale persisted state and re-stamps it with this client's actor.
    ///
    /// ``Document/resetForReanchor()`` resets the change id along with everything else, which
    /// clears the actor the attach already assigned. Re-stamping here keeps every reset site
    /// from having to remember that.
    ///
    /// - Parameter doc: The document to re-anchor.
    func reanchor(_ doc: Document) {
        doc.resetForReanchor()
        if let actor = self.actorID ?? self.id {
            doc.setActor(actor)
        }
    }

    /// Hands the session lease to the attachment and starts persisting the document.
    ///
    /// The lease then lives exactly as long as the attachment does. Persistence is driven off
    /// every local change rather than the sync round trip, because what offline persistence
    /// has to survive is precisely the case where no sync ever runs to completion.
    ///
    /// - Parameters:
    ///   - attachment: The attachment taking ownership of the lease.
    ///   - doc: The attached document.
    ///   - lease: The held session lease, if one was taken.
    func installOfflinePersistence(on attachment: Attachment<Document>,
                                   doc: Document,
                                   lease: SessionLockHandle?)
    {
        attachment.sessionLockHandle = lease
        guard self.store != nil else {
            return
        }
        doc.onLocalChange = { [weak self, weak doc] in
            guard let self, let doc else {
                return
            }
            self.enqueuePersist(doc)
        }
    }

    /// Re-anchors a document whose resume the server rejected for a stale epoch, and retries
    /// the attach once.
    ///
    /// A restored document whose epoch the server has since compacted past cannot be resumed:
    /// the un-acknowledged changes it carries are anchored to a state the server no longer
    /// has. The persisted state is dropped — surfaced as a data-loss event first, so the app
    /// can decide what to do about the discarded edits — and the retry goes out as a fresh
    /// attach the server can re-anchor from its current snapshot.
    ///
    /// - Parameters:
    ///   - doc: The resumed document the server rejected.
    ///   - request: The attach request, re-packed here with the re-anchored change pack.
    ///   - initialPresence: The presence to seed, since the re-anchor cleared the restored map.
    ///   - disablePresence: Whether presence is disabled, in which case nothing is seeded.
    /// - Returns: The response to the retried attach.
    func retryAttachAfterReanchor(doc: Document,
                                  request: inout Yorkie_V1_AttachDocumentRequest,
                                  initialPresence: PresenceData,
                                  disablePresence: Bool) async
        -> ResponseMessage<Yorkie_V1_AttachDocumentResponse>
    {
        let docKey = doc.getKey()
        Logger.warning("[AD] c:\"\(self.key)\" stale epoch on resume of d:\"\(docKey)\"; re-anchoring")
        doc.publishLocalChangesDroppedEvent(reason: .epochReanchor, changes: doc.getPendingChangeStructs())
        self.reanchor(doc)
        try? await self.store?.remove(docKey: self.storeKey(docKey))

        // The retry is a fresh attach, so it needs the initial presence the resume path
        // skipped. Without this the client attaches with no presence entry at all: peers
        // never see it in `others` and its cursor is invisible until the app happens to set
        // presence again.
        if !disablePresence {
            try? doc.update { _, presence in
                presence.set(initialPresence)
            }
        }

        request.changePack = Converter.toChangePack(pack: doc.createChangePack())
        return await self.yorkieService.attachDocument(request: request,
                                                       headers: self.authHeader.makeHeader(docKey))
    }

    /// Discards a resumed document's persisted state when the server purged the document
    /// it was anchored to.
    ///
    /// If the server collected or deleted the document while this client was offline, attach
    /// mints a fresh empty one under a new document id with the server sequence back at 0.
    /// Restoring the persisted snapshot on top of that would present un-pushed edits against
    /// an unrelated document, so the purge is detected — by a changed document id, or by a
    /// server sequence that regressed to 0 while the local snapshot was non-empty — and the
    /// persisted state is dropped instead, surfaced as a data-loss event rather than left to
    /// corrupt the attach.
    ///
    /// Call before ``Document/applyChangePack(_:)``, while the document still carries the
    /// restored checkpoint and document id this compares against.
    ///
    /// - Parameters:
    ///   - doc: The resumed document.
    ///   - pack: The change pack from the attach response, not yet applied.
    ///   - documentID: The document id the server returned for this attach.
    ///   - disableGC: The attach's garbage-collection opt-out, restated after a reset.
    ///   - disablePresence: The server-fixated presence gating, restated after a reset.
    func dropPurgedOfflineState(doc: Document,
                                pack: ChangePack,
                                documentID: String,
                                disableGC: Bool,
                                disablePresence: Bool) async
    {
        let persistedDocID = doc.getDocID()
        let idChanged = persistedDocID.isEmpty == false && documentID != persistedDocID
        let seqRegressed = doc.checkpoint.getServerSeq() > 0 && pack.getCheckpoint().getServerSeq() == 0
        guard idChanged || seqRegressed else {
            return
        }

        Logger.warning("[AD] c:\"\(self.key)\" server purged d:\"\(doc.getKey())\" " +
            "(document id or server seq reset); dropping persisted offline state")
        doc.publishLocalChangesDroppedEvent(reason: .documentPurged, changes: doc.getPendingChangeStructs())
        try? await self.store?.remove(docKey: self.storeKey(doc.getKey()))
        self.reanchor(doc)
        // Restated because the reset cleared them along with the rest of the local state.
        doc.setDisableGC(disableGC)
        doc.setDisablePresence(disablePresence)
    }

    /// Takes the session lease and restores any stored copy of `doc`, before its change pack
    /// is built.
    ///
    /// The lease is acquired before any restore or RPC, so a second session fails fast rather
    /// than driving sync against a shared checkpoint. A client without a store does none of
    /// this and keeps the previous behaviour entirely.
    ///
    /// - Parameter doc: The document being attached.
    /// - Returns: The held lease, and whether a stored copy was restored.
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when another session holds the lease.
    func prepareOfflineResume(for doc: Document) async throws -> (handle: SessionLockHandle?, didRestore: Bool) {
        var acquired: SessionLockHandle?
        var restored = false
        if let store = self.store {
            guard let handle = await self.sessionLock.acquire(name: self.sessionLockName(doc.getKey())) else {
                throw YorkieError(
                    code: .errInvalidArgument,
                    message: "document \"\(doc.getKey())\" is already open in another session under offline "
                        + "persistence; only one active session per document is allowed to avoid silent edit loss"
                )
            }
            acquired = handle

            // Restore the persisted document so its un-acknowledged local changes are
            // re-pushed by the attach below. A stored copy belonging to a different actor is
            // discarded rather than adopted, since its changes are not ours to re-push.
            if let bytes = try? await store.load(docKey: self.storeKey(doc.getKey())) {
                do {
                    try doc.restoreFromBytes(bytes)
                    restored = true
                } catch {
                    // An envelope that cannot be restored is unusable, but it must never abort
                    // this attach or poison every later one: drop it and fall through to a fresh
                    // attach. Classified by error code, not by error type: every structural
                    // failure in the envelope decoder is a ``YorkieError`` too, so testing the
                    // type would report a truncated file as someone else's store.
                    let isActorMismatch = (error as? YorkieError)?.code == .errActorMismatch
                    let reason: LocalChangesDroppedValue.Reason = isActorMismatch ? .actorMismatch : .restoreFailed
                    Logger.warning("[Store] persisted state for \(doc.getKey()) unusable (\(reason.rawValue)): \(error)")
                    // Recovered from the stored bytes, not from `doc`: the restore failed, so
                    // `doc` never took on the persisted changes and would report none.
                    let dropped = (try? Document.fromBytes(key: doc.getKey(), bytes: bytes).getPendingChangeStructs()) ?? []
                    doc.publishLocalChangesDroppedEvent(reason: reason, changes: dropped)
                    // Deliberately no reset here. `restoreFromBytes` is all-or-nothing and
                    // threw before touching `doc`, so there is nothing of the stored copy to
                    // undo — and `doc` may carry the caller's own edits, made before attach,
                    // which a reset would destroy. Only the unusable stored entry goes.
                    try? await store.remove(docKey: self.storeKey(doc.getKey()))
                }
            }
        }

        return (acquired, restored)
    }

    /// Drops everything offline persistence held for a document that is no longer attached.
    ///
    /// The stored copy is removed before the lease is released, so no other session can
    /// resume a copy that is about to be deleted.
    ///
    /// - Parameters:
    ///   - doc: The document leaving this client.
    ///   - attachment: Its attachment, holding the session lease.
    func releasePersistence(for doc: Document, attachment: Attachment<Document>?) async {
        if self.store != nil {
            try? await self.store?.remove(docKey: self.storeKey(doc.getKey()))
        }
        await self.releaseSession(for: doc, attachment: attachment)
    }

    /// Resolves the polling interval for an attachment.
    ///
    /// - Parameters:
    ///   - requested: The caller's explicit interval, if any.
    ///   - syncMode: The attachment's sync mode.
    /// - Returns: The requested interval, else the default for polling mode and 0 otherwise.
    func resolvePollInterval(_ requested: TimeInterval?, _ syncMode: SyncMode) -> TimeInterval {
        if let requested {
            return requested
        }
        return syncMode == .polling ? self.defaultPollingInterval : 0
    }

    /// Seeds the initial presence on a document being attached.
    ///
    /// - Parameters:
    ///   - doc: The document to seed.
    ///   - presenceData: The presence to set.
    ///   - lease: The session lease already held for this attach, released if seeding fails.
    /// - Throws: Whatever the update throws, after letting the lease go.
    func seedInitialPresence(_ doc: Document, _ presenceData: PresenceData, lease: SessionLockHandle?) async throws {
        do {
            try doc.update { _, presence in
                presence.set(presenceData)
            }
        } catch {
            // Seeding can throw on schema validation or a size limit. The lease is already
            // held and nothing downstream will release it, so let it go here rather than
            // locking the document key out for the lifetime of the process.
            await lease?.release()
            throw error
        }
    }

    /// Releases every held session lease and stops persisting every attached document.
    ///
    /// Used on deactivate, which ends this client's claim on all of its documents at once.
    func releaseAllSessions() async {
        for key in self.attachmentMap.keys {
            guard let attachment = self.getDocumentAttachment(key) else {
                continue
            }
            await self.releaseSession(for: attachment.resource, attachment: attachment)
        }
    }

    /// Stops persisting `doc` and releases its session lease, leaving the stored copy intact.
    ///
    /// The teardown for a document this client stops driving without giving it up — a
    /// deactivate, or a document the server reports as removed mid-sync. The stored copy
    /// stays: it holds un-pushed changes a later session is meant to resume, which is the
    /// whole point of persisting it. Only the paths that deliberately discard a document
    /// (``detach(_:)``, ``remove(_:)``) also drop the stored bytes.
    ///
    /// - Parameters:
    ///   - doc: The document this client stops persisting.
    ///   - attachment: Its attachment, holding the session lease.
    func releaseSession(for doc: Document, attachment: Attachment<Document>?) async {
        doc.onLocalChange = nil
        // Drain any queued write first, so the lease is not released while a persist for this
        // document is still in flight and a second session could start resuming a half-written
        // envelope.
        let key = self.storeKey(doc.getKey())
        if let pending = self.persistTasks.removeValue(forKey: key) {
            await pending.value
        }
        await attachment?.sessionLockHandle?.release()
        attachment?.sessionLockHandle = nil
    }

    /// Persists the document's restorable envelope, when a store is configured.
    ///
    /// Failures are logged rather than thrown: losing a persisted copy must not fail the edit
    /// that triggered it, and the next local change will try again.
    func persistToStore(_ doc: Document) async {
        guard let store = self.store else {
            return
        }
        do {
            try await store.save(docKey: self.storeKey(doc.getKey()), bytes: doc.toBytes())
        } catch {
            Logger.warning("[Store] failed to persist \(doc.getKey()): \(error)")
        }
    }

    /// Waits for every queued persist to finish.
    ///
    /// Exists for tests, which otherwise have no way to observe the end of a chain that is
    /// deliberately fire-and-forget on the editing path.
    func drainPersists() async {
        for task in self.persistTasks.values {
            await task.value
        }
    }

    /// Queues a persist of `doc`, behind any persist of the same document already in flight.
    ///
    /// Writes for one document are chained rather than fired independently. A caller's
    /// ``DocStore`` may do real I/O, so two unordered writes can complete out of order and
    /// leave the store holding the older envelope — losing exactly the edits persistence
    /// exists to keep. Serializing per key makes the last write win the way it reads.
    ///
    /// - Parameter doc: The document to persist.
    func enqueuePersist(_ doc: Document) {
        let key = self.storeKey(doc.getKey())
        let previous = self.persistTasks[key]
        let task = Task { [weak self] in
            await previous?.value
            guard let self else {
                return
            }
            await self.persistToStore(doc)
        }
        self.persistTasks[key] = task
        Task { [weak self] in
            await task.value
            guard let self, self.persistTasks[key] == task else {
                return
            }
            self.persistTasks.removeValue(forKey: key)
        }
    }
}
