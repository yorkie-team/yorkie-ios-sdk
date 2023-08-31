/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

import Foundation

/**
 * `TreeNode` represents the JSON representation of a node in the tree.
 * It is used to serialize and deserialize the tree.
 */
public struct TreeNode: Equatable {
    let type: TreeNodeType
    var children: [TreeNode]?
    var value: String?
    var attributes: [String: String]?

    var toJSONString: String {
        if self.type == DefaultTreeNodeType.text.rawValue {
            let valueString = self.value ?? ""

            return "{\"type\":\"\(self.type)\",\"value\":\"\(valueString)\"}"
        } else {
            var childrenString = ""
            if let children, children.isEmpty == false {
                childrenString = children.compactMap { $0.toJSONString }.joined(separator: ",")
            }

            var resultString = "{\"type\":\"\(self.type)\",\"children\":[\(childrenString)]"

            if let attributes, attributes.isEmpty == false {
                let sortedKeys = attributes.keys.sorted()

                let attrsString = sortedKeys.compactMap { key in
                    if let value = attributes[key] {
                        return "\"\(key)\":\(value)"
                    } else {
                        return nil
                    }
                }.joined(separator: ",")

                resultString += ",\"attributes\":{\(attrsString)}"
            }

            resultString += "}"

            return resultString
        }
    }
}

/**
 * `TreeNodeForTest` represents the JSON representation of a node in the tree.
 * It is used for testing.
 */
struct TreeNodeForTest: Codable {
    let type: TreeNodeType
    var children: [TreeNodeForTest]?
    var value: String?
    var attributes: [String: String]?
    var size: Int
    var isRemoved: Bool
}

/**
 * `TreeChangeType` represents the type of change in the tree.
 */
enum TreeChangeType {
    case content
    case style
}

enum TreeChangeValue {
    case nodes([TreeNode])
    case attributes([String: String])
}

/**
 * `TreeChange` represents the change in the tree.
 */
struct TreeChange {
    let actor: ActorID
    let type: TreeChangeType
    let from: Int
    let to: Int
    let fromPath: [Int]
    let toPath: [Int]
    let value: TreeChangeValue?
}

/**
 * `CRDTTreePos` represent a position in the tree. It indicates the virtual
 * location in the tree, so whether the node is splitted or not, we can find
 * the adjacent node to pos by calling `map.floorEntry()`.
 */
struct CRDTTreePos: Equatable, Comparable {
    /**
     * `initial` is the initial position of the tree.
     */
    public static let initial = CRDTTreePos(createdAt: .initial, offset: 0)

    /**
     * `createdAt` is the creation time of the node.
     */
    let createdAt: TimeTicket

    /**
     * `offset` is the distance from the beginning of the node if the node is
     * split.
     */
    let offset: Int32

    /**
     * `toIDString` returns a string that can be used as an ID for this position.
     */
    var toIDString: String {
        "\(self.createdAt.toIDString):\(self.offset)"
    }

    static func < (lhs: CRDTTreePos, rhs: CRDTTreePos) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.offset < rhs.offset
        } else {
            return lhs.createdAt < rhs.createdAt
        }
    }
}

