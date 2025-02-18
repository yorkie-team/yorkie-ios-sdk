/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

/**
 * `DocumentOptions` are the options to create a new document.
 *
 * @public
 */
public struct DocumentOptions {
    /**
     * `disableGC` disables garbage collection if true.
     */
    var disableGC: Bool

    public init(disableGC: Bool) {
        self.disableGC = disableGC
    }
}

/**
 * `DocumentStatus` represents the status of the document.
 */
public enum DocumentStatus: String {
    /**
     * Detached means that the document is not attached to the client.
     * The actor of the ticket is created without being assigned.
     */
    case detached

    /**
     * Attached means that this document is attached to the client.
     * The actor of the ticket is created with being assigned by the client.
     */
    case attached

    /**
     * Removed means that this document is removed. If the document is removed,
     * it cannot be edited.
     */
    case removed
}

public typealias DocumentKey = String
public typealias DocumentID = String

public enum PresenceSubscriptionType: String {
    case presence
    case myPresence
    case others
}

/**
 * A CRDT-based data type. We can representing the model
 * of the application. And we can edit it even while offline.
 *
 */
@MainActor
public class Document {
    public typealias SubscribeCallback = @MainActor (DocEvent, Document) -> Void

    private let key: DocumentKey
    private(set) var status: DocumentStatus = .detached
    private let disableGC: Bool
    private var changeID: ChangeID = .initial
    var checkpoint: Checkpoint = .initial
    private var localChanges = [Change]()

    private var root = CRDTRoot()
    private var clone: (root: CRDTRoot, presences: [ActorID: StringValueTypeDictionary])?

    private var defaultSubscribeCallback: SubscribeCallback?
    private var subscribeCallbacks = [String: SubscribeCallback]()
    private var presenceSubscribeCallback = [String: SubscribeCallback]()
    private var connectionSubscribeCallback: SubscribeCallback?
    private var statusSubscribeCallback: SubscribeCallback?
    private var syncSubscribeCallback: SubscribeCallback?

    /**
     * `onlineClients` is a set of client IDs that are currently online.
     */
    public var onlineClients = Set<ActorID>()

    /**
     * `presences` is a map of client IDs to their presence information.
     */
    private var presences = [ActorID: StringValueTypeDictionary]()

    public convenience nonisolated init(key: String) {
        self.init(key: key, opts: DocumentOptions(disableGC: false))
    }

    public nonisolated init(key: DocumentKey, opts: DocumentOptions) {
        self.key = key
        self.disableGC = opts.disableGC
    }

    /**
     * `update` executes the given updater to update this document.
     */
    public func update(_ updater: (_ root: JSONObject, _ presence: inout Presence) throws -> Void, _ message: String? = nil) throws {
        guard self.status != .removed else {
            throw YorkieError(code: .errDocumentRemoved, message: "\(self) is removed.")
        }

        guard let actorID = self.actorID else {
            throw YorkieError(code: .errUnexpected, message: "actor ID is null.")
        }

        // 01. Update the clone object and create a change.
        let clone = self.cloned
        let context = ChangeContext(id: self.changeID.next(), root: clone.root, message: message)

        let proxy = JSONObject(target: clone.root.object, context: context)

        if self.presences[actorID] == nil {
            self.clone?.presences[actorID] = [:]
        }

        var presence = Presence(changeContext: context, presence: self.clone?.presences[actorID] ?? [:])

        try updater(proxy, &presence)

        self.clone?.presences[actorID] = presence.presence

        // 02. Update the root object and presences from changes.
        if context.hasChange {
            Logger.trace("trying to update a local change: \(self.toJSON())")

            let change = context.getChange()
            let opInfos = (try? change.execute(root: self.root, presences: &self.presences)) ?? []
            self.localChanges.append(change)
            self.changeID = change.id

            // 03. Publish the document change event.
            // NOTE(chacha912): Check opInfos, which represent the actually executed operations.
            if !opInfos.isEmpty {
                let changeInfo = ChangeInfo(message: change.message ?? "",
                                            operations: opInfos,
                                            actorID: actorID,
                                            clientSeq: change.id.getClientSeq(),
                                            serverSeq: change.id.getServerSeq())
                let changeEvent = LocalChangeEvent(value: changeInfo)
                self.publish(changeEvent)
            }

            if change.presenceChange != nil, let presence = self.getPresence(actorID) {
                self.publish(PresenceChangedEvent(value: (actorID, presence)))
            }

            Logger.trace("after update a local change: \(self.toJSON())")
        }
    }

