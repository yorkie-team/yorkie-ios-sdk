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
    case removeStyle
}

enum TreeChangeValue {
    case nodes([CRDTTreeNode])
    case attributes([String: String])
    case attributesToRemove([String])
}

/**
 * `TreeChange` represents the change in the tree.
 */
struct TreeChange {
    let actor: ActorID
    let type: TreeChangeType
    let from: Int
    var to: Int
    let fromPath: [Int]
    var toPath: [Int]
    var value: TreeChangeValue?
    let splitLevel: Int32
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
     * `fromTreePos` creates a new instance of CRDTTreePos from the given TreePos.
     */
    static func fromTreePos(pos: TreePos<CRDTTreeNode>) -> CRDTTreePos {
        let offset = Int(pos.offset)
        var node = pos.node
        var leftNode: CRDTTreeNode!

        if node.isText {
            if node.parent?.children[0] === node, offset == 0 {
                leftNode = node.parent
            } else {
                leftNode = node
            }

            node = node.parent!
        } else {
            if offset == 0 {
                leftNode = node
            } else {
                leftNode = node.children[offset - 1]
            }
        }

        return CRDTTreePos(parentID: node.id, leftSiblingID: CRDTTreeNodeID(createdAt: leftNode.createdAt, offset: leftNode.offset + Int32(offset)))
    }

    /**
     * `toTreeNodePair` converts the pos to parent and left sibling nodes.
     * If the position points to the middle of a node, then the left sibling node
     * is the node that contains the position. Otherwise, the left sibling node is
     * the node that is located at the left of the position.
     */
    func toTreeNodePair(tree: CRDTTree) throws -> TreeNodePair {
        let parentID = self.parentID
        let leftSiblingID = self.leftSiblingID
        let parentNode = tree.findFloorNode(parentID)
        let leftNode = tree.findFloorNode(leftSiblingID)
        guard let parentNode, var leftNode else {
            throw YorkieError(code: .errRefused, message: "cannot find node of CRDTTreePos(\(parentID.toTestString), \(leftSiblingID.toTestString))")
        }

        /**
         * NOTE(hackerwins): If the left node and the parent node are the same,
         * it means that the position is the left-most of the parent node.
         * We need to skip finding the left of the position.
         */
        if leftSiblingID != parentID,
           leftSiblingID.offset > 0,
           leftSiblingID.offset == leftNode.id.offset,
           let insPrevID = leftNode.insPrevID,
           let newLeftNode = tree.findFloorNode(insPrevID)
        {
            leftNode = newLeftNode
        }

        return (parentNode, leftNode)
    }

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

    /**
     * `toTestString` returns a string containing the meta data of the ticket
     * for debugging purpose.
     */
    var toTestString: String {
        "\(self.createdAt.toTestString)/\(self.offset)"
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
public struct CRDTTreePosStruct: Codable {
    let parentID: CRDTTreeNodeIDStruct
    let leftSiblingID: CRDTTreeNodeIDStruct
}

/**
 * `CRDTTreeNodeIDStruct` represents the structure of CRDTTreePos.
 * It is used to serialize and deserialize the CRDTTreePos.
 */
public struct CRDTTreeNodeIDStruct: Codable {
    let createdAt: TimeTicketStruct
    let offset: Int32
}

/**
 * `TreePosRange` represents a pair of CRDTTreePos.
 */
typealias TreePosRange = (CRDTTreePos, CRDTTreePos)

/**
 * `TreeNodePair` represents a pair of CRDTTreeNode. It represents the position
 * of the node in the tree with the left and parent nodes.
 */
typealias TreeNodePair = (CRDTTreeNode, CRDTTreeNode)

/**
 * `TreePosStructRange` represents a pair of CRDTTreePosStruct.
 */
public typealias TreePosStructRange = (CRDTTreePosStruct, CRDTTreePosStruct)

/**
 * `CRDTTreeNode` is a node of CRDTTree. It includes the logical clock and
 * links to other nodes to resolve conflicts.
 */
final class CRDTTreeNode: IndexTreeNode {
    var size: Int
    weak var parent: CRDTTreeNode?
    var type: TreeNodeType
    var value: NSString {
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
            // Yorkie use UTF16 for String.
            self.size = newValue.length
        }
    }

    var innerValue: NSString

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

    init(id: CRDTTreeNodeID, type: TreeNodeType, value: NSString? = nil, children: [CRDTTreeNode]? = nil, attributes: RHT? = nil, removedAt: TimeTicket? = nil) {
        self.size = 0
        self.innerValue = ""
        self.parent = nil

        self.id = id
        self.removedAt = removedAt
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
        clone.attrs = self.attrs?.deepcopy()
        clone.innerChildren = self.innerChildren.compactMap { child in
            let childClone = child.deepcopy()
            childClone?.parent = clone

            return childClone
        }
        clone.insPrevID = self.insPrevID
        clone.insNextID = self.insNextID

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
     * `cloneText` clones this text node with the given offset.
     */
    func cloneText(offset: Int32) -> CRDTTreeNode {
        CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.id.createdAt, offset: offset),
                     type: self.type,
                     removedAt: self.removedAt)
    }