extension CRDTTreePos {
    /**
     * `fromStruct` creates a new instance of RGATreeSplitPos from the given struct.
     */
    static func fromStruct(_ value: CRDTTreePosStruct) throws -> CRDTTreePos {
        try CRDTTreePos(createdAt: TimeTicket.fromStruct(value.createdAt), offset: value.offset)
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: CRDTTreePosStruct {
        CRDTTreePosStruct(createdAt: self.createdAt.toStruct, offset: self.offset)
    }
}

/**
 * `CRDTTreePosStruct` represents the structure of CRDTTreePos.
 * It is used to serialize and deserialize the CRDTTreePos.
 */
struct CRDTTreePosStruct {
    let createdAt: TimeTicketStruct
    let offset: Int32
}

/**
 * `TreePosRange` represents a pair of CRDTTreePos.
 */
typealias TreePosRange = (CRDTTreePos, CRDTTreePos)

/**
 * `TreePosStructRange` represents a pair of CRDTTreePosStruct.
 */
typealias TreePosStructRange = (CRDTTreePosStruct, CRDTTreePosStruct)

/**
 * `CRDTTreeNode` is a node of CRDTTree. It is includes the logical clock and
 * links to other nodes to resolve conflicts.
 */
final class CRDTTreeNode: IndexTreeNode {
    var size: Int
    var parent: CRDTTreeNode?
    var type: TreeNodeType
    var value: String {
        get {
            if self.isText == false {
                fatalError("cannot get value of element node: \(self.type)")
            }

            return self.innerValue
        }

        set {
            if self.isText == false {
                fatalError("cannot set value of element node: \(self.type)")
            }

            self.innerValue = newValue
            self.size = newValue.count
        }
    }

    var innerValue: String

    var innerChildren: [CRDTTreeNode]

    let pos: CRDTTreePos
    var removedAt: TimeTicket?
    var attrs: RHT?

    /**
     * `next` is the next node of this node in the list.
     */
    var next: CRDTTreeNode?

    /**
     * `prev` is the previous node of this node in the list.
     */
    var prev: CRDTTreeNode?

    /**
     * `insPrev` is the previous node of this node after the node is split.
     */
    var insPrev: CRDTTreeNode?

    init(pos: CRDTTreePos, type: TreeNodeType, value: String? = nil, children: [CRDTTreeNode]? = nil, attributes: RHT? = nil) {
        self.size = 0
        self.innerValue = ""
        self.parent = nil

        self.pos = pos
        self.type = type
        self.innerChildren = children ?? []
        self.attrs = attributes

        if let value {
            self.value = value
        }

        if type == DefaultTreeNodeType.text.rawValue, self.innerChildren.isEmpty == false {
            fatalError("Text node cannot have children: \(self.type)")
        }
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTTreeNode? {
        let clone = CRDTTreeNode(pos: self.pos, type: self.type)

        clone.removedAt = self.removedAt
        clone.size = self.size
        if self.type == DefaultTreeNodeType.text.rawValue {
            clone.value = self.value
        }
        clone.attrs = self.attrs
        clone.innerChildren = self.innerChildren.compactMap { child in
            let childClone = child.deepcopy()
            childClone?.parent = clone

            return childClone
        }

        return clone
    }

    /**
     * `isRemoved` returns whether the node is removed or not.
     */
    public var isRemoved: Bool {
        self.removedAt != nil
    }

    /**
     * `remove` marks the node as removed.
     */
    func remove(_ removedAt: TimeTicket) {
        let alived = !self.isRemoved

        if self.removedAt == nil || removedAt <= self.removedAt! {
            self.removedAt = removedAt
        }

        if alived {
            self.updateAncestorsSize()
        }
    }

    /**
     * `clone` clones this node with the given offset.
     */
    func clone(offset: Int32) -> CRDTTreeNode {
        CRDTTreeNode(pos: CRDTTreePos(createdAt: self.pos.createdAt, offset: offset), type: self.type)
    }

    /**
     * `createdAt` returns the creation time of this element.
     */
    var createdAt: TimeTicket {
        self.pos.createdAt
    }

    /**
     * toJSON converts the given CRDTNode to JSON.
     */
    var toJSON: TreeNode {
        if self.isText {
            return TreeNode(type: self.type, value: self.value)
        }

        let children = self.children.compactMap {
            $0.toJSON
        }

        let attrs = self.attrs?.toObject().mapValues { $0.value }

        return TreeNode(type: self.type, children: children, attributes: attrs)
    }

    /**
     * toXML converts the given CRDTNode to XML string.
     */
    static func toXML(node: CRDTTreeNode) -> String {
        if node.isText {
            return node.value
        }

        var xml = "<\(node.type)"
        if let attrs = node.attrs?.toObject() {
            attrs.keys.sorted().forEach {
                if let value = attrs[$0]?.value {
                    xml += " \($0)=\(value)"
                }
            }
        }
        xml += ">"

        let childrenXML = node.children.compactMap { self.toXML(node: $0) }.joined()

        xml += childrenXML
        xml += "</\(node.type)>"

        return xml
    }

    /**
     * `toTestTreeNode` converts the given CRDTNode JSON for debugging.
     */
    static func toTestTreeNode(_ node: CRDTTreeNode) -> TreeNodeForTest {
        if node.isText {
            return TreeNodeForTest(type: node.type,
                                   value: node.value,
                                   size: node.size,
                                   isRemoved: node.isRemoved)
        } else {
            return TreeNodeForTest(type: node.type,
                                   children: node.children.map { self.toTestTreeNode($0) },
                                   size: node.size,
                                   isRemoved: node.isRemoved)
        }
    }

    var toJSONTreeNode: any JSONTreeNode {
        if self.isText {
            return JSONTreeTextNode(value: self.value)
        } else {
            var attrs = [String: String]()
            self.attrs?.forEach {
                attrs[$0.key] = $0.value
            }

            return JSONTreeElementNode(type: self.type,
                                       attributes: attrs.anyValueTypeDictionary,
                                       children: self.children.compactMap { $0.toJSONTreeNode })
        }
    }
}

/**
 * `CRDTTree` is a CRDT implementation of a tree.
 */
class CRDTTree: CRDTGCElement {
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    private var dummyHead: CRDTTreeNode
    private(set) var indexTree: IndexTree<CRDTTreeNode>
    private var nodeMapByPos: LLRBTree<CRDTTreePos, CRDTTreeNode>
    private var removedNodeMap: [String: CRDTTreeNode]

