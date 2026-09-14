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

typealias CRDTElementPair = (element: CRDTElement, parent: CRDTContainer?)

/**
 * `RootStats` is a structure that represents the statistics of the root object.
 */
public struct RootStats {
    /**
     * `elements` is the number of elements in the root object.
     */
    let elements: Int

    /**
     * `gcElements` is the number of elements that can be garbage collected.
     */
    let gcElements: Int

    /**
     * `gcPairs` is the number of garbage collection pairs.
     */
    let gcPairs: Int
}

/**
 * `CRDTRoot` is a structure represents the root. It has a hash table of
 * all elements to find a specific element when applying remote changes
 * received from server.
 *
 * Every element has a unique time ticket at creation, which allows us to find
 * a particular element.
 */
class CRDTRoot {
    /**
     * `rootObject` is the root object of the document.
     */
    private var rootObject: CRDTObject
    /**
     * `elementPairMapByCreatedAt` is a hash table that maps the creation time of
     * an element to the element itself and its parent.
     */
    private var elementPairMapByCreatedAt: [String: CRDTElementPair] = [:]
    /**
     * `gcElementSetByCreatedAt` is a hash set that contains the creation
     * time of the removed element. It is used to find the removed element when
     * executing garbage collection.
     */
    private var gcElementSetByCreatedAt = Set<String>()
    /**
     * `sizeInGC` maps the creation time of every registered element whose size
     * counts toward `docSize.gc` rather than `docSize.live`, to the exact amount
     * charged. Each element's size belongs to exactly one of the two, and an
     * element reaches gc by more routes than it has removals: it can be removed
     * itself, or be a descendant of a removed container. Recording the amount
     * rather than a flag keeps the two sides symmetric even though `getDataSize`
     * is not stable over an element's lifetime -- it grows by a ticket the moment
     * `removedAt` is set, which can happen after the size has already moved.
     */
    private var sizeInGC: [String: DataSize] = [:]
    /**
     * `gcPairMap` is a hash table that maps the IDString of GCChild to the
     * element itself and its parent.
     */
    private var gcPairMap: [String: GCPair]

    /**
     * `docSize` is a structure that represents the size of the document.
     */
    private var docSize: DocSize

    init(rootObject: CRDTObject = CRDTObject(createdAt: TimeTicket.initial)) {
        self.rootObject = rootObject
        self.gcPairMap = [:]
        self.docSize = .init(live: .init(data: 0, meta: 0), gc: .init(data: 0, meta: 0))

        self.registerElement(self.rootObject, parent: nil)
        self.rootObject.getDescendants(callback: { element, _ in
            if element.removedAt != nil {
                self.registerRemovedElement(element)
            }
            if let element = element as? CRDTGCPairContainable {
                for pair in element.getGCPairs() {
                    self.registerGCPair(pair)
                }
            }
            // NOTE(#1227): Register dead position nodes in CRDTArray as GC pairs so
            // they are collected once all peers have applied the winning move.
            if let array = element as? CRDTArray {
                for node in array.getAllRGANodes() {
                    if node.getElementEntry() == nil, node.getPositionRemovedAt() != nil {
                        self.registerGCPair(GCPair(parent: array.getRGATreeList(), child: node))
                    }
                }
            }

            return false
        })
    }

    /**
     * `find` returns the element of given creation time.
     */
    func find(createdAt: TimeTicket) -> CRDTElement? {
        return self.elementPairMapByCreatedAt[createdAt.toIDString]?.element
    }

    /**
     * `findElementPairByCreatedAt` returns the element and its parent of the given creation time.
     *
     * Used by undo/redo to walk up the ancestor chain and detect whether any ancestor was removed.
     */
    func findElementPairByCreatedAt(_ createdAt: TimeTicket) -> CRDTElementPair? {
        return self.elementPairMapByCreatedAt[createdAt.toIDString]
    }

    private let subPathPrefix = "$"
    private let subPathSeparator = "."

    /**
     * `createSubPaths` creates an array of the sub paths for the given element.
     */
    func createSubPaths(createdAt: TimeTicket) throws -> [String] {
        guard let pair = self.elementPairMapByCreatedAt[createdAt.toIDString] else {
            return []
        }

        var result: [String] = []
        var pairForLoop: CRDTElementPair = pair
        while let parent = pairForLoop.parent {
            let createdAt = pairForLoop.element.createdAt
            let subPath = try parent.subPath(createdAt: createdAt)
            result.append(subPath)
            guard let parentPair = self.elementPairMapByCreatedAt[parent.createdAt.toIDString] else {
                break
            }

            pairForLoop = parentPair
        }

        result.append(self.subPathPrefix)
        return result.reversed()
    }

    /**
     * `createPath` creates path of the given element.
     */
    func createPath(createdAt: TimeTicket) throws -> String {
        return try self.createSubPaths(createdAt: createdAt).joined(separator: self.subPathSeparator)
    }

