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
 * Presence key, value dictionary
 * Similar to an Indexable in JS SDK
 */
public typealias Presence = [String: Any]

public actor Document {
    private let key: String
    private var root: CRDTRoot
    private var clone: CRDTRoot?
    private var changeID: ChangeID
    private var checkpoint: Checkpoint
    private var localChanges: [Change]

    public let eventStream: PassthroughSubject<DocEvent, Never>

    public init(key: String) {
        self.key = key
        self.root = CRDTRoot()
        self.changeID = ChangeID.initial
        self.checkpoint = Checkpoint.initial
        self.localChanges = []
        self.eventStream = PassthroughSubject()
    }

    /**
     * `update` executes the given updater to update this document.
     */
    public func update(updater: (_ root: JSONObject) -> Void, message: String? = nil) {
        let clone = self.cloned
        let context = ChangeContext(id: self.changeID.next(), root: clone, message: message)

        let proxy = JSONObject(target: clone.object, context: context)
        updater(proxy)

        if context.hasOperations() {
            Logger.trivial("trying to update a local change: \(self.toJSON())")

            let change = context.getChange()
            try? change.execute(root: self.root)
            self.localChanges.append(change)
            self.changeID = change.id

            let changeInfo = ChangeInfo(change: change, paths: self.createPaths(change: change))
            let changeEvent = LocalChangeEvent(value: [changeInfo])
            self.eventStream.send(changeEvent)

            Logger.trivial("after update a local change: \(self.toJSON())")
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
        while self.localChanges.isEmpty == false {
            let change = self.localChanges.removeFirst()
            if change.id.getClientSeq() > pack.getCheckpoint().getClientSeq() {
                break
            }
        }

        // 02. Update the checkpoint.
        self.checkpoint.forward(other: pack.getCheckpoint())

        // 03. Do Garbage collection.
        if let ticket = pack.getMinSyncedTicket() {
            self.garbageCollect(lessThanOrEqualTo: ticket)
        }

        Logger.trivial("\(self.root.toJSON())")
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
    func createChangePack() -> ChangePack {
        let changes = self.localChanges
        let checkpoint = self.checkpoint.increasedClientSeq(by: UInt32(changes.count))
        return ChangePack(key: self.key, checkpoint: checkpoint, changes: changes)
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
     * `key` returns the key of this document.
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
        self.eventStream.send(snapshotEvent)
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

        Logger.trivial(changes.map { "\($0.id.structureAsString)\t\($0.structureAsString)" }.joined(separator: "\n"))

        let clone = self.cloned
        try changes.forEach {
            try $0.execute(root: clone)
        }

        try changes.forEach {
            try $0.execute(root: self.root)
            self.changeID.syncLamport(with: $0.id.getLamport())
        }

        let changeInfos = changes.map {
            ChangeInfo(change: $0, paths: self.createPaths(change: $0))
        }

        let changeEvent = RemoteChangeEvent(value: changeInfos)
        self.eventStream.send(changeEvent)

        Logger.debug(
            """
            after appling \(changes.count) remote changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.removedElementSetSize)
            """
        )
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
}