    init(root: CRDTTreeNode, createdAt: TimeTicket) {
        self.createdAt = createdAt
        self.dummyHead = CRDTTreeNode(pos: CRDTTreePos.initial, type: DefaultTreeNodeType.dummy.rawValue)
        self.indexTree = IndexTree(root: root)
        self.nodeMapByPos = LLRBTree()
        self.removedNodeMap = [String: CRDTTreeNode]()

        var previous = self.dummyHead
        self.indexTree.traverse { node, _ in
            self.insertAfter(previous, node)
            previous = node
        }
    }

    /**
     * `nodesBetweenByTree` returns the nodes between the given range.
     */
    func nodesBetweenByTree(_ from: Int, _ to: Int, _ callback: @escaping (CRDTTreeNode) -> Void) throws {
        try self.indexTree.nodesBetween(from, to, callback)
    }

    /**
     * `nodesBetween` returns the nodes between the given range.
     * This method includes the given left node but excludes the given right node.
     */
    func nodesBetween(_ left: CRDTTreeNode, _ right: CRDTTreeNode, _ callback: @escaping (CRDTTreeNode) -> Void) throws {
        var current: CRDTTreeNode? = left
        while current !== right {
            if current == nil {
                throw YorkieError.unexpected(message: "left and right are not in the same list")
            }

            callback(current!)
            current = current?.next
        }
    }

    /**
     * `findPostorderRight` finds the right node of the given index in postorder.
     */
    func findPostorderRight(_ index: Int) -> CRDTTreeNode? {
        guard let pos = try? self.indexTree.findTreePos(index, true) else {
            return nil
        }

        return self.indexTree.findPostorderRight(pos)
    }

    /**
     * `findTreePos` finds `TreePos` of the given `CRDTTreePos`
     */
    func findTreePos(_ pos: CRDTTreePos, _ editedAt: TimeTicket) throws -> (TreePos<CRDTTreeNode>, CRDTTreeNode) {
        guard let treePos = self.toTreePos(pos) else {
            throw YorkieError.unexpected(message: "cannot find node at \(pos)")
        }

        // Find the appropriate position. This logic is similar to the logical to
        // handle the same position insertion of RGA.
        var current = treePos
        while current.node.next?.pos.createdAt.after(editedAt) ?? false, current.node.parent === current.node.next?.parent {
            current = TreePos(node: current.node.next!, offset: Int32(current.node.next!.size))
        }

        let right = self.indexTree.findPostorderRight(treePos)
        return (current, right)
    }