    /**
     * `registerElement` registers the given element to hash table.
     */
    func registerElement(_ element: CRDTElement, parent: CRDTContainer?) {
        self.elementPairMapByCreatedAt[element.createdAt.toIDString] = (element, parent)
        self.docSize.live.addDataSizes(others: element.getDataSize())

        if let element = element as? CRDTContainer {
            element.getDescendants { [unowned self] element, parent in
                self.elementPairMapByCreatedAt[element.createdAt.toIDString] = (element, parent)
                self.docSize.live.addDataSizes(others: element.getDataSize())
                return false
            }
        }
    }

    /**
     * `deregisterElement` deregister the given element and its descendants from hash table.
     */
    @discardableResult
    func deregisterElement(_ element: CRDTElement) -> Int {
        var count = 0

        let deregisterElementInternal: (CRDTElement) -> Void = { [unowned self] element in
            let createdAt = element.createdAt.toIDString
            // Subtract the size from wherever it is actually counted, and by the
            // amount actually charged. A descendant created inside an
            // already-removed container never passed through a removal, so it still
            // sits in live; subtracting it from gc would push gc below zero and
            // leave its cost in live forever.
            if let charged = self.sizeInGC[createdAt] {
                self.docSize.gc.subDataSize(others: charged)
                self.sizeInGC[createdAt] = nil
            } else {
                self.docSize.live.subDataSize(others: element.getDataSize())
            }

            self.elementPairMapByCreatedAt[createdAt] = nil
            self.gcElementSetByCreatedAt.remove(createdAt)
            count += 1
        }

        deregisterElementInternal(element)
        (element as? CRDTContainer)?.getDescendants { element, _ in
            deregisterElementInternal(element)
            return false
        }

        return count
    }

    /**
     * `registerRemovedElement` registers the given element to the hash set.
     */
    func registerRemovedElement(_ element: CRDTElement) {
        let moved = self.moveSizeToGC(element)

        // NOTE(hackerwins): registerElement books a container and every descendant
        // into live, and deregisterElement subtracts both when the tombstone is
        // collected. Removing a container therefore has to move its descendants as
        // well: booking only the container itself would strand their size in live
        // forever and drive gc negative once the collection subtracted them.
        if let element = element as? CRDTContainer {
            element.getDescendants { [unowned self] element, _ in
                _ = self.moveSizeToGC(element)
                return false
            }
        }

        // NOTE(hackerwins): When an element is removed, parent sets the removedAt
        // to mark the child as removed. That ticket is part of the size charged to
        // gc just now, but it was not part of what live held -- registerElement ran
        // before the removal -- so live gets it back. Only on the move that carried
        // it: a size already in gc, or one moved as a descendant while its own
        // removedAt is still unset, did not.
        //
        // This holds for the incremental path. The initializer instead registers an
        // already-tombstoned element at its post-removal size, so live did hold the
        // ticket and the refund over-credits it by one per tombstone. That drift is
        // pre-existing and unchanged here.
        if moved, element.removedAt != nil {
            self.docSize.live.meta += timeTicketSize
        }

        self.gcElementSetByCreatedAt.insert(element.createdAt.toIDString)
    }

    /**
     * `moveSizeToGC` moves the size of the given element from live to gc, and
     * reports whether it moved a size live was holding. A size already in gc --
     * because the element was removed before, or because a container above it
     * was -- only has its charge topped up: `getDataSize` grows by a ticket when
     * `removedAt` is set, which can happen after the move.
     */
    private func moveSizeToGC(_ element: CRDTElement) -> Bool {
        let createdAt = element.createdAt.toIDString
        let size = element.getDataSize()

        if let charged = self.sizeInGC[createdAt] {
            self.docSize.gc.addDataSizes(others: DataSize(data: size.data - charged.data,
                                                          meta: size.meta - charged.meta))
            self.sizeInGC[createdAt] = size
            return false
        }

        self.docSize.gc.addDataSizes(others: size)
        self.docSize.live.subDataSize(others: size)
        self.sizeInGC[createdAt] = size
        return true
    }

    /**
     * `registerGCPair` registers the given pair to hash table.
     */
    func registerGCPair(_ pair: GCPair) {
        guard let childID = pair.child?.toIDString else {
            return
        }

        if self.gcPairMap[childID] != nil {
            self.gcPairMap.removeValue(forKey: childID)
            return
        }

        self.gcPairMap[childID] = pair

        if let gcOnlySize = pair.gcOnlySize {
            // NOTE: The child's size was never counted in docSize.live (it was
            // born removed, or it was registered by the snapshot-load scan where
            // live only counts visible nodes), so there is nothing to move out
            // of live. Only the given size is added to gc; purge subtracts the
            // child's size from gc as usual.
            self.docSize.gc.addDataSizes(others: gcOnlySize)
            return
        }

        guard let size = pair.child?.getDataSize() else {
            Logger.critical("registerGCPair: missing child size for \(String(describing: pair.child))")
            return
        }

        // var docSizeLive: Int

        if pair.child is RHTNode {
            self.docSize.live.subDataSize(others: size)
        } else {
            self.docSize.live.subDataSize(others: size)
            self.docSize.live.meta += timeTicketSize
        }

        self.docSize.gc.addDataSizes(others: size)
    }