    /**
     * `cloneElement` clones this element node with the given issueTimeTicket function.
     */
    func cloneElement(issueTimeTicket: TimeTicket) -> CRDTTreeNode {
        CRDTTreeNode(id: CRDTTreeNodeID(createdAt: issueTimeTicket, offset: 0),
                     type: self.type,
                     removedAt: self.removedAt)
    }

    /**
     * `split` splits the given offset of this node.
     */
    @discardableResult
    func split(_ tree: CRDTTree, _ offset: Int32, _ issueTimeTicket: TimeTicket? = nil) throws -> CRDTTreeNode? {
        if self.isText == false, issueTimeTicket == nil {
            throw YorkieError(code: .errInvalidArgument, message: "The issueTimeTicket for Text Node have to nil!")
        }

        let split = self.isText ? try self.splitText(offset, self.id.offset) : try self.splitElement(offset, issueTimeTicket!)

        if split != nil {
            split?.insPrevID = self.id
            if self.insNextID != nil {
                let insNext = tree.findFloorNode(self.insNextID!)
                insNext?.insPrevID = split?.id
                split?.insNextID = self.insNextID
            }
            self.insNextID = split?.id
            tree.registerNode(split!)
        }

        return split
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
    func canDelete(
        _ editedAt: TimeTicket,
        _ maxCreatedAt: TimeTicket?,
        _ clientLamportAtChange: Int64
    ) -> Bool {
        let nodeExisted: Bool
        if let maxCreatedAt = maxCreatedAt {
            nodeExisted = !self.createdAt.after(maxCreatedAt)
        } else {
            nodeExisted = self.createdAt.lamport <= clientLamportAtChange
        }

        return nodeExisted && (self.removedAt == nil || editedAt.after(self.removedAt!))
    }

    /**
     * `canStyle` checks if node is able to style.
     */
    func canStyle(
        _ editedAt: TimeTicket,
        _ maxCreatedAt: TimeTicket?,
        _ clientLamportAtChange: Int64
    ) -> Bool {
        if self.isText { return false }
        let nodeExisted: Bool
        if let maxCreatedAt = maxCreatedAt {
            nodeExisted = !self.createdAt.after(maxCreatedAt)
        } else {
            nodeExisted = self.createdAt.lamport <= clientLamportAtChange
        }

        return nodeExisted && (self.removedAt == nil || editedAt.after(self.removedAt!))
    }

    /**
     * `setAttrs` sets the attributes of the node.
     */
    func setAttrs(
        _ attrs: [String: String],
        _ editedAt: TimeTicket
    ) -> [(RHTNode?, RHTNode?)] {
        if self.attrs == nil {
            self.attrs = RHT()
        }

        var pairs = [(RHTNode?, RHTNode?)]()

        for attr in attrs {
            pairs.append(self.attrs!.set(key: attr.key, value: attr.value, executedAt: editedAt))
        }

        return pairs
    }

    /**
     * toXML converts the given CRDTNode to XML string.
     */
    static func toXML(node: CRDTTreeNode) -> String {
        if node.isText {
            return node.value as String
        }

        var xml = "<\(node.type)"
        if let attrs = node.attrs?.toObject() {
            for key in attrs.keys.sorted() {
                if let value = attrs[key]?.value {
                    xml += " \(key)=\(value)"
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
                                   value: node.value as String,
                                   size: node.size,
                                   isRemoved: node.isRemoved)
        } else {
            return TreeNodeForTest(type: node.type,
                                   children: node.children.map { self.toTestTreeNode($0) },
                                   size: node.size,
                                   isRemoved: node.isRemoved)
        }
    }

    var toJSONString: String {
        if let data = try? JSONSerialization.data(withJSONObject: toDictionary, options: [.sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8)
        {
            return jsonString
        }

        return "{}"
    }

    var toDictionary: [String: Any] {
        var dictionary: [String: Any] = ["type": self.type]

        if self.type == DefaultTreeNodeType.text.rawValue {
            dictionary["value"] = self.value as String
        } else {
            dictionary["children"] = self.children.map { $0.toDictionary }
            dictionary["attributes"] = self.attrs?.toDictionary
        }

        return dictionary
    }

    /**
     * `getGCPairs` returns the pairs of GC.
     */
    func getGCPairs() -> [GCPair] {
        var pairs = [GCPair]()

        if let attrs = self.attrs {
            for node in attrs where node.removedAt != nil {
                pairs.append(GCPair(parent: self, child: node))
            }
        }

        return pairs
    }
}

extension CRDTTreeNode: GCParent {
    func purge(node: any GCChild) {
        guard let node = node as? RHTNode else {
            return
        }

        self.attrs?.purge(node)
    }
}

extension CRDTTreeNode: GCChild {
    /**
     * `toIDString` returns the IDString of this node.
     */
    var toIDString: String {
        self.id.toIDString
    }
}

/**
 * `CRDTTree` is a CRDT implementation of a tree.
 */
class CRDTTree: CRDTElement {
    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    private(set) var indexTree: IndexTree<CRDTTreeNode>
    private var nodeMapByID: LLRBTree<CRDTTreeNodeID, CRDTTreeNode>

    init(root: CRDTTreeNode, createdAt: TimeTicket) {
        self.createdAt = createdAt
        self.indexTree = IndexTree(root: root)
        self.nodeMapByID = LLRBTree()

        self.indexTree.traverseAll { node, _ in
            self.nodeMapByID.put(node.id, node)
        }
    }

    /**
     * `findFloorNode` finds node of given id.
     */
    func findFloorNode(_ id: CRDTTreeNodeID) -> CRDTTreeNode? {
        guard let entry = self.nodeMapByID.floorEntry(id), entry.key.createdAt == id.createdAt else {
            return nil
        }

        return entry.value
    }

    /**
     * `registerNode` registers the given node to the tree.
     */
    func registerNode(_ node: CRDTTreeNode) {
        self.nodeMapByID.put(node.id, node)
    }

    /**
     * `findNodesAndSplitText` finds `TreePos` of the given `CRDTTreeNodeID` and
     * splits nodes for the given split level.
     *
     * The ids of the given `pos` are the ids of the node in the CRDT perspective.
     * This is different from `TreePos` which is a position of the tree in the
     * physical perspective.
     */
    func findNodesAndSplitText(_ pos: CRDTTreePos, _ editedAt: TimeTicket? = nil) throws -> TreeNodePair {
        // 01. Find the parent and left sibling node of the given position.
        let (parent, leftSibling) = try pos.toTreeNodePair(tree: self)
        var leftNode = leftSibling

        // 02. Determine whether the position is left-most and the exact parent
        // in the current tree.
        let isLeftMost = parent === leftNode
        let realParent = leftNode.parent != nil && !isLeftMost ? leftNode.parent! : parent

        // 03. Split text node if the left node is a text node.
        if leftNode.isText {
            try leftNode.split(self, pos.leftSiblingID.offset - leftNode.id.offset, nil)
        }

        // 04. Find the appropriate left node. If some nodes are inserted at the
        // same position concurrently, then we need to find the appropriate left
        // node. This is similar to RGA.
        if let editedAt {
            let allChildren = realParent.innerChildren
            let index = isLeftMost ? 0 : (allChildren.firstIndex(where: { $0 === leftNode }) ?? -1) + 1

            for next in allChildren.suffix(from: index) {
                if !next.id.createdAt.after(editedAt) {
                    break
                }

                leftNode = next
            }
        }

        return (realParent, leftNode)
    }

    /**
     * `style` applies the given attributes of the given range.
     */
    @discardableResult
    func style(
        _ range: TreePosRange,
        _ attributes: [String: String]?,
        _ editedAt: TimeTicket,
        _ maxCreatedAtMapByActor: [String: TimeTicket]? = nil,
        _ versionVector: VersionVector? = nil
    ) throws -> ([String: TimeTicket], [GCPair], [TreeChange]) {
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, editedAt)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, editedAt)

        var changes: [TreeChange] = []
        var createdAtMapByActor = [String: TimeTicket]()
        var pairs = [GCPair]()
        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { token, _ in
            let (node, _) = token
            let actorID = node.createdAt.actorID
            var maxCreatedAt: TimeTicket?
            var clientLamportAtChange: Int64 = 0

            if versionVector == nil && maxCreatedAtMapByActor.isNilOrEmpty {
                // Local edit - use version vector comparison
                clientLamportAtChange = .max
            } else if let versionVector, versionVector.size() > 0 {
                clientLamportAtChange = versionVector.get(actorID) ?? 0
            } else {
                if let map = maxCreatedAtMapByActor?[node.createdAt.actorID] {
                    maxCreatedAt = map
                } else {
                    maxCreatedAt = .initial
                }
            }
            if node.canStyle(
                editedAt,
                maxCreatedAt,
                clientLamportAtChange
            ), !node.isText, let attributes {
                let maxCreatedAt = createdAtMapByActor[actorID]
                let createdAt = node.createdAt
                if maxCreatedAt == nil || createdAt.after(maxCreatedAt!) {
                    createdAtMapByActor[actorID] = createdAt
                }

                if node.attrs == nil {
                    node.attrs = RHT()
                }
                let updatedAttrPairs = node.setAttrs(attributes, editedAt)
                var affectedAttrs = [String: String]()
                for (_, curr) in updatedAttrPairs {
                    if let key = curr?.key {
                        affectedAttrs[key] = attributes[key]
                    }
                }

                let parentOfNode = node.parent!
                let previousNode = node.prevSibling ?? node.parent!

                if !affectedAttrs.isEmpty {
                    try changes.append(TreeChange(actor: editedAt.actorID,
                                                  type: .style,
                                                  from: self.toIndex(parentOfNode, previousNode),
                                                  to: self.toIndex(node, node),
                                                  fromPath: self.toPath(parentOfNode, previousNode),
                                                  toPath: self.toPath(node, node),
                                                  value: TreeChangeValue.attributes(affectedAttrs),
                                                  splitLevel: 0) // dummy value.
                    )

                    for (prev, _) in updatedAttrPairs where prev != nil {
                        pairs.append(GCPair(parent: node, child: prev))
                    }
                }
            }
        }

        return (createdAtMapByActor, pairs, changes)
    }

    /**
     * `removeStyle` removes the given attributes of the given range.
     */
    func removeStyle(
        _ range: TreePosRange,
        _ attributesToRemove: [String],
        _ editedAt: TimeTicket,
        _ maxCreatedAtMapByActor: [String: TimeTicket]? = nil,
        _ versionVector: VersionVector? = nil
    ) throws -> ([String: TimeTicket], [GCPair], [TreeChange]) {
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, editedAt)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, editedAt)
        var changes: [TreeChange] = []
        var createdAtMapByActor = [String: TimeTicket]()
        var pairs = [GCPair]()
        let value = TreeChangeValue.attributesToRemove(attributesToRemove)

        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { token, _ in
            let (node, _) = token
            let actorID = node.createdAt.actorID
            var maxCreatedAt: TimeTicket?
            var clientLamportAtChange: Int64 = 0

            if versionVector == nil && maxCreatedAtMapByActor.isNilOrEmpty {
                // Local edit - use version vector comparison
                clientLamportAtChange = .max
            } else if let versionVector, versionVector.size() > 0 {
                clientLamportAtChange = versionVector.get(actorID) ?? 0
            } else {
                if let map = maxCreatedAtMapByActor?[node.createdAt.actorID] {
                    maxCreatedAt = map
                } else {
                    maxCreatedAt = TimeTicket.initial
                }
            }

            if node.canStyle(
                editedAt,
                maxCreatedAt,
                clientLamportAtChange
            ), !attributesToRemove.isEmpty {
                let maxCreatedAt = createdAtMapByActor[actorID]
                let createdAt = node.createdAt
                if maxCreatedAt == nil || createdAt.after(maxCreatedAt!) {
                    createdAtMapByActor[actorID] = createdAt
                }

                if node.attrs == nil {
                    node.attrs = RHT()
                }
                for key in attributesToRemove {
                    let nodesToBeRemoved = node.attrs!.remove(key: key, executedAt: editedAt)
                    for rhtNode in nodesToBeRemoved {
                        pairs.append(GCPair(parent: node, child: rhtNode))
                    }
                }

                let parentOfNode = node.parent!
                let previousNode = node.prevSibling ?? node.parent!

                try changes.append(TreeChange(actor: editedAt.actorID,
                                              type: .removeStyle,
                                              from: self.toIndex(parentOfNode, previousNode),
                                              to: self.toIndex(node, node),
                                              fromPath: self.toPath(parentOfNode, previousNode),
                                              toPath: self.toPath(node, node),
                                              value: value,
                                              splitLevel: 0) // dummy value.
                )
            }
        }