    /**
     * `findTreePosWithSplitText` finds `TreePos` of the given `CRDTTreePos` and
     * splits the text node if necessary.
     *
     * `CRDTTreePos` is a position in the CRDT perspective. This is
     * different from `TreePos` which is a position of the tree in the local
     * perspective.
     */
    func findTreePosWithSplitText(_ pos: CRDTTreePos, _ editedAt: TimeTicket) throws -> (TreePos<CRDTTreeNode>, CRDTTreeNode) {
        guard let treePos = self.toTreePos(pos) else {
            throw YorkieError.unexpected(message: "cannot find node at \(pos)")
        }

        // Find the appropriate position. This logic is similar to the logical to
        // handle the same position insertion of RGA.
        var current = treePos
        while current.node.next?.pos.createdAt.after(editedAt) ?? false, current.node.parent === current.node.next?.parent {
            current = TreePos(node: current.node.next!, offset: Int32(current.node.next!.size))
        }

        if current.node.isText {
            let split = try current.node.split(current.offset)
            if split != nil {
                self.insertAfter(current.node, split!)
                split?.insPrev = current.node
            }
        }

        let right = self.indexTree.findPostorderRight(treePos)
        return (current, right)
    }

    /**
     * `insertAfter` inserts the given node after the given previous node.
     */
    func insertAfter(_ prevNode: CRDTTreeNode, _ newNode: CRDTTreeNode) {
        let next = prevNode.next
        prevNode.next = newNode
        newNode.prev = prevNode
        if next != nil {
            newNode.next = next
            next!.prev = newNode
        }

        self.nodeMapByPos.put(newNode.pos, newNode)
    }

    /**
     * `style` applies the given attributes of the given range.
     */
    @discardableResult
    func style(_ range: TreePosRange, _ attributes: [String: String]?, _ editedAt: TimeTicket) throws -> [TreeChange] {
        let (_, toRight) = try self.findTreePos(range.1, editedAt)
        let (_, fromRight) = try self.findTreePos(range.0, editedAt)
        var changes: [TreeChange] = []

        guard let actorID = editedAt.actorID else {
            throw YorkieError.unexpected(message: "No actor ID.")
        }

        var value: TreeChangeValue?

        if let attributes {
            value = .attributes(attributes)
        }

        try changes.append(TreeChange(actor: actorID,
                                      type: .style,
                                      from: self.toIndex(range.0),
                                      to: self.toIndex(range.1),
                                      fromPath: self.indexTree.indexToPath(self.posToStartIndex(range.0)),
                                      toPath: self.indexTree.indexToPath(self.posToStartIndex(range.0)),
                                      value: value)
        )

        try self.nodesBetween(fromRight, toRight) { node in
            if !node.isRemoved, let attributes {
                if node.attrs == nil {
                    node.attrs = RHT()
                }

                for (key, value) in attributes {
                    node.attrs?.set(key: key, value: value, executedAt: editedAt)
                }
            }
        }

        return changes
    }

