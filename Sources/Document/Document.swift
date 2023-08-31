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

/**
 * A CRDT-based data type. We can representing the model
 * of the application. And we can edit it even while offline.
 *
 */
public actor Document {
    typealias SubscribeCallback = (DocEvent) -> Void

    private let key: DocumentKey
    private(set) var status: DocumentStatus
    private var changeID: ChangeID
    var checkpoint: Checkpoint
    private var localChanges: [Change]

    private var root: CRDTRoot
    private var clone: (root: CRDTRoot, presences: [ActorID: PresenceData])?

    private var defaultSubscribeCallback: SubscribeCallback?
    private var subscribeCallbacks: [String: SubscribeCallback]
    private var peersSubscribeCallback: SubscribeCallback?

    /**
     * `onlineClients` is a set of client IDs that are currently online.
     */
    public var onlineClients: Set<ActorID>

    /**
     * `presences` is a map of client IDs to their presence information.
     */
    private var presences: [ActorID: PresenceData]

    public init(key: String) {
        self.key = key
        self.status = .detached
        self.root = CRDTRoot()
        self.changeID = ChangeID.initial
        self.checkpoint = Checkpoint.initial
        self.localChanges = []
        self.subscribeCallbacks = [:]
        self.onlineClients = Set<ActorID>()
        self.presences = [:]
    }

    /**
     * `update` executes the given updater to update this document.
     */
    public func update(_ updater: (_ root: JSONObject, _ presence: inout Presence) -> Void, _ message: String? = nil) throws {
        guard self.status != .removed else {
            throw YorkieError.documentRemoved(message: "\(self) is removed.")
        }

        let clone = self.cloned
        let context = ChangeContext(id: self.changeID.next(), root: clone.root, message: message)

        guard let actorID = self.changeID.getActorID() else {
            throw YorkieError.unexpected(message: "actor ID is null.")
        }

        let proxy = JSONObject(target: clone.root.object, context: context)

        if self.presences[actorID] == nil {
            self.clone?.presences[actorID] = [:]
        }

        var presence = Presence(changeContext: context, presence: self.clone?.presences[actorID] ?? [:])

        updater(proxy, &presence)

        self.clone?.presences[actorID] = presence.presence

        if context.hasChange {
            Logger.trace("trying to update a local change: \(self.toJSON())")

            let change = context.getChange()
            let opInfos = (try? change.execute(root: self.root, presences: &self.presences)) ?? []
            self.localChanges.append(change)
            self.changeID = change.id

            if change.hasOperations {
                let changeInfo = ChangeInfo(message: change.message ?? "",
                                            operations: opInfos,
                                            actorID: change.id.getActorID())
                let changeEvent = LocalChangeEvent(value: changeInfo)
                self.processDocEvent(changeEvent)
            }

            if change.presenceChange != nil, let presence = self.presences[actorID] {
                let peerChangedInfo = PeersChangedValue.presenceChanged(peer: (actorID, presence))
                let peerChangedEvent = PeersChangedEvent(value: peerChangedInfo)
                self.processDocEvent(peerChangedEvent)
            }

            Logger.trace("after update a local change: \(self.toJSON())")
        }
    }

    /**
     * `subscribe` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribe(_ targetPath: String? = nil, _ callback: @escaping (DocEvent) -> Void) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = callback
        } else {
            self.defaultSubscribeCallback = callback
        }
    }

    /**
     * `subscribePeers` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribePeers(_ callback: @escaping (DocEvent) -> Void) {
        self.peersSubscribeCallback = callback
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
     * `unsubscribePeers` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribePeers() {
        self.peersSubscribeCallback = nil
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

        // 01. Remove local changes applied to server.
        while let change = self.localChanges.first, change.id.getClientSeq() <= pack.getCheckpoint().getClientSeq() {
            self.localChanges.removeFirst()
        }

        // 02. Update the checkpoint.
        self.checkpoint.forward(other: pack.getCheckpoint())

        // 03. Do Garbage collection.
        if let ticket = pack.getMinSyncedTicket() {
            self.garbageCollect(lessThanOrEqualTo: ticket)
        }

        // 04. Update the status.
        if pack.isRemoved {
            self.setStatus(.removed)
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

        self.changeID.setActor(actorID)

        // TODOs also apply into root.
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
    func garbageCollect(lessThanOrEqualTo ticket: TimeTicket) -> Int {
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
        self.processDocEvent(snapshotEvent)
    }

    /**
     * `applyChanges` applies the given changes into this document.
     */
    public func applyChanges(_ changes: [Change]) throws {
        Logger.debug(
            """
            trying to apply \(changes.count) remote changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.removedElementSetSize)
            """)

        Logger.trace(changes.map { "\($0.id.toTestString)\t\($0.toTestString)" }.joined(separator: "\n"))

        let clone = self.cloned

        for change in changes {
            try change.execute(root: clone.root, presences: &self.clone!.presences)
        }

        for change in changes {
            var updates: (changeInfo: ChangeInfo?, peer: PeersChangedValue?)

            guard let actorID = change.id.getActorID() else {
                throw YorkieError.unexpected(message: "ActorID is null")
            }

            if case .put(let presence) = change.presenceChange {
                if self.onlineClients.contains(actorID) {
                    let peer = (actorID, presence)

                    if self.presences[actorID] != nil {
                        updates.peer = PeersChangedValue.presenceChanged(peer: peer)
                    } else {
                        updates.peer = PeersChangedValue.watched(peer: peer)
                    }
                }
            }

            let opInfos = try change.execute(root: self.root, presences: &self.presences)

            if change.hasOperations {
                updates.changeInfo = ChangeInfo(message: change.message ?? "", operations: opInfos, actorID: actorID)
            }

            // NOTE: RemoteChange event should be emitted synchronously with
            // applying changes. This is because 3rd party model should be synced
            // with the Document after RemoteChange event is emitted. If the event
            // is emitted asynchronously, the model can be changed and breaking
            // consistency.
            if let info = updates.changeInfo {
                let remoteChangeEvent = RemoteChangeEvent(value: info)
                self.processDocEvent(remoteChangeEvent)
            }

            if let peer = updates.peer {
                let peerChangedEvent = PeersChangedEvent(value: peer)
                self.processDocEvent(peerChangedEvent)
            }

            self.changeID = self.changeID.syncLamport(with: change.id.getLamport())
        }

        Logger.debug(
            """
            after appling \(changes.count) remote changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.removedElementSetSize)
            """
        )
    }

    /**
     * `getValueByPath` returns the JSONElement corresponding to the given path.
     */
    public func getValueByPath(_ path: String) throws -> Any? {
        guard path.starts(with: JSONObject.rootKey) else {
            throw YorkieError.unexpected(message: "The path must start with \(JSONObject.rootKey)")
        }

        let rootObject = self.getRoot()

        if path == JSONObject.rootKey {
            return rootObject
        }

        var subPath = path
        subPath.removeFirst(JSONObject.rootKey.count) // remove root path("$")

        let keySeparator = JSONObject.keySeparator

        guard subPath.starts(with: keySeparator) else {
            throw YorkieError.unexpected(message: "Invalid path.")
        }

        subPath.removeFirst(keySeparator.count)

        return rootObject.get(keyPath: subPath)
    }

    private func createPaths(change: Change) -> [String] {
        let pathTrie = Trie<String>(value: "$")
        for op in change.operations {
            let createdAt = op.effectedCreatedAt
            if var subPaths = try? self.root.createSubPaths(createdAt: createdAt), subPaths.isEmpty == false {
                subPaths.removeFirst()
                pathTrie.insert(values: subPaths)
            }
        }
        return pathTrie.findPrefixes().map { $0.joined(separator: ".") }
    }

    public func setStatus(_ status: DocumentStatus) {
        self.status = status
    }

    public nonisolated var debugDescription: String {
        "[\(self.key)]"
    }

    /**
     * `publish` triggers an event in this document, which can be received by
     * callback functions from document.subscribe().
     */
    func publish(_ eventType: PeersChangedEventType, _ peerActorID: ActorID?) {
        switch eventType {
        case .initialized:
            self.processDocEvent(PeersChangedEvent(value: .initialized(peers: self.getPresences())))
        case .watched:
            if let peerActorID, let presence = self.getPresence(peerActorID) {
                self.processDocEvent(PeersChangedEvent(value: .watched(peer: (peerActorID, presence))))
            }
        case .unwatched:
            if let peerActorID {
                self.processDocEvent(PeersChangedEvent(value: .unwatched(peer: (peerActorID, [:]))))
            }
        default:
            break
        }
    }

    private func processDocEvent(_ event: DocEvent) {
        if event.type != .snapshot {
            if let event = event as? ChangeEvent {
                var operations = [String: [any OperationInfo]]()

                event.value.operations.forEach { operationInfo in
                    self.subscribeCallbacks.keys.forEach { targetPath in
                        if self.isSameElementOrChildOf(operationInfo.path, targetPath) {
                            if operations[targetPath] == nil {
                                operations[targetPath] = [any OperationInfo]()
                            }
                            operations[targetPath]?.append(operationInfo)
                        }
                    }
                }

                operations.forEach { key, value in
                    let info = ChangeInfo(message: event.value.message, operations: value, actorID: event.value.actorID)

                    self.subscribeCallbacks[key]?(event.type == .localChange ? LocalChangeEvent(value: info) : RemoteChangeEvent(value: info))
                }
            }
        } else {
            self.subscribeCallbacks["$"]?(event)
        }

        self.defaultSubscribeCallback?(event)

        if event.type == .peersChanged {
            self.peersSubscribeCallback?(event)
        }
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
     * `getPresence` returns the presence of the given clientID.
     */
    public func getPresence(_ clientID: ActorID) -> PresenceData? {
        self.presences[clientID]
    }

    /**
     * `getPresences` returns the presences of online clients.
     */
    public func getPresences() -> [PeerElement] {
        var presences = [PeerElement]()

        for clientID in self.onlineClients {
            if let presence = self.presences[clientID] {
                presences.append((clientID, presence))
            }
        }

        return presences
    }
}