        return (createdAtMapByActor, pairs, changes)
    }

    /**
     * `edit` edits the tree with the given range and content.
     * If the content is undefined, the range will be removed.
     */
    @discardableResult
    func edit(
        _ range: TreePosRange,
        _ contents: [CRDTTreeNode]?,
        _ splitLevel: Int32,
        _ editedAt: TimeTicket,
        _ issueTimeTicket: () -> TimeTicket,
        _ maxCreatedAtMapByActor: [String: TimeTicket]? = nil,
        _ versionVector: VersionVector? = nil
    ) throws -> ([TreeChange], [GCPair], [String: TimeTicket]) {
        // 01. find nodes from the given range and split nodes.
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0, editedAt)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1, editedAt)

        let fromIdx = try self.toIndex(fromParent, fromLeft)
        let fromPath = try self.toPath(fromParent, fromLeft)

        var nodesToBeRemoved = [CRDTTreeNode]()
        var tokensToBeRemoved = [TreeToken<CRDTTreeNode>]()
        var toBeMovedToFromParents = [CRDTTreeNode]()
        var maxCreatedAtMap = [String: TimeTicket]()
        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { treeToken, ended in
            // NOTE(hackerwins): If the node overlaps as a start tag with the
            // range then we need to move the remaining children to fromParent.
            let (node, tokenType) = treeToken
            if tokenType == .start, !ended {
                // TODO(hackerwins): Define more clearly merge-able rules
                // between two parents. For now, we only merge two parents are
                // both element nodes having text children.
                // e.g. <p>a|b</p><p>c|d</p> -> <p>a|d</p>
                // if (!fromParent.hasTextChild() || !toParent.hasTextChild()) {
                //   return;
                // }

                toBeMovedToFromParents.append(contentsOf: node.children)
            }

            let actorID = node.createdAt.actorID

            var maxCreatedAt: TimeTicket?

            // NOTE(sejongk): If the node is removable or its parent is going to
            // be removed, then this node should be removed.

            var clientLamportAtChange: Int64 = 0

            if versionVector == nil && maxCreatedAtMapByActor.isNilOrEmpty {
                // Local edit - use version vector comparison
                clientLamportAtChange = .max
            } else if let versionVector, versionVector.size() > 0 {
                clientLamportAtChange = versionVector.get(actorID) ?? 0
            } else {
                maxCreatedAt = maxCreatedAtMapByActor?[node.createdAt.actorID] ?? .initial
            }

            if node.canDelete(
                editedAt,
                maxCreatedAt,
                clientLamportAtChange
            ) || nodesToBeRemoved.contains(where: { $0 === node.parent }) {
                let maxCreatedAt = maxCreatedAtMap[actorID]
                let createdAt = node.createdAt

                if maxCreatedAt == nil || createdAt.after(maxCreatedAt!) {
                    maxCreatedAtMap[actorID] = createdAt
                }

                // NOTE(hackerwins): If the node overlaps as an end token with the
                // range then we need to keep the node.
                if tokenType == .text || tokenType == .start {
                    nodesToBeRemoved.append(node)
                }
                tokensToBeRemoved.append((node, tokenType))
            }
        }

        // NOTE(hackerwins): If concurrent deletion happens, we need to seperate the
        // range(from, to) into multiple ranges.
        var changes = try self.makeDeletionChanges(tokensToBeRemoved, editedAt)

        // 02. Delete: delete the nodes that are marked as removed.
        var pairs = [GCPair]()
        for node in nodesToBeRemoved {
            node.remove(editedAt)

            if node.isRemoved {
                pairs.append(GCPair(parent: self, child: node))
            }
        }

        // 03. Merge: move the nodes that are marked as moved.
        try fromParent.append(contentsOf: toBeMovedToFromParents.filter { $0.removedAt == nil })

        // 04. Split: split the element nodes for the given split level.
        if splitLevel > 0 {
            var splitCount = 0
            var parent = fromParent
            var left = fromLeft
            while splitCount < splitLevel {
                try parent.split(self, Int32(parent.findOffset(node: left) + 1), issueTimeTicket())
                left = parent
                parent = parent.parent!
                splitCount += 1
            }

            changes.append(TreeChange(actor: editedAt.actorID,
                                      type: .content,
                                      from: fromIdx,
                                      to: fromIdx,
                                      fromPath: fromPath,
                                      toPath: fromPath,
                                      value: nil,
                                      splitLevel: 0))
        }

        // 05. Insert: insert the given nodes at the given position.
        if let contents, contents.isEmpty == false {
            var aliveContents = [CRDTTreeNode]()
            var leftInChildren = fromLeft // tree

            for content in contents {
                // 05-1. insert the content nodes to the tree.
                if leftInChildren === fromParent {
                    // 05-1-1. when there's no leftSibling, then insert content into very fromt of parent's children List
                    try fromParent.insertAt(content, 0)
                } else {
                    // 05-1-2. insert after leftSibling
                    try fromParent.insertAfter(content, leftInChildren)
                }

                leftInChildren = content
                traverseAll(node: content) { node, _ in
                    // if insertion happens during concurrent editing and parent node has been removed,
                    // make new nodes as tombstone immediately
                    if fromParent.isRemoved {
                        node.remove(editedAt)

                        pairs.append(GCPair(parent: self, child: node))
                    }

                    self.nodeMapByID.put(node.id, node)
                }

                if !content.isRemoved {
                    aliveContents.append(content)
                }
            }

            if aliveContents.isEmpty == false {
                let value = TreeChangeValue.nodes(aliveContents)

                if changes.isEmpty == false, changes.last!.from == fromIdx {
                    var last = changes.last!

                    last.value = value

                    changes.removeLast()
                    changes.append(last)
                } else {
                    changes.append(TreeChange(actor: editedAt.actorID,
                                              type: .content,
                                              from: fromIdx,
                                              to: fromIdx,
                                              fromPath: fromPath,
                                              toPath: fromPath,
                                              value: value,
                                              splitLevel: 0))
                }
            }
        }

        return (changes, pairs, maxCreatedAtMap)
    }

    /**
     * `editT` edits the given range with the given value.
     * This method uses indexes instead of a pair of TreePos for testing.
     */
    func editT(
        _ range: (Int, Int),
        _ contents: [CRDTTreeNode]?,
        _ splitLevel: Int32,
        _ editedAt: TimeTicket,
        _ issueTimeTicket: () -> TimeTicket
    ) throws {
        let fromPos = try self.findPos(range.0)
        let toPos = try self.findPos(range.1)
        try self.edit(
            (fromPos, toPos),
            contents,
            splitLevel,
            editedAt,
            issueTimeTicket,
            nil,
            nil
        )
    }

    /**
     * `move` move the given source range to the given target range.
     */
    func move(_ target: (Int, Int), _ source: (Int, Int), _ ticket: TimeTicket) throws {
        // TODO(hackerwins, easylogic): Implement this with keeping references of the nodes.
        throw YorkieError(code: .errInvalidArgument, message: "not implemented, \(target), \(source) \(ticket)")
    }

    /**
     * `findPos` finds the position of the given index in the tree.
     */
    func findPos(_ index: Int, _ preferText: Bool = true) throws -> CRDTTreePos {
        let treePos = try self.indexTree.findTreePos(index, preferText)

        return CRDTTreePos.fromTreePos(pos: treePos)
    }

    /**
     * `pathToPosRange` converts the given path of the node to the range of the position.
     */
    func pathToPosRange(_ path: [Int]) throws -> TreePosRange {
        let fromIdx = try self.pathToIndex(path)

        return try (self.findPos(fromIdx), self.findPos(fromIdx + 1))
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
     * `nodeSize` returns the size of the LLRBTree.
     */
    var nodeSize: Int {
        self.nodeMapByID.size
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
        self.indexTree.root.toJSONString
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
    private func toPath(_ parentNode: CRDTTreeNode, _ leftNode: CRDTTreeNode) throws -> [Int] {
        guard let treePos = try self.toTreePos(parentNode, leftNode) else {
            return []
        }

        return try self.indexTree.treePosToPath(treePos)
    }

    /**
     * `toIndex` converts the given CRDTTreeNodeID to the index of the tree.
     */
    func toIndex(_ parentNode: CRDTTreeNode, _ leftNode: CRDTTreeNode) throws -> Int {
        guard let treePos = try self.toTreePos(parentNode, leftNode) else {
            return -1
        }

        return try self.indexTree.indexOf(treePos)
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
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1)

        return try (self.toPath(fromParent, fromLeft), self.toPath(toParent, toLeft))
    }

    /**
     * `posRangeToIndexRange` converts the given position range to the path range.
     */
    func posRangeToIndexRange(_ range: TreePosRange) throws -> (Int, Int) {
        let (fromParent, fromLeft) = try self.findNodesAndSplitText(range.0)
        let (toParent, toLeft) = try self.findNodesAndSplitText(range.1)

        return try (self.toIndex(fromParent, fromLeft), self.toIndex(toParent, toLeft))
    }

    /**
     * `traverseInPosRange` traverses the tree in the given position range.
     */
    private func traverseInPosRange(_ fromParent: CRDTTreeNode,
                                    _ fromLeft: CRDTTreeNode,
                                    _ toParent: CRDTTreeNode,
                                    _ toLeft: CRDTTreeNode,
                                    callback: @escaping (TreeToken<CRDTTreeNode>, Bool) throws -> Void) throws
    {
        let fromIdx = try self.toIndex(fromParent, fromLeft)
        let toIdx = try self.toIndex(toParent, toLeft)

        return try self.indexTree.tokensBetween(fromIdx, toIdx, callback)
    }

    /**
     * `toTreePos` converts the given CRDTTreePos to local TreePos<CRDTTreeNode>.
     */
    private func toTreePos(_ parentNode: CRDTTreeNode, _ leftNode: CRDTTreeNode) throws -> TreePos<CRDTTreeNode>? {
        var parentNode = parentNode

        if parentNode.isRemoved {
            var childNode = parentNode
            while parentNode.isRemoved {
                childNode = parentNode
                parentNode = childNode.parent!
            }

            let childOffset = try parentNode.findOffset(node: childNode)

            return TreePos(node: parentNode, offset: Int32(childOffset))
        }

        if parentNode === leftNode {
            return TreePos(node: parentNode, offset: 0)
        }

        var offset = try parentNode.findOffset(node: leftNode)

        if leftNode.isRemoved == false {
            if leftNode.isText {
                return TreePos(node: leftNode, offset: Int32(leftNode.paddedSize))
            }

            offset += 1
        }

        return TreePos(node: parentNode, offset: Int32(offset))
    }

    /**
     * `makeDeletionChanges` converts nodes to be deleted to deletion changes.
     */
    func makeDeletionChanges(_ candidates: [TreeToken<CRDTTreeNode>], _ editedAt: TimeTicket) throws -> [TreeChange] {
        var changes = [TreeChange]()
        var ranges = [(TreeToken<CRDTTreeNode>, TreeToken<CRDTTreeNode>)]()

        // Generate ranges by accumulating consecutive nodes.
        var start: TreeToken<CRDTTreeNode>?
        var end: TreeToken<CRDTTreeNode>?
        for (index, cur) in candidates.enumerated() {
            let next = candidates[safe: index + 1]
            if start == nil {
                start = cur
            }
            end = cur

            let rightToken = try self.findRightToken(cur)
            if next == nil ||
                rightToken.0 !== next!.0 ||
                rightToken.1 != next!.1
            {
                ranges.append((start!, end!))
                start = nil
                end = nil
            }
        }

        // Convert each range to a deletion change.
        for range in ranges {
            let (start, end) = range
            let (fromLeft, fromLeftTokenType) = try self.findLeftToken(start)
            let (toLeft, toLeftTokenType) = end
            let fromParent = fromLeftTokenType == .start ? fromLeft : fromLeft.parent!
            let toParent = toLeftTokenType == .start ? toLeft : toLeft.parent!

            let fromIdx = try self.toIndex(fromParent, fromLeft)
            let toIdx = try self.toIndex(toParent, toLeft)
            if fromIdx < toIdx {
                // When the range is overlapped with the previous one, compact them.
                if changes.isEmpty == false, fromIdx == changes.last!.to {
                    var last = changes.last!

                    last.to = toIdx
                    last.toPath = try self.toPath(toParent, toLeft)

                    changes.removeLast()
                    changes.append(last)
                } else {
                    try changes.append(TreeChange(actor: editedAt.actorID,
                                                  type: .content,
                                                  from: fromIdx,
                                                  to: toIdx,
                                                  fromPath: self.toPath(fromParent, fromLeft),
                                                  toPath: self.toPath(toParent, toLeft),
                                                  value: nil,
                                                  splitLevel: 0))
                }
            }
        }
        return changes.reversed()
    }

    /**
     * `findRightToken` returns the token to the right of the given token in the tree.
     */
    func findRightToken(_ token: TreeToken<CRDTTreeNode>) throws -> TreeToken<CRDTTreeNode> {
        let (node, tokenType) = token
        if tokenType == .start {
            let children = node.innerChildren
            if children.isEmpty == false {
                let firstChild = children.first!
                return (firstChild, firstChild.isText ? .text : .end)
            }

            return (node, .end)
        }

        let parent = node.parent
        let siblings = parent!.innerChildren

        guard let offset = siblings.firstIndex(where: { $0 === node }) else {
            throw YorkieError(code: .errUnexpected, message: "Can't find index of node \(node)")
        }

        if parent != nil, offset == siblings.count - 1 {
            return (parent!, .end)
        }

        let next = siblings[offset + 1]
        return (next, next.isText ? .text : .end)
    }

    /**
     * `findLeftToken` returns the token to the left of the given token in the tree.
     */
    func findLeftToken(_ token: TreeToken<CRDTTreeNode>) throws -> TreeToken<CRDTTreeNode> {
        let (node, tokenType) = token
        if tokenType == .end {
            let children = node.innerChildren
            if children.isEmpty == false {
                let lastChild = children.last!
                return (lastChild, lastChild.isText ? .text : .end)
            }

            return (node, .start)
        }

        let parent = node.parent
        let siblings = parent!.innerChildren

        guard let offset = siblings.firstIndex(where: { $0 === node }) else {
            throw YorkieError(code: .errUnexpected, message: "Can't find index of node \(node)")
        }

        if parent != nil, offset == 0 {
            return (parent!, .start)
        }

        let prev = siblings[offset - 1]
        return (prev, prev.isText ? .text : .end)
    }
}

extension CRDTTree: GCParent {
    /**
     * `purge` physically purges the given node.
     */
    func purge(node: any GCChild) {
        guard let node = node as? CRDTTreeNode else {
            return
        }

        do {
            try node.parent?.removeChild(child: node)
        } catch {
            return
        }
        self.nodeMapByID.remove(node.id)

        if let insPrevID = node.insPrevID {
            self.findFloorNode(insPrevID)?.insNextID = node.insNextID
        }
        if let insNextID = node.insNextID {
            self.findFloorNode(insNextID)?.insPrevID = node.insPrevID
        }

        node.insPrevID = nil
        node.insNextID = nil
    }
}

extension CRDTTree: CRDTGCPairContainable {
    /**
     * `getGCPairs` returns the pairs of GC.
     */
    func getGCPairs() -> [GCPair] {
        var pairs = [GCPair]()
        self.indexTree.traverse { node, _ in
            if node.removedAt != nil {
                pairs.append(GCPair(parent: self, child: node))
            }

            for pair in node.getGCPairs() {
                pairs.append(pair)
            }
        }

        return pairs
    }
}