    /**
     * `edit` edits the tree with the given range and content.
     * If the content is undefined, the range will be removed.
     */
    @discardableResult
    func edit(_ range: TreePosRange, _ contents: [CRDTTreeNode]?, _ editedAt: TimeTicket) throws -> [TreeChange] {
        // 01. split text nodes at the given range if needed.
        let (toPos, toRight) = try self.findTreePosWithSplitText(range.1, editedAt)
        let (fromPos, fromRight) = try self.findTreePosWithSplitText(range.0, editedAt)

        // TODO(hackerwins): If concurrent deletion happens, we need to seperate the
        // range(from, to) into multiple ranges.
        var changes = [TreeChange]()

        guard let actorID = editedAt.actorID else {
            throw YorkieError.unexpected(message: "No actor ID.")
        }

        var value: TreeChangeValue?

        if let nodes = contents?.compactMap({ $0.toJSON }) {
            value = .nodes(nodes)
        }

        try changes.append(TreeChange(actor: actorID,
                                      type: .content,
                                      from: self.toIndex(range.0),
                                      to: self.toIndex(range.1),
                                      fromPath: self.indexTree.treePosToPath(fromPos),
                                      toPath: self.indexTree.treePosToPath(toPos),
                                      value: value)
        )

        var toBeRemoveds = [CRDTTreeNode]()
        // 02. remove the nodes and update linked list and index tree.
        if fromRight !== toRight {
            try self.nodesBetween(fromRight, toRight) { node in
                if node.isRemoved == false {
                    toBeRemoveds.append(node)
                }
            }

            let isRangeOnSameBranch = toPos.node.isAncestorOf(node: fromPos.node)
            toBeRemoveds.forEach { node in
                node.remove(editedAt)

                if node.isRemoved {
                    self.removedNodeMap[node.pos.toIDString] = node
                }
            }

            // move the alive children of the removed element node
            if isRangeOnSameBranch {
                var removedElementNode: CRDTTreeNode?
                if fromPos.node.parent?.isRemoved ?? false {
                    removedElementNode = fromPos.node.parent
                } else if !fromPos.node.isText, fromPos.node.isRemoved {
                    removedElementNode = fromPos.node
                }

                // If the nearest removed element node of the fromNode is found,
                // insert the alive children of the removed element node to the toNode.
                if removedElementNode != nil {
                    let elementNode = toPos.node
                    let offset = try elementNode.findBranchOffset(node: removedElementNode!)
                    try removedElementNode?.children.reversed().forEach { node in
                        try elementNode.insertAt(node, offset)
                    }
                }
            } else {
                if fromPos.node.parent?.isRemoved ?? false {
                    try toPos.node.parent?.prepend(contentsOf: fromPos.node.parent?.children ?? [])
                }
            }
        }

        // 03. insert the given node at the given position.
        if let contents, contents.isEmpty == false {
            // 03-1. insert the content nodes to the list.
            var previous = fromRight.prev
            let node = fromPos.node
            var offset = Int(fromPos.offset)

            for content in contents {
                traverse(node: content) { node, _ in
                    self.insertAfter(previous!, node)
                    previous = node
                }

                // 03-2. insert the content nodes to the tree.
                if node.isText {
                    if fromPos.offset == 0 {
                        try node.parent!.insertBefore(content, node)
                    } else {
                        try node.parent!.insertAfter(content, node)
                    }
                } else {
                    try node.insertAt(content, offset)
                    offset += 1
                }
            }
        }

        return changes
    }

    /**
     * `editByIndex` edits the given range with the given value.
     * This method uses indexes instead of a pair of TreePos for testing.
     */
    func editByIndex(_ range: (Int, Int), _ contents: [CRDTTreeNode]?, _ editedAt: TimeTicket) throws {
        let fromPos = try self.findPos(range.0)
        let toPos = try self.findPos(range.1)
        try self.edit((fromPos, toPos), contents, editedAt)
    }

    /**
     * `split` splits the node at the given index.
     */
    @discardableResult
    func split(_ index: Int, _ depth: Int = 1) throws -> TreePos<CRDTTreeNode> {
        // TODO(hackerwins, easylogic): Implement this with keeping references in the list.
        // return this.treeByIndex.split(index, depth);
        throw YorkieError.unimplemented(message: "not implemented, \(index) \(depth)")
    }

    /**
     * `move` move the given source range to the given target range.
     */
    func move(_ target: (Int, Int), _ source: (Int, Int), _ ticket: TimeTicket) throws {
        // TODO(hackerwins, easylogic): Implement this with keeping references of the nodes.
        throw YorkieError.unimplemented(message: "not implemented, \(target), \(source) \(ticket)")
    }

    /**
     * `removedNodesLen` returns length of removed nodes
     */
    var removedNodesLength: Int {
        self.removedNodeMap.count
    }

