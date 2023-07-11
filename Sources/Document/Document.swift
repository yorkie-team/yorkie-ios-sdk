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

/**
 * Presence key, value dictionary
 * Similar to an Indexable in JS SDK
 */
public typealias Presence = [String: Any]

public typealias DocumentKey = String
public typealias DocumentID = String

/**
 * A CRDT-based data type. We can representing the model
 * of the application. And we can edit it even while offline.
 *
 */
public actor Document {
    typealias SubscribeCallback = (DocEvent) async -> Void

    private let key: DocumentKey
    private(set) var status: DocumentStatus
    private var root: CRDTRoot
    private var clone: CRDTRoot?
    private var changeID: ChangeID
    internal var checkpoint: Checkpoint
    private var localChanges: [Change]
    private var defaultSubscribeCallback: SubscribeCallback?
    private var subscribeCallbacks: [String: SubscribeCallback]

    public init(key: String) {
        self.key = key
        self.status = .detached
        self.root = CRDTRoot()
        self.changeID = ChangeID.initial
        self.checkpoint = Checkpoint.initial
        self.localChanges = []
        self.subscribeCallbacks = [:]
    }

    /**
     * `update` executes the given updater to update this document.
     */
    public func update(_ updater: (_ root: JSONObject) -> Void, message: String? = nil) async throws {
        guard self.status != .removed else {
            throw YorkieError.documentRemoved(message: "\(self) is removed.")
        }

        let clone = self.cloned
        let context = ChangeContext(id: self.changeID.next(), root: clone, message: message)

        let proxy = JSONObject(target: clone.object, context: context)
        updater(proxy)

        if context.hasOperations() {
            Logger.trace("trying to update a local change: \(self.toJSON())")

            let change = context.getChange()
            let opInfos = (try? change.execute(root: self.root)) ?? []
            self.localChanges.append(change)
            self.changeID = change.id

            let changeInfo = ChangeInfo(message: change.message ?? "",
                                        operations: opInfos,
                                        actorID: change.id.getActorID())
            let changeEvent = LocalChangeEvent(value: changeInfo)
            self.processDocEvent(changeEvent)

            Logger.trace("after update a local change: \(self.toJSON())")
        }
    }

    /**
     * `subscribe` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribe(targetPath: String? = nil, callback: @escaping (DocEvent) async -> Void) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = callback
        } else {
            self.defaultSubscribeCallback = callback
        }
    }

    /**
     * `unsubscribe` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribe(targetPath: String? = nil) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = nil
        } else {
            self.defaultSubscribeCallback = nil
        }
    }

    /**
     * `applyChangePack` applies the given change pack into this document.
     * 1. Remove local changes applied to server.
     * 2. Update the checkpoint.
     * 3. Do Garbage collection.
     *
     * - Parameter pack: change pack
     */
    func applyChangePack(pack: ChangePack) throws {
        if let snapshot = pack.getSnapshot() {
            try self.applySnapshot(serverSeq: pack.getCheckpoint().getServerSeq(), snapshot: snapshot)
        } else if pack.hasChanges() {
            try self.applyChanges(changes: pack.getChanges())
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
    var cloned: CRDTRoot {
        if let clone = self.clone {
            return clone
        }

        let clone = self.root.deepcopy()
        self.clone = clone
        return clone
    }

    /**
     * `createChangePack` create change pack of the local changes to send to the
     * remote server.
     *
     */
    func createChangePack(_ forceToRemoved: Bool = false) -> ChangePack {
        let changes = self.localChanges
        let checkpoint = self.checkpoint.increasedClientSeq(by: UInt32(changes.count))
        return ChangePack(key: self.key, checkpoint: checkpoint, changes: changes, isRemoved: forceToRemoved ? true : self.status == .removed)
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
     * `getClone` return clone object.
     *
     */
    func getClone() -> CRDTObject? {
        return self.clone?.object
    }

    /**
     * `getRoot` returns a new proxy of cloned root.
     */
    public func getRoot() -> JSONObject {
        let clone = self.cloned
        let context = ChangeContext(id: self.changeID.next(), root: clone)

        return JSONObject(target: clone.object, context: context)
    }

    /**
     * `garbageCollect` purges elements that were removed before the given time.
     *
     */
    @discardableResult
    func garbageCollect(lessThanOrEqualTo ticket: TimeTicket) -> Int {
        if let clone = self.clone {
            clone.garbageCollect(lessThanOrEqualTo: ticket)
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
    func toJSON() -> String {
        return self.root.toJSON()
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this array.
     */
    func toSortedJSON() -> String {
        return self.root.debugDescription
    }

    /**
     * `applySnapshot` applies the given snapshot into this document.
     */
    func applySnapshot(serverSeq: Int64, snapshot: Data) throws {
        let obj = try Converter.bytesToObject(bytes: snapshot)
        self.root = CRDTRoot(rootObject: obj)
        self.changeID.syncLamport(with: serverSeq)

        // drop clone because it is contaminated.
        self.clone = nil

        let snapshotEvent = SnapshotEvent(value: snapshot)
        self.processDocEvent(snapshotEvent)
    }

    /**
     * `applyChanges` applies the given changes into this document.
     */
    func applyChanges(changes: [Change]) throws {
        Logger.debug(
            """
            trying to apply \(changes.count) remote changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.removedElementSetSize)
            """)

        Logger.trace(changes.map { "\($0.id.structureAsString)\t\($0.structureAsString)" }.joined(separator: "\n"))

        let clone = self.cloned
        try changes.forEach {
            try $0.execute(root: clone)
        }

        var changeInfos = [ChangeInfo]()
        try changes.forEach {
            let opInfos = try $0.execute(root: self.root)

            changeInfos.append(ChangeInfo(message: $0.message ?? "",
                                          operations: opInfos,
                                          actorID: $0.id.getActorID()))

            self.changeID.syncLamport(with: $0.id.getLamport())
        }

        changeInfos.forEach {
            self.processDocEvent(RemoteChangeEvent(value: $0))
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
    public func getValueByPath(path: String) throws -> Any? {
        guard path.starts(with: "$") else {
            throw YorkieError.unexpected(message: "The path must start with \"$\"")
        }

        let context = ChangeContext(id: self.changeID.next(), root: self.root)
        let rootObject = JSONObject(target: self.root.object, context: context)

        if path == "$" {
            return rootObject
        }

        var subPath = path
        subPath.removeFirst(2) // remove root path "$."

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

                for (key, value) in operations {
                    let info = ChangeInfo(message: event.value.message, operations: value, actorID: event.value.actorID)

                    if let callback = self.subscribeCallbacks[key] {
                        Task {
                            await callback(event.type == .localChange ? LocalChangeEvent(value: info) : RemoteChangeEvent(value: info))
                        }
                    }
                }
            }
        } else {
            if let callback = self.subscribeCallbacks["$"] {
                Task {
                    await callback(event)
                }
            }
        }

        Task {
            await self.defaultSubscribeCallback?(event)
        }
    }
}
