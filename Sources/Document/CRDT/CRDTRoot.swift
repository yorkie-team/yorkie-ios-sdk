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
     * `removedElementSetByCreatedAt` is a hash set that contains the creation
     * time of the removed element. It is used to find the removed element when
     * executing garbage collection.
     */
    private var removedElementSetByCreatedAt: Set<String> = Set()
    /**
     * `elementHasRemovedNodesSetByCreatedAt` is a hash set that contains the
     * creation time of the element that has removed nodes. It is used to find
     * the element that has removed nodes when executing garbage collection.
     */
    private var elementHasRemovedNodesSetByCreatedAt: Set<String> = Set()

    init(rootObject: CRDTObject = CRDTObject(createdAt: TimeTicket.initial)) {
        self.rootObject = rootObject
        self.elementPairMapByCreatedAt[self.rootObject.createdAt.toIDString] = (element: self.rootObject, parent: nil)

        self.rootObject.getDescendants(callback: { element, parent in
            self.registerElement(element, parent: parent)
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
    }

    /**
     * `deregisterElement` deregister the given element from hash table.
     */
    func deregisterElement(_ element: CRDTElement) {
        self.elementPairMapByCreatedAt[element.createdAt.toIDString] = nil
        self.removedElementSetByCreatedAt.remove(element.createdAt.toIDString)
    }

    /**
     * `registerRemovedElement` registers the given element to the hash set.
     */
    func registerRemovedElement(_ element: CRDTElement) {
        self.removedElementSetByCreatedAt.insert(element.createdAt.toIDString)
    }

    /**
     * `registerElementHasRemovedNodes` registers the given GC element to the
     * hash set.
     */
    func registerElementHasRemovedNodes(_ element: CRDTElement) {
        self.elementHasRemovedNodesSetByCreatedAt.insert(element.createdAt.toIDString)
    }

    /**
     * `elementMapSize` returns the size of element map.
     */
    var elementMapSize: Int {
        return self.elementPairMapByCreatedAt.count
    }

    /**
     * `removedElementSetSize` returns the size of removed element set.
     */
    var removedElementSetSize: Int {
        return self.removedElementSetByCreatedAt.count
    }

    /**
     * `getObject` returns root object.
     */
    var object: CRDTObject {
        return self.rootObject
    }

    /**
     * `garbageLength` returns length of nodes which can be garbage collected.
     */
    var garbageLength: Int {
        var count = 0
        var seen = Set<String>()

        self.removedElementSetByCreatedAt.forEach {
            seen.insert($0)

            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let element = pair.element as? CRDTContainer
            else {
                return
            }
            element.getDescendants { element, _ in
                seen.insert(element.createdAt.toIDString)
                return false
            }
        }

        count += seen.count

        self.elementHasRemovedNodesSetByCreatedAt.forEach {
            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let element = pair.element as? CRDTGCElement
            else {
                return
            }

            count += element.removedNodesLength
        }

        return count
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
    func garbageCollect(lessThanOrEqualTo ticket: TimeTicket) -> Int {
        var count = 0

        self.removedElementSetByCreatedAt.forEach {
            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let removedAt = pair.element.removedAt, removedAt <= ticket
            else {
                return
            }

            try? pair.parent?.purge(element: pair.element)
            count += self.garbageCollectInternal(element: pair.element)
        }

        self.elementHasRemovedNodesSetByCreatedAt.forEach {
            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let element = pair.element as? CRDTGCElement
            else {
                return
            }

            let removedNodeCount = element.purgeRemovedNodesBefore(ticket: ticket)
            guard removedNodeCount > 0 else {
                return
            }

            self.elementHasRemovedNodesSetByCreatedAt.remove(element.createdAt.toIDString)
            count += removedNodeCount
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
    private func toSortedJSON() -> String {
        return self.rootObject.toSortedJSON()
    }
}

extension CRDTRoot: CustomDebugStringConvertible {
    var debugDescription: String {
        self.toSortedJSON()
    }
}