    /**
     * `purgeRemovedNodesBefore` physically purges nodes that have been removed.
     */
    func purgeRemovedNodesBefore(ticket: TimeTicket) -> Int {
        var nodesToBeRemoved = [CRDTTreeNode]()
        var count = 0

        self.removedNodeMap.forEach { _, node in
            if node.removedAt != nil, ticket >= node.removedAt! {
                nodesToBeRemoved.append(node)
                count += 1
            }
        }

        nodesToBeRemoved.forEach { node in
            do {
                try node.parent?.removeChild(child: node)
            } catch {
                assertionFailure("Can't remove Child from parents.")
            }
            self.nodeMapByPos.remove(node.pos)
            self.purge(node)
            self.removedNodeMap.removeValue(forKey: node.pos.toIDString)
        }

        return count
    }

    /**
     * `purge` physically purges the given node from RGATreeSplit.
     */
    func purge(_ node: CRDTTreeNode) {
        let prev = node.prev
        let next = node.next

        if prev != nil {
            prev?.next = next
        }
        if next != nil {
            next?.prev = prev
        }

        node.prev = nil
        node.next = nil
        node.insPrev = nil
    }

    /**
     * `findPos` finds the position of the given index in the tree.
     */
    func findPos(_ index: Int, _ preferText: Bool = true) throws -> CRDTTreePos {
        let treePos = try self.indexTree.findTreePos(index, preferText)

        return CRDTTreePos(createdAt: treePos.node.pos.createdAt, offset: treePos.node.pos.offset + treePos.offset)
    }

    /**
     * `removedNodesLen` returns size of removed nodes.
     */
    var removedNodesLen: Int {
        self.removedNodeMap.count
    }

    /**
     * `posToStartIndex` returns start index of pos
     *       0   1   2 3 4 5 6    7  8
     *  <doc><p><tn>t e x t </tn></p></doc>
     *  if tree is just like above, and the pos is pointing index of 7
     * this returns 0 (start index of tag)
     */
    func posToStartIndex(_ pos: CRDTTreePos) throws -> Int {
        guard let treePos = self.toTreePos(pos) else {
            throw YorkieError.unexpected(message: "Can't get treePos.")
        }
        let index = try self.toIndex(pos)
        var size = treePos.node.size

        if treePos.node.isText {
            guard let parent = treePos.node.parent else {
                throw YorkieError.unexpected(message: "Can't get parent.")
            }
            size = parent.size
        }

        return index - size - 1
    }

    /**
     * `pathToPosRange` converts the given path of the node to the range of the position.
     */
    func pathToPosRange(_ path: [Int]) throws -> TreePosRange {
        let index = try self.pathToIndex(path)
        let pos = try self.pathToTreePos(path)
        let parentNode = pos.node
        let offset = Int(pos.offset)

        if parentNode.hasTextChild {
            throw YorkieError.unexpected(message: "invalid Path")
        }
        let node = parentNode.children[offset]
        let fromIdx = index + node.size + 1

        return try (self.findPos(fromIdx), self.findPos(fromIdx + 1))
    }

    /**
     * `pathToTreePos` finds the tree position path.
     */
    func pathToTreePos(_ path: [Int]) throws -> TreePos<CRDTTreeNode> {
        try self.indexTree.pathToTreePos(path)
    }

    /**
     * `pathToPos` finds the position of the given index in the tree by path.
     */
    func pathToPos(_ path: [Int]) throws -> CRDTTreePos {
        let treePos = try self.indexTree.pathToTreePos(path)

        return CRDTTreePos(createdAt: treePos.node.pos.createdAt, offset: treePos.node.pos.offset + treePos.offset)
    }

    /**
     * `root` returns the root node of the tree.
     */
    var root: CRDTTreeNode {
        self.indexTree.root
    }

    /**
     * `size` returns the size of the tree.
     */
    var size: Int {
        self.indexTree.size
    }