    /**
     * `subscribe` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribe(_ targetPath: String? = nil, _ callback: @escaping SubscribeCallback) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = callback
        } else {
            self.defaultSubscribeCallback = callback
        }
    }

    /**
     * `subscribePresence` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribePresence(_ type: PresenceSubscriptionType = .presence, _ callback: @escaping SubscribeCallback) {
        self.presenceSubscribeCallback[type.rawValue] = callback
    }

    /**
     * `subscribeConnection` registers a callback to subscribe to events on the document.
     * The callback will be called when the stream connection status changes.
     */
    public func subscribeConnection(_ callback: @escaping SubscribeCallback) {
        self.connectionSubscribeCallback = callback
    }

    /**
     * `subscribeStatus` registers a callback to subscribe to events on the document.
     * The callback will be called when the document status changes.
     */
    public func subscribeStatus(_ callback: @escaping SubscribeCallback) {
        self.statusSubscribeCallback = callback
    }

    /**
     * `subscribePresence` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribeSync(_ callback: @escaping SubscribeCallback) {
        self.syncSubscribeCallback = callback
    }

    /**
     * `unsubscribe` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribe(_ targetPath: String? = nil) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = nil
        } else {
            self.defaultSubscribeCallback = nil
        }
    }

    /**
     * `unsubscribePresence` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribePresence(_ type: PresenceSubscriptionType = .presence) {
        self.presenceSubscribeCallback.removeValue(forKey: type.rawValue)
    }

    /**
     * `unsubscribeConnection` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribeConnection() {
        self.connectionSubscribeCallback = nil
    }

    /**
     * `unsubscribeSync` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribeSync() {
        self.syncSubscribeCallback = nil
    }

    /**
     * `applyChangePack` applies the given change pack into this document.
     * 1. Remove local changes applied to server.
     * 2. Update the checkpoint.
     * 3. Do Garbage collection.
     *
     * - Parameter pack: change pack
     */
    func applyChangePack(_ pack: ChangePack) throws {
        if let snapshot = pack.getSnapshot() {
            try self.applySnapshot(pack.getCheckpoint().getServerSeq(), snapshot)
        } else if pack.hasChanges() {
            try self.applyChanges(pack.getChanges())
        }

        // 02. Remove local changes applied to server.
        while let change = self.localChanges.first, change.id.getClientSeq() <= pack.getCheckpoint().getClientSeq() {
            self.localChanges.removeFirst()
        }

        // NOTE(hackerwins): If the document has local changes, we need to apply
        // them after applying the snapshot. We need to treat the local changes
        // as remote changes because the application should apply the local
        // changes to their own document.
        if pack.hasSnapshot() {
            try self.applyChanges(self.localChanges)
        }

        // 03. Update the checkpoint.
        self.checkpoint.forward(other: pack.getCheckpoint())

        // 04. Do Garbage collection.
        if let ticket = pack.getMinSyncedTicket() {
            self.garbageCollect(ticket)
        }

        // 05. Update the status.
        if pack.isRemoved {
            self.applyStatus(.removed)
        }

        Logger.trace("\(self.root.toJSON())")
    }

    /**
     * `hasLocalChanges` returns whether this document has local changes or not.
     *
     */
    func hasLocalChanges() -> Bool {
        return self.localChanges.isEmpty == false
    }

    /**
     * `ensureClone` make a clone of root.
     */
    var cloned: (root: CRDTRoot, presences: [ActorID: PresenceData]) {
        if let clone = self.clone {
            return clone
        }

        self.clone = (self.root.deepcopy(), self.presences)

        return self.clone!
    }

    /**
     * `createChangePack` create change pack of the local changes to send to the
     * remote server.
     *
     */
    func createChangePack(_ forceToRemoved: Bool = false) -> ChangePack {
        let changes = self.localChanges
        let checkpoint = self.checkpoint.increasedClientSeq(by: UInt32(changes.count))
        return ChangePack(key: self.key, checkpoint: checkpoint, isRemoved: forceToRemoved ? true : self.status == .removed, changes: changes)
    }

