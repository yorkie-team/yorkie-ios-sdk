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
 * `CRDTTreePos` represent a position in the tree. It is used to identify a
 * position in the tree. It is composed of the parent ID and the left sibling
 * ID. If there's no left sibling in parent's children, then left sibling is
 * parent.
 */
struct CRDTTreePos: Equatable {
    let parentID: CRDTTreeNodeID
    let leftSiblingID: CRDTTreeNodeID
}

extension CRDTTreePos {
    /**
     * `fromStruct` creates a new instance of CRDTTreePos from the given struct.
     */
    static func fromStruct(_ value: CRDTTreePosStruct) throws -> CRDTTreePos {
        try CRDTTreePos(parentID: CRDTTreeNodeID.fromStruct(value.parentID), leftSiblingID: CRDTTreeNodeID.fromStruct(value.leftSiblingID))
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: CRDTTreePosStruct {
        CRDTTreePosStruct(parentID: self.parentID.toStruct, leftSiblingID: self.leftSiblingID.toStruct)
    }
}

/**
 * `CRDTTreeNodeID` represent a position in the tree. It indicates the virtual
 * location in the tree, so whether the node is splitted or not, we can find
 * the adjacent node to pos by calling `map.floorEntry()`.
 */
struct CRDTTreeNodeID: Equatable, Comparable {
    /**
     * `initial` is the initial position of the tree.
     */
    public static let initial = CRDTTreeNodeID(createdAt: .initial, offset: 0)

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

    static func < (lhs: CRDTTreeNodeID, rhs: CRDTTreeNodeID) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.offset < rhs.offset
        } else {
            return lhs.createdAt < rhs.createdAt
        }
    }

    static func == (lhs: CRDTTreeNodeID, rhs: CRDTTreeNodeID) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.offset == rhs.offset
    }
}

extension CRDTTreeNodeID {
    /**
     * `fromStruct` creates a new instance of CRDTTreeNodeID from the given struct.
     */
    static func fromStruct(_ value: CRDTTreeNodeIDStruct) throws -> CRDTTreeNodeID {
        try CRDTTreeNodeID(createdAt: TimeTicket.fromStruct(value.createdAt), offset: value.offset)
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: CRDTTreeNodeIDStruct {
        CRDTTreeNodeIDStruct(createdAt: self.createdAt.toStruct, offset: self.offset)
    }
}

/**
 * `CRDTTreePosStruct` represents the structure of CRDTTreePos.
 */
struct CRDTTreePosStruct {
    let parentID: CRDTTreeNodeIDStruct
    let leftSiblingID: CRDTTreeNodeIDStruct
}

/**
 * `CRDTTreeNodeIDStruct` represents the structure of CRDTTreePos.
 * It is used to serialize and deserialize the CRDTTreePos.
 */
struct CRDTTreeNodeIDStruct {
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

    let id: CRDTTreeNodeID
    var removedAt: TimeTicket?
    var attrs: RHT?

    /**
     * `insPrevID` is the previous node of this node in the list.
     */
    var insPrevID: CRDTTreeNodeID?

    /**
     * `insNextID` is the previous node of this node after the node is split.
     */
    var insNextID: CRDTTreeNodeID?

    init(id: CRDTTreeNodeID, type: TreeNodeType, value: String? = nil, children: [CRDTTreeNode]? = nil, attributes: RHT? = nil) {
        self.size = 0
        self.innerValue = ""
        self.parent = nil

        self.id = id
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
        let clone = CRDTTreeNode(id: self.id, type: self.type)

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
        let clone = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.id.createdAt, offset: offset), type: self.type, attributes:  self.attrs)
        clone.removedAt = self.removedAt
        clone.value = self.value
        clone.size = self.size
        clone.innerChildren = self.innerChildren.compactMap {
            let childClone = $0.deepcopy()
            childClone?.parent = clone
            
            return childClone
        }
        