    /**
     * toXML returns the XML encoding of this tree.
     */
    func toXML() -> String {
        CRDTTreeNode.toXML(node: self.indexTree.root)
    }

    /**
     * `toJSON` returns the JSON encoding of this tree.
     */
    func toJSON() -> String {
        self.indexTree.root.toJSON.toJSONString
    }

    /**
     * `toTestTreeNode` returns the JSON of this tree for debugging.
     */
    func toTestTreeNode() -> TreeNodeForTest {
        CRDTTreeNode.toTestTreeNode(self.indexTree.root)
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this tree.
     */
    func toSortedJSON() -> String {
        self.toJSON()
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTElement {
        let tree = CRDTTree(root: root.deepcopy()!, createdAt: self.createdAt)

        return tree
    }

    /**
     * `toIndex` converts the given CRDTTreePos to the index of the tree.
     */
    func toIndex(_ pos: CRDTTreePos) throws -> Int {
        guard let treePos = self.toTreePos(pos) else {
            return -1
        }

        return try self.indexTree.indexOf(treePos)
    }

    /**
     * `toTreePos` converts the given CRDTTreePos to TreePos<CRDTTreeNode>.
     */
    func toTreePos(_ pos: CRDTTreePos) -> TreePos<CRDTTreeNode>? {
        let entry = self.nodeMapByPos.floorEntry(pos)
        if entry == nil || pos.createdAt != entry?.key.createdAt {
            return nil
        }

        // Choose the left node if the position is on the boundary of the split nodes.
        var node = entry?.value
        if pos.offset > 0, pos.offset == node?.pos.offset, node?.insPrev != nil {
            node = node?.insPrev
        }

        return TreePos(node: node!, offset: pos.offset - node!.pos.offset)
    }

    /**
     * `indexToPath` converts the given tree index to path.
     */
    func indexToPath(_ index: Int) throws -> [Int] {
        try self.indexTree.indexToPath(index)
    }

    /**
     * `pathToIndex` converts the given path to index.
     */
    func pathToIndex(_ path: [Int]) throws -> Int {
        try self.indexTree.pathToIndex(path)
    }

    /**
     * `indexRangeToPosRange` returns the position range from the given index range.
     */
    func indexRangeToPosRange(_ range: (Int, Int)) throws -> TreePosRange {
        let fromPos = try self.findPos(range.0)
        if range.0 == range.1 {
            return (fromPos, fromPos)
        }

        return try (fromPos, self.findPos(range.1))
    }

    /**
     * `indexRangeToPosStructRange` converts the integer index range into the Tree position range structure.
     */
    func indexRangeToPosStructRange(_ range: (Int, Int)) throws -> TreePosStructRange {
        let (fromIdx, toIdx) = range
        let fromPos = try self.findPos(fromIdx).toStruct
        if fromIdx == toIdx {
            return (fromPos, fromPos)
        }

        return try (fromPos, self.findPos(toIdx).toStruct)
    }

    /**
     * `posRangeToPathRange` converts the given position range to the path range.
     */
    func posRangeToPathRange(_ range: TreePosRange) throws -> ([Int], [Int]) {
        let fromPath = try self.indexTree.indexToPath(self.toIndex(range.0))
        let toPath = try self.indexTree.indexToPath(self.toIndex(range.1))

        return (fromPath, toPath)
    }

    /**
     * `toBytes` creates an array representing the value.
     */
    func toBytes() -> Data {
        return Data()
    }
}

extension CRDTTree: Sequence {
    func makeIterator() -> CRDTTreeListIterator {
        return CRDTTreeListIterator(self.dummyHead.next)
    }
}

class CRDTTreeListIterator: IteratorProtocol {
    private weak var iteratorNext: CRDTTreeNode?

    init(_ firstNode: CRDTTreeNode?) {
        self.iteratorNext = firstNode
    }

    func next() -> CRDTTreeNode? {
        while let result = self.iteratorNext {
            self.iteratorNext = result.next
            if result.isRemoved == false {
                return result
            }
        }

        return nil
    }
}