    /**
     * `setActor` sets actor into this document. This is also applied in the local
     * changes the document has.
     *
     */
    func setActor(_ actorID: ActorID) {
        let changes = self.localChanges.map {
            var new = $0
            new.setActor(actorID)
            return new
        }

        self.localChanges = changes

        self.changeID = self.changeID.setActor(actorID)

        // TODOs also apply into root.
    }

    var actorID: ActorID? {
        self.changeID.getActorID()
    }

    /**
     * `getKey` returns the key of this document.
     *
     */
    nonisolated func getKey() -> String {
        return self.key
    }

    /**
     * `getCloneRoot` return clone object.
     */
    func getCloneRoot() -> CRDTObject? {
        return self.clone?.root.object
    }

    /**
     * `getRoot` returns a new proxy of cloned root.
     */
    public func getRoot() -> JSONObject {
        let clone = self.cloned
        let context = ChangeContext(id: self.changeID.next(), root: clone.root)

        return JSONObject(target: clone.root.object, context: context)
    }

    /**
     * `garbageCollect` purges elements that were removed before the given time.
     *
     */
    @discardableResult
    func garbageCollect(_ ticket: TimeTicket) -> Int {
        if self.disableGC {
            return 0
        }

        if let clone = self.clone {
            clone.root.garbageCollect(lessThanOrEqualTo: ticket)
        }
        return self.root.garbageCollect(lessThanOrEqualTo: ticket)
    }

    /**
     * `getRootObject` returns root object.
     *
     */
    func getRootObject() -> CRDTObject {
        return self.root.object
    }

    /**
     * `getGarbageLength` returns the length of elements should be purged.
     *
     */
    func getGarbageLength() -> Int {
        return self.root.garbageLength
    }

    /**
     * `getGarbageLengthFromClone` returns the length of elements should be purged from clone.
     */
    func getGarbageLengthFromClone() -> Int {
        return self.clone?.root.garbageLength ?? 0
    }