    /**
     * `unregisterGCPair` removes the given pair from the hash table. Called
     * when a tombstoned node is revived (un-tombstoned) by an
     * identity-preserving undo, so that a later re-registration (redo) is not
     * swallowed by the toggle in `registerGCPair`.
     *
     * NOTE: must be called AFTER the node's `removedAt` has been cleared, so
     * `getDataSize()` no longer includes the tombstone ticket.
     */
    func unregisterGCPair(_ pair: GCPair) {
        guard let childID = pair.child?.toIDString, self.gcPairMap[childID] != nil else {
            return
        }

        self.gcPairMap.removeValue(forKey: childID)

        guard let size = pair.child?.getDataSize() else {
            return
        }

        // Mirror registerGCPair's accounting: move the node's size back from
        // gc to live, and drop the tombstone ticket counted at register time.
        self.docSize.gc.subDataSize(others: size)
        self.docSize.live.addDataSizes(others: size)
        if !(pair.child is RHTNode) {
            self.docSize.gc.meta -= timeTicketSize
        }
    }

    /**
     * `elementMapSize` returns the size of element map.
     */
    var elementMapSize: Int {
        return self.elementPairMapByCreatedAt.count
    }

    /**
     * `garbageElementSetSize` returns the size of removed element set.
     */
    var garbageElementSetSize: Int {
        var seen = Set<String>()

        for createdAt in self.gcElementSetByCreatedAt {
            seen.insert(createdAt)
            guard let pair = self.elementPairMapByCreatedAt[createdAt],
                  let element = pair.element as? CRDTContainer
            else {
                continue
            }
            element.getDescendants { element, _ in
                seen.insert(element.createdAt.toIDString)
                return false
            }
        }

        return seen.count
    }

    /**
     * `object` returns root object.
     */
    var object: CRDTObject {
        return self.rootObject
    }

    /**
     * `garbageLength` returns length of nodes which can be garbage collected.
     */
    var garbageLength: Int {
        self.garbageElementSetSize + self.gcPairMap.count
    }

    /**
     * `getDocSize` returns the size of the document.
     */
    func getDocSize() -> DocSize {
        return self.docSize
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTRoot {
        if let object = self.rootObject.deepcopy() as? CRDTObject {
            return CRDTRoot(rootObject: object)
        }

        return CRDTRoot()
    }

    /**
     * `garbageCollect` purges elements that were removed before the given time.
     */
    @discardableResult
    func garbageCollect(minSyncedVersionVector: VersionVector) -> Int {
        var count = 0

        for createdAt in self.gcElementSetByCreatedAt {
            guard let pair = self.elementPairMapByCreatedAt[createdAt] else {
                continue
            }

            if let removedAt = pair.element.removedAt, minSyncedVersionVector.afterOrEqual(other: removedAt) {
                try? pair.parent?.purge(element: pair.element)
                count += self.deregisterElement(pair.element)
            }
        }

        for pair in self.gcPairMap.values {
            if let child = pair.child, child.removedAt == nil {
                // Node was revived but its pair was not unregistered. Reverse the
                // GC accounting (gc → live) and drop the stale entry via
                // unregisterGCPair so the registerGCPair toggle can't be tripped
                // later and docSize.gc/live stay consistent.
                self.unregisterGCPair(pair)
                continue
            }

            if let child = pair.child, let removedAt = child.removedAt, minSyncedVersionVector.afterOrEqual(other: removedAt) {
                pair.parent?.purge(node: child)
                if let datasize = pair.child?.getDataSize() {
                    self.docSize.gc.subDataSize(others: datasize)
                }
                self.gcPairMap.removeValue(forKey: child.toIDString)
                count += 1
            }
        }

        return count
    }

    /**
     * `toJSON` returns the JSON encoding of this root object.
     */
    func toJSON() -> String {
        return self.rootObject.toJSON()
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this root object.
     */
    func toSortedJSON() -> String {
        return self.rootObject.toSortedJSON()
    }

    /**
     * `getStats` returns the current statistics of the root object.
     * This includes counts of various types of elements and structural information.
     */
    func getStats() -> RootStats {
        return RootStats(elements: self.elementMapSize,
                         gcElements: self.garbageElementSetSize,
                         gcPairs: self.gcPairMap.count)
    }

    /**
     * `acc` accumulates the given DataSize to Live.
     */
    func acc(_ diff: DataSize) {
        self.docSize.live.addDataSizes(others: diff)
    }
}

extension CRDTRoot: CustomDebugStringConvertible {
    var debugDescription: String {
        self.toSortedJSON()
    }
}