        return clone
    }

    /**
     * `createdAt` returns the creation time of this element.
     */
    var createdAt: TimeTicket {
        self.id.createdAt
    }

    /**
     * `offset` returns the offset of a pos.
     */
    var offset: Int32 {
        self.id.offset
    }

    /**
     * `canDelete` checks if node is able to delete.
     */
    func canDelete(_ editedAt: TimeTicket, _ latestCreatedAt: TimeTicket) -> Bool {
        !self.createdAt.after(latestCreatedAt) && (self.removedAt == nil || editedAt.after(self.removedAt!))
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
                    if value.first == "\"", value.last == "\"" {
                        xml += " \($0)=\(value)"
                    } else {
                        xml += " \($0)=\"\(value)\""
                    }
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

    private(set) var indexTree: IndexTree<CRDTTreeNode>
    private var nodeMapByID: LLRBTree<CRDTTreeNodeID, CRDTTreeNode>
    private var removedNodeMap: [String: CRDTTreeNode]

    init(root: CRDTTreeNode, createdAt: TimeTicket) {
        self.createdAt = createdAt
        self.indexTree = IndexTree(root: root)
        self.nodeMapByID = LLRBTree()
        self.removedNodeMap = [String: CRDTTreeNode]()

        self.indexTree.traverse { node, _ in
            self.nodeMapByID.put(node.id, node)
        }
    }

    /**
     * `findFloorNode` finds node of given id.
     */
    private func findFloorNode(_ id: CRDTTreeNodeID) -> CRDTTreeNode? {
        guard let entry = self.nodeMapByID.floorEntry(id), entry.key.createdAt == id.createdAt else {
            return nil
        }

        return entry.value
    }

    /**
     * `findNodesAndSplitText` finds `TreePos` of the given `CRDTTreeNodeID` and
     * splits the text node if necessary.
     *
     * `CRDTTreeNodeID` is a position in the CRDT perspective. This is
     * different from `TreePos` which is a position of the tree in the local
     * perspective.
     */
    func findNodesAndSplitText(_ pos: CRDTTreePos, _ editedAt: TimeTicket) throws -> (CRDTTreeNode, CRDTTreeNode) {
        guard let treeNodes = self.toTreeNodes(pos) else {
            throw YorkieError.unexpected(message: "cannot find node at \(pos)")
        }

        let parentNode = treeNodes.0
        var leftSiblingNode = treeNodes.1

        // Find the appropriate position. This logic is similar to the logical to
        // handle the same position insertion of RGA.

        if leftSiblingNode.isText {
            let absOffset = leftSiblingNode.id.offset
            if let split = try leftSiblingNode.split(pos.leftSiblingID.offset - absOffset, absOffset) {
                split.insPrevID = leftSiblingNode.id
                self.nodeMapByID.put(split.id, split)

                if let id = leftSiblingNode.insNextID {
                    let insNext = self.findFloorNode(id)

                    insNext?.insPrevID = split.id
                    split.insNextID = id
                }
                leftSiblingNode.insNextID = split.id
            }
        }

        var index = 0

        if parentNode !== leftSiblingNode {
            let firstIndex = parentNode.innerChildren.firstIndex(where: { $0 === leftSiblingNode }) ?? -1

            index = firstIndex + 1
        }

        if index <= parentNode.innerChildren.count {
            for idx in index ..< parentNode.innerChildren.count {
                let next = parentNode.innerChildren[idx]
                
                if next.id.createdAt.after(editedAt) {
                    leftSiblingNode = next
                } else {
                    break
                }
            }
        }

        return (parentNode, leftSiblingNode)
    }

    /**
     * `style` applies the given attributes of the given range.
     */
    @discardableResult
    func style(_ range: TreePosRange, _ attributes: [String: String]?, _ editedAt: TimeTicket) throws -> [TreeChange] {
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, editedAt)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, editedAt)
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
                                      from: self.toIndex(fromParent, fromLeft),
                                      to: self.toIndex(toParent, toLeft),
                                      fromPath: self.toPath(fromParent, fromLeft),
                                      toPath: self.toPath(toParent, toLeft),
                                      value: value)
        )

        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { node, _ in
            if node.isRemoved == false, node.isText == false, let attributes {
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
    func edit(_ range: TreePosRange, _ contents: [CRDTTreeNode]?, _ editedAt: TimeTicket, _ latestCreatedAtMapByActor: [String: TimeTicket] = [:]) throws -> ([TreeChange], [String: TimeTicket]) {
        // 01. split text nodes at the given range if needed.
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, editedAt)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, editedAt)

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
                                      from: self.toIndex(fromParent, fromLeft),
                                      to: self.toIndex(toParent, toLeft),
                                      fromPath: self.toPath(fromParent, fromLeft),
                                      toPath: self.toPath(toParent, toLeft),
                                      value: value)
        )

        var toBeRemoveds = [CRDTTreeNode]()
        var latestCreatedAtMap = [String: TimeTicket]()

        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { node, contain in
            // If node is a element node and half-contained in the range,
            // it should not be removed.
            if node.isText == false, contain != .all {
                return
            }
            
            guard let actorID = node.createdAt.actorID else {
                throw YorkieError.unexpected(message: "Can't get actorID")
            }
            
            let latestCreatedAt = latestCreatedAtMapByActor.isEmpty == false ? latestCreatedAtMapByActor[actorID] ?? TimeTicket.initial : TimeTicket.max
            
            if node.canDelete(editedAt, latestCreatedAt) {
                let latestCreatedAt = latestCreatedAtMap[actorID]
                let createdAt = node.createdAt
                
                if latestCreatedAt == nil || createdAt.after(latestCreatedAt!) {
                    latestCreatedAtMap[actorID] = createdAt
                }
                
                toBeRemoveds.append(node)
            }
        }

        for node in toBeRemoveds {
            node.remove(editedAt)

            if node.isRemoved {
                self.removedNodeMap[node.id.toIDString] = node
            }
        }

        // 03. insert the given node at the given position.
        if let contents, contents.isEmpty == false {
            var leftInChildren = fromLeft // tree

            for content in contents {
                // 03-1. insert the content nodes to the tree.
                if leftInChildren === fromParent {
                    // 03-1-1. when there's no leftSibling, then insert content into very fromt of parent's children List
                    try fromParent.insertAt(content, 0)
                } else {
                    // 03-1-2. insert after leftSibling
                    try fromParent.insertAfter(content, leftInChildren)
                }

                leftInChildren = content
                traverseAll(node: content) { node, _ in
                    // if insertion happens during concurrent editing and parent node has been removed,
                    // make new nodes as tombstone immediately
                    if fromParent.isRemoved {
                        node.remove(editedAt)

                        self.removedNodeMap[node.id.toIDString] = node
                    }

                    self.nodeMapByID.put(node.id, node)
                }
            }
        }

        return (changes, latestCreatedAtMap)
    }

    private func traverseInPosRange(_ fromParent: CRDTTreeNode,
                                    _ fromLeft: CRDTTreeNode,
                                    _ toParent: CRDTTreeNode,
                                    _ toLeft: CRDTTreeNode,
                                    callback: @escaping (CRDTTreeNode, TagContained) throws -> Void) throws {
       let fromIdx = try self.toIndex(fromParent, fromLeft)
       let toIdx = try self.toIndex(toParent, toLeft)

       return try self.indexTree.nodesBetween(fromIdx, toIdx, callback)
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
            self.nodeMapByID.remove(node.id)
            self.purge(node)
            self.removedNodeMap.removeValue(forKey: node.id.toIDString)
        }

        return count
    }

    /**
     * `purge` physically purges the given node from RGATreeSplit.
     */
    func purge(_ node: CRDTTreeNode) {
        if let insPrevID = node.insPrevID {
            self.findFloorNode(insPrevID)?.insNextID = node.insNextID
        }
        if let insNextID = node.insNextID {
            self.findFloorNode(insNextID)?.insPrevID = node.insPrevID
        }

        node.insPrevID = nil
        node.insNextID = nil
    }

    /**
     * `findPos` finds the position of the given index in the tree.
     */
    func findPos(_ index: Int, _ preferText: Bool = true) throws -> CRDTTreePos {
        let treePos = try self.indexTree.findTreePos(index, preferText)

        let offset = treePos.offset
        var node = treePos.node
        var leftSibing: CRDTTreeNode

        if node.isText {
            if node.parent?.children[0] === node, offset == 0 {
                leftSibing = node.parent!
            } else {
                leftSibing = node
            }

            node = node.parent!
        } else {
            if offset == 0 {
                leftSibing = node
            } else {
                leftSibing = node.children[Int(offset) - 1]
            }
        }

        return CRDTTreePos(parentID: node.id, leftSiblingID: CRDTTreeNodeID(createdAt: leftSibing.createdAt, offset: leftSibing.offset + offset))
    }

    /**
     * `removedNodesLen` returns size of removed nodes.
     */
    var removedNodesLen: Int {
        self.removedNodeMap.count
    }

    /**
     * `pathToPosRange` converts the given path of the node to the range of the position.
     */
    func pathToPosRange(_ path: [Int]) throws -> TreePosRange {
        let fromIdx = try self.pathToIndex(path)

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
        let index = try self.indexTree.pathToIndex(path)

        return try self.findPos(index)
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
     * `toPath` converts the given CRDTTreeNodeID to the path of the tree.
     */
    private func toPath(_ parentNode: CRDTTreeNode, _ leftSiblingNode: CRDTTreeNode) throws -> [Int] {
        guard let treePos = try self.toTreePos(parentNode, leftSiblingNode) else {
            throw YorkieError.unexpected(message: "Can't find treePos")
        }

        return try self.indexTree.treePosToPath(treePos)
    }

    /**
     * `toIndex` converts the given CRDTTreeNodeID to the index of the tree.
     */
    func toIndex(_ parentNode: CRDTTreeNode, _ leftSiblingNode: CRDTTreeNode) throws -> Int {
        guard let treePos = try self.toTreePos(parentNode, leftSiblingNode) else {
            throw YorkieError.unexpected(message: "Can't find treePos")
        }

        return try self.indexTree.indexOf(treePos)
    }

    private func toTreeNodes(_ pos: CRDTTreePos) -> (CRDTTreeNode, CRDTTreeNode)? {
        let parentID = pos.parentID
        let leftSiblingID = pos.leftSiblingID
        guard let parentNode = self.findFloorNode(parentID),
              var leftSiblingNode = self.findFloorNode(leftSiblingID)
        else {
            return nil
        }

        if leftSiblingID.offset > 0,
           leftSiblingID.offset == leftSiblingNode.id.offset,
           leftSiblingNode.insPrevID != nil
        {
            leftSiblingNode = self.findFloorNode(leftSiblingNode.insPrevID!) ?? leftSiblingNode
        }

        return (parentNode, leftSiblingNode)
    }

    /**
     * `toTreePos` converts the given CRDTTreePos to local TreePos<CRDTTreeNode>.
     */
    private func toTreePos(_ parentNode: CRDTTreeNode, _ leftSiblingNode: CRDTTreeNode) throws -> TreePos<CRDTTreeNode>? {
        var treePos: TreePos<CRDTTreeNode>

        var parentNode = parentNode

        if parentNode.isRemoved {
            var childNode = parentNode
            while parentNode.isRemoved {
                childNode = parentNode
                parentNode = childNode.parent!
            }

            guard let childOffset = try parentNode.findOffset(node: childNode) else {
                throw YorkieError.unexpected(message: "Can't find Offset")
            }

            treePos = TreePos(node: parentNode, offset: Int32(childOffset))
        } else {
            if parentNode === leftSiblingNode {
                treePos = TreePos(node: parentNode, offset: 0)
            } else {
                guard var offset = try parentNode.findOffset(node: leftSiblingNode) else {
                    throw YorkieError.unexpected(message: "Can't find Offset")
                }

                if leftSiblingNode.isRemoved == false {
                    if leftSiblingNode.isText {
                        return TreePos(node: leftSiblingNode, offset: Int32(leftSiblingNode.paddedSize))
                    } else {
                        offset += 1
                    }
                }

                treePos = TreePos(node: parentNode, offset: Int32(offset))
            }
        }

        return treePos
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
    func posRangeToPathRange(_ range: TreePosRange, _ timeTicket: TimeTicket) throws -> ([Int], [Int]) {
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, timeTicket)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, timeTicket)

        return try (self.toPath(fromParent, fromLeft), self.toPath(toParent, toLeft))
    }

    /**
     * `posRangeToIndexRange` converts the given position range to the path range.
     */
    func posRangeToIndexRange(_ range: TreePosRange, _ timeTicket: TimeTicket) throws -> (Int, Int) {
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, timeTicket)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, timeTicket)

        return try (self.toIndex(fromParent, fromLeft), self.toIndex(toParent, toLeft))
    }

    /**
     * `toBytes` creates an array representing the value.
     */
    func toBytes() -> Data {
        return Data()
    }
}

/*
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
 */
