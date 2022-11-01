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
    private var rootObject: CRDTObject
    private var elementPairMapByCreatedAt: [TimeTicket: CRDTElementPair] = [:]
    private var removedElementSetByCreatedAt: Set<TimeTicket> = Set()
    private var textWithGarbageSetByCreatedAt: Set<TimeTicket> = Set()

    init(rootObject: CRDTObject = CRDTObject(createdAt: TimeTicket.initial)) {
        self.rootObject = rootObject
        self.elementPairMapByCreatedAt[self.rootObject.getCreatedAt()] = (element: self.rootObject, parent: nil)

        self.rootObject.getDescendants(callback: { element, parent in
            self.registerElement(element, parent: parent)
            return false
        })
    }

    /**
     * `find` returns the element of given creation time.
     */
    func find(createdAt: TimeTicket) -> CRDTElement? {
        return self.elementPairMapByCreatedAt[createdAt]?.element
    }

    private let subPathPrefix = "$"
    private let subPathSeparator = "."

    /**
     * `createSubPaths` creates an array of the sub paths for the given element.
     */
    func createSubPaths(createdAt: TimeTicket) throws -> [String] {
        guard let pair = self.elementPairMapByCreatedAt[createdAt] else {
            return []
        }

        var result: [String] = []
        var pairForLoop: CRDTElementPair = pair
        while let parent = pairForLoop.parent {
            let createdAt = pairForLoop.element.getCreatedAt()
            var subPath = try parent.subPath(createdAt: createdAt)
            subPath = self.escapeSubpath(subPath)
            result.append(subPath)
            guard let parentPair = self.elementPairMapByCreatedAt[parent.getCreatedAt()] else {
                break
            }

            pairForLoop = parentPair
        }

        result.append(self.subPathPrefix)
        return result.reversed()
    }

    private func escapeSubpath(_ target: String) -> String {
        return [self.subPathPrefix, self.subPathSeparator].reduce(target) { partialResult, seq in
            partialResult.replacingOccurrences(of: seq, with: "\\\(seq)")
        }
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
        self.elementPairMapByCreatedAt[element.getCreatedAt()] = (element, parent)
    }

    /**
     * `deregisterElement` deregister the given element from hash table.
     */
    func deregisterElement(_ element: CRDTElement) {
        self.elementPairMapByCreatedAt[element.getCreatedAt()] = nil
        self.removedElementSetByCreatedAt.remove(element.getCreatedAt())
    }

    /**
     * `registerRemovedElement` registers the given element to hash table.
     */
    func registerRemovedElement(_ element: CRDTElement) {
        self.removedElementSetByCreatedAt.insert(element.getCreatedAt())
    }

    /**
     * `registerTextWithGarbage` registers the given text to hash set.
     */
    func registerTextWithGarbage(text: CRDTTextElement) {
        self.textWithGarbageSetByCreatedAt.insert(text.getCreatedAt())
    }

    /**
     * `getElementMapSize` returns the size of element map.
     */
    func getElementMapSize() -> Int {
        return self.elementPairMapByCreatedAt.count
    }

    /**
     * `getRemovedElementSetSize()` returns the size of removed element set.
     */
    func getRemovedElementSetSize() -> Int {
        return self.removedElementSetByCreatedAt.count
    }

    /**
     * `getObject` returns root object.
     */
    func getObject() -> CRDTObject {
        return self.rootObject
    }

    /**
     * `getGarbageLength` returns length of nodes which should garbage collection task
     */
    func getGarbageLength() -> Int {
        var count = 0

        self.removedElementSetByCreatedAt.forEach {
            count += 1
            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let element = pair.element as? CRDTContainer
            else {
                return
            }

            element.getDescendants { _, _ in
                count += 1
                return false
            }
        }

        self.textWithGarbageSetByCreatedAt.forEach {
            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let text = pair.element as? CRDTTextElement
            else {
                return
            }

            count += text.getRemovedNodesLength()
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
                  let removedAt = pair.element.getRemovedAt(), removedAt <= ticket
            else {
                return
            }

            try? pair.parent?.delete(element: pair.element)
            count += self.garbageCollectInternal(element: pair.element)
        }

        self.textWithGarbageSetByCreatedAt.forEach {
            guard let pair = self.elementPairMapByCreatedAt[$0],
                  let text = pair.element as? CRDTTextElement
            else {
                return
            }

            let removedNodeCount = text.purgeTextNodesWithGarbage(ticket: ticket)
            guard removedNodeCount > 0 else {
                return
            }

            self.textWithGarbageSetByCreatedAt.remove(text.getCreatedAt())
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
