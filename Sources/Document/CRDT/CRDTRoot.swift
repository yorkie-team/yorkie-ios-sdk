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
        self.rootObject.getDescendants(callback: { element, parent in
            if element.removedAt != nil {
                self.registerRemovedElement(element)
            }
            if let element = element as? CRDTGCPairContainable {
                for pair in element.getGCPairs() {
                    self.registerGCPair(pair)
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
     * `deregisterElement` deregister the given element from hash table.
     */
    func deregisterElement(_ element: CRDTElement) {
        self.docSize.gc.subDataSize(others: element.getDataSize())
        self.elementPairMapByCreatedAt[element.createdAt.toIDString] = nil
        self.gcElementSetByCreatedAt.remove(element.createdAt.toIDString)
    }

    /**
     * `registerRemovedElement` registers the given element to the hash set.
     */
    func registerRemovedElement(_ element: CRDTElement) {
        let size = element.getDataSize()

        self.docSize.gc.addDataSizes(others: size)
        self.docSize.live.subDataSize(others: size)

        self.docSize.live.meta += timeTicketSize

        self.gcElementSetByCreatedAt.insert(element.createdAt.toIDString)
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
    public func getDocSize() -> DocSize {
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
                count += self.garbageCollectInternal(element: pair.element)
            }
        }

        for pair in self.gcPairMap.values {
            if let child = pair.child, let removedAt = child.removedAt, minSyncedVersionVector.afterOrEqual(other: removedAt) {
                pair.parent?.purge(node: child)
                self.gcPairMap.removeValue(forKey: child.toIDString)
                count += 1
            }
        }

        return count
    }

    private func garbageCollectInternal(element: CRDTElement) -> Int {
        var count = 0

        let callback: (_ element: CRDTElement, _ parent: CRDTContainer?) -> Bool = { element, _ in
            self.deregisterElement(element)
            count += 1
            return false
        }

        _ = callback(element, nil)

        (element as? CRDTContainer)?.getDescendants(callback: callback)

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
    public func acc(_ diff: DataSize) {
        self.docSize.live.addDataSizes(others: diff)
    }
}

extension CRDTRoot: CustomDebugStringConvertible {
    var debugDescription: String {
        self.toSortedJSON()
    }
}