    /**
     * `toJSON` returns the JSON encoding of this array.
     */
    public func toJSON() -> String {
        return self.root.toJSON()
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this array.
     */
    public func toSortedJSON() -> String {
        return self.root.debugDescription
    }

    /**
     * `applySnapshot` applies the given snapshot into this document.
     */
    public func applySnapshot(_ serverSeq: Int64, _ snapshot: Data) throws {
        let (root, presences) = try Converter.bytesToSnapshot(bytes: snapshot)
        self.root = CRDTRoot(rootObject: root)
        self.presences = presences
        self.changeID = self.changeID.syncLamport(with: serverSeq)

        // drop clone because it is contaminated.
        self.clone = nil

        let snapshotEvent = SnapshotEvent(value: snapshot)
        self.publish(snapshotEvent)
    }

    /**
     * `applyChanges` applies the given changes into this document.
     */
    public func applyChanges(_ changes: [Change]) throws {
        Logger.debug(
            """
            trying to apply \(changes.count) remote changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.garbageElementSetSize)
            """)

        Logger.trace(changes.map { "\($0.id.toTestString)\t\($0.toTestString)" }.joined(separator: "\n"))

        let clone = self.cloned

        for change in changes {
            try change.execute(root: clone.root, presences: &self.clone!.presences)

            var changeInfo: ChangeInfo?
            var presenceEvent: DocEvent?

            guard let actorID = change.id.getActorID() else {
                throw YorkieError(code: .errUnexpected, message: "ActorID is null")
            }

            if let presenceChange = change.presenceChange, self.onlineClients.contains(actorID) {
                switch presenceChange {
                case .put(let presence):
                    // NOTE(chacha912): When the user exists in onlineClients, but
                    // their presence was initially absent, we can consider that we have
                    // received their initial presence, so trigger the 'watched' event
                    if self.onlineClients.contains(actorID) {
                        let peer = (actorID, presence.toJSONObejct)

                        if self.getPresence(actorID) != nil {
                            presenceEvent = PresenceChangedEvent(value: peer)
                        } else {
                            presenceEvent = WatchedEvent(value: peer)
                        }
                    }
                case .clear:
                    // NOTE(chacha912): When the user exists in onlineClients, but
                    // PresenceChange(clear) is received, we can consider it as detachment
                    // occurring before unwatching.
                    // Detached user is no longer participating in the document, we remove
                    // them from the online clients and trigger the 'unwatched' event.
                    guard let presence = self.getPresence(actorID) else {
                        throw YorkieError(code: .errUnexpected, message: "No presence!")
                    }

                    presenceEvent = UnwatchedEvent(value: (actorID, presence))

                    self.removeOnlineClient(actorID)
                }
            }

            let opInfos = try change.execute(root: self.root, presences: &self.presences)

            if change.hasOperations {
                changeInfo = ChangeInfo(message: change.message ?? "",
                                        operations: opInfos,
                                        actorID: actorID,
                                        clientSeq: change.id.getClientSeq(),
                                        serverSeq: change.id.getServerSeq())
            }

            // DocEvent should be emitted synchronously with applying changes.
            // This is because 3rd party model should be synced with the Document
            // after RemoteChange event is emitted. If the event is emitted
            // asynchronously, the model can be changed and breaking consistency.
            if let info = changeInfo {
                let remoteChangeEvent = RemoteChangeEvent(value: info)
                self.publish(remoteChangeEvent)
            }

            if let presenceEvent {
                self.publish(presenceEvent)
            }

            self.changeID = self.changeID.syncLamport(with: change.id.getLamport())
        }

        Logger.debug(
            """
            after appling \(changes.count) remote changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.garbageElementSetSize)
            """
        )
    }

    /**
     * `getValueByPath` returns the JSONElement corresponding to the given path.
     */
    public func getValueByPath(_ path: String) throws -> Any? {
        guard path.starts(with: JSONObject.rootKey) else {
            throw YorkieError(code: .errInvalidArgument, message: "The path must start with \(JSONObject.rootKey)")
        }

        let rootObject = self.getRoot()

        if path == JSONObject.rootKey {
            return rootObject
        }

        var subPath = path
        subPath.removeFirst(JSONObject.rootKey.count) // remove root path("$")

        let keySeparator = JSONObject.keySeparator

        guard subPath.starts(with: keySeparator) else {
            throw YorkieError(code: .errUnexpected, message: "Invalid path.")
        }

        subPath.removeFirst(keySeparator.count)

        return rootObject.get(keyPath: subPath)
    }

    /**
     * `applyStatus` applies the document status into this document.
     */
    func applyStatus(_ status: DocumentStatus) {
        self.status = status

        if status == .detached {
            self.setActor(ActorIDs.initial)
        }

        let event = StatusChangedEvent(source: status == .removed ? .remote : .local,
                                       value: StatusInfo(status: status, actorID: status == .attached ? self.actorID : nil))

        self.publish(event)
    }

    public nonisolated var debugDescription: String {
        "[\(self.key)]"
    }

    func publishPresenceEvent(_ eventType: DocEventType, _ peerActorID: ActorID? = nil, _ presence: [String: Any]? = nil) {
        switch eventType {
        case .initialized:
            self.publish(InitializedEvent(value: self.getPresences()))
        case .watched:
            if let peerActorID, let presence = presence {
                self.publish(WatchedEvent(value: (peerActorID, presence)))
            }
        case .unwatched:
            if let peerActorID, let presence = presence {
                self.publish(UnwatchedEvent(value: (peerActorID, presence)))
            }
        default:
            assertionFailure("Not presence Event type. \(eventType)")
        }
    }

    func publishConnectionEvent(_ status: StreamConnectionStatus) {
        self.publish(ConnectionChangedEvent(value: status))
    }

    func publishSyncEvent(_ status: DocumentSyncStatus) {
        self.publish(SyncStatusChangedEvent(value: status))
    }

    func publishInitializedEvent() {
        self.publish(InitializedEvent(value: self.getPresences()))
    }

    /**
     * `publish` triggers an event in this document, which can be received by
     * callback functions from document.subscribe().
     */
    private func publish(_ event: DocEvent) {
        let presenceEvents: [DocEventType] = [.initialized, .watched, .unwatched, .presenceChanged]

        if presenceEvents.contains(event.type) {
            if let callback = self.presenceSubscribeCallback[PresenceSubscriptionType.presence.rawValue] {
                callback(event, self)
            }

            if let id = self.actorID {
                var isMine = false
                var isOthers = false

                if event is InitializedEvent {
                    isMine = true
                } else if event is WatchedEvent {
                    isOthers = true
                } else if event is UnwatchedEvent {
                    isOthers = true
                } else if let event = event as? PresenceChangedEvent {
                    if event.value.clientID == id {
                        isMine = true
                    } else {
                        isOthers = true
                    }
                }

                if isMine {
                    if let callback = self.presenceSubscribeCallback[PresenceSubscriptionType.myPresence.rawValue] {
                        callback(event, self)
                    }
                }

                if isOthers {
                    if let callback = self.presenceSubscribeCallback[PresenceSubscriptionType.others.rawValue] {
                        callback(event, self)
                    }
                }
            }
        } else if event.type == .connectionChanged {
            self.connectionSubscribeCallback?(event, self)
        } else if event.type == .statusChanged {
            self.statusSubscribeCallback?(event, self)
        } else if event.type == .syncStatusChanged {
            self.syncSubscribeCallback?(event, self)
        } else if event.type == .snapshot {
            self.subscribeCallbacks["$"]?(event, self)
        } else if let event = event as? ChangeEvent {
            var operations = [String: [any OperationInfo]]()

            for operationInfo in event.value.operations {
                for targetPath in self.subscribeCallbacks.keys where self.isSameElementOrChildOf(operationInfo.path, targetPath) {
                    if operations[targetPath] == nil {
                        operations[targetPath] = [any OperationInfo]()
                    }
                    operations[targetPath]?.append(operationInfo)
                }
            }

            for (key, value) in operations {
                let info = ChangeInfo(message: event.value.message,
                                      operations: value,
                                      actorID: event.value.actorID,
                                      clientSeq: event.value.clientSeq,
                                      serverSeq: event.value.serverSeq)

                if let callback = self.subscribeCallbacks[key] {
                    callback(event.type == .localChange ? LocalChangeEvent(value: info) : RemoteChangeEvent(value: info), self)
                }
            }

            self.subscribeCallbacks["$"]?(event, self)
        }

        self.defaultSubscribeCallback?(event, self)
    }

    private func isSameElementOrChildOf(_ elem: String, _ parent: String) -> Bool {
        if parent == elem {
            return true
        }

        let nodePath = elem.components(separatedBy: ".")
        let targetPath = parent.components(separatedBy: ".")

        var result = true

        for (index, path) in targetPath.enumerated() where path != nodePath[safe: index] {
            result = false
        }

        return result
    }

    /**
     * `setOnlineClients` sets the given online client set.
     */
    func setOnlineClients(_ onlineClients: Set<ActorID>) {
        self.onlineClients = onlineClients
    }

    /**
     * `resetOnlineClients` resets the online client set.
     *
     */
    func resetOnlineClients() {
        self.onlineClients = Set<ActorID>()
    }

    /**
     * `addOnlineClient` adds the given clientID into the online client set.
     */
    func addOnlineClient(_ clientID: ActorID) {
        self.onlineClients.insert(clientID)
    }

    /**
     * `removeOnlineClient` removes the clientID from the online client set.
     */
    func removeOnlineClient(_ clientID: ActorID) {
        self.onlineClients.remove(clientID)
    }

    /**
     * `hasPresence` returns whether the given clientID has a presence or not.
     */
    public func hasPresence(_ clientID: ActorID) -> Bool {
        self.presences[clientID] != nil
    }

    /**
     * `getMyPresence` returns the presence of the current client.
     */
    public func getMyPresence() -> [String: Any]? {
        guard self.status == .attached, let id = self.actorID else {
            return nil
        }

        return self.presences[id]?.mapValues { $0.toJSONObject }
    }

    /**
     * `getPresence` returns the presence of the given clientID.
     */
    public func getPresence(_ clientID: ActorID) -> [String: Any]? {
        if clientID == self.actorID {
            return self.getMyPresence()
        }

        guard self.onlineClients.contains(clientID) else {
            return nil
        }

        return self.presences[clientID]?.mapValues { $0.toJSONObject }
    }

    /**
     * `getPresenceForTest` returns the presence of the given clientID.
     */
    public func getPresenceForTest(_ clientID: ActorID) -> [String: Any]? {
        self.presences[clientID]?.mapValues { $0.toJSONObject }
    }

    /**
     * `getPresences` returns the presences of online clients.
     */
    public func getPresences(_ excludeMyself: Bool = false) -> [PeerElement] {
        var presences = [PeerElement]()

        if !excludeMyself, let actorID, let presence = getMyPresence() {
            presences.append(PeerElement(actorID, presence))
        }

        for clientID in self.onlineClients {
            if let presence = getPresence(clientID) {
                presences.append((clientID, presence))
            }
        }

        return presences
    }
}
