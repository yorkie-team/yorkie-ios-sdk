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
    static let initial = CRDTTreeNodeID(createdAt: .initial, offset: 0)

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

    /**
     * `mergedFrom` records the source parent's ID when this node was moved by a
     * concurrent merge. Persisted in the snapshot encoding as the witness of the
     * merge relationship.
     */
    var mergedFrom: CRDTTreeNodeID?

    /**
     * `mergedAt` records the immutable ticket of the merge operation. Persisted
     * alongside ``mergedFrom`` because the source parent's ``removedAt`` may be
     * overwritten by later LWW tombstones and thus cannot serve as the
     * merge-time causal boundary for the split's Fix 8 version-vector check.
     */
    var mergedAt: TimeTicket?

    /**
     * `mergedInto` is a runtime cache set on the source parent pointing at the
     * merge target. Set locally during merge execution and rebuilt from
     * ``mergedFrom`` on snapshot load. Used for the fast "is this tombstoned
     * parent a merge source?" check when resolving insertion positions.
     */
    var mergedInto: CRDTTreeNodeID?

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
        clone.mergedFrom = self.mergedFrom
        clone.mergedAt = self.mergedAt
        clone.mergedInto = self.mergedInto

        return clone
    }

    /**
     * `isRemoved` returns whether the node is removed or not.
     */
    var isRemoved: Bool {
        self.removedAt != nil
    }

    /**
     * `remove` marks the node as removed. Returns true when this call
     * transitions a previously-alive node to removed, so the caller can register
     * a GC pair; a tombstone overwrite by LWW returns false.
     */
    @discardableResult
    func remove(_ removedAt: TimeTicket) -> Bool {
        let alived = !self.isRemoved

        if self.removedAt == nil || removedAt <= self.removedAt! {
            self.removedAt = removedAt
        }

        if alived {
            self.updateAncestorsSize()
            return true
        }

        return false
    }

    /**
     * `cloneText` clones this text node with the given offset.
     */
    func cloneText(offset: Int32) -> CRDTTreeNode {
        let clone = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.id.createdAt, offset: offset),
                                 type: self.type,
                                 removedAt: self.removedAt)
        clone.mergedFrom = self.mergedFrom
        clone.mergedAt = self.mergedAt
        return clone
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
     * `shouldStayLeftOnSplit` keeps a concurrent merge-moved child in the
     * original (left) node during a split when the merge is unknown to the
     * editor and the merge source is local to this node (one of `siblings`).
     */
    func shouldStayLeftOnSplit(_ child: CRDTTreeNode, siblings: [CRDTTreeNode], versionVector: VersionVector?) -> Bool {
        guard let mergedFrom = child.mergedFrom, let mergedAt = child.mergedAt else {
            return false
        }
        guard let versionVector, !versionVector.afterOrEqual(other: mergedAt) else {
            return false
        }

        return siblings.contains { $0.id == mergedFrom }
    }

    /**
     * `split` splits the given offset of this node.
     */
    @discardableResult
    func split(
        _ tree: CRDTTree,
        _ offset: Int32,
        _ issueTimeTicket: TimeTicket? = nil,
        _ versionVector: VersionVector? = nil
    ) throws -> (CRDTTreeNode?, DataSize) {
        if self.isText == false, issueTimeTicket == nil {
            throw YorkieError(code: .errInvalidArgument, message: "The issueTimeTicket for Text Node have to nil!")
        }

        let (split, diff) = self.isText ? try self.splitText(offset, self.id.offset) : try self.splitElement(offset, issueTimeTicket!, versionVector)

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

        return (split, diff)
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
     * Returns true if the node can be deleted based on the editedAt time.
     * If creationKnown is false, the node cannot be deleted.
     * If the node has no removedAt (alive), it can be deleted.
     * If tombstoneKnown is false and editedAt is after removedAt, allow overwrite.
     */
    func canDelete(
        _ editedAt: TimeTicket,
        _ creationKnown: Bool,
        _ tombstoneKnown: Bool
    ) -> Bool {
        if !creationKnown {
            return false
        }
        if self.removedAt == nil {
            return true
        }
        // Allow tombstone overwrite when tombstoneKnown is false and editedAt is newer
        if !tombstoneKnown && editedAt.after(self.removedAt!) {
            return true
        }
        return false
    }

    /**
     * `canStyle` checks if node is able to style.
     */
    func canStyle(
        _ editedAt: TimeTicket,
        _ clientLamportAtChange: Int64
    ) -> Bool {
        if self.isText { return false }
        let nodeExisted = self.createdAt.lamport <= clientLamportAtChange

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
     * `getDataSize` returns the data size of the node.
     */
    func getDataSize() -> DataSize {
        var data = 0
        var meta = timeTicketSize

        if self.isText {
            data += self.size * 2
        }

        if self.isRemoved {
            meta += timeTicketSize
        }

        if let attrs {
            for node in attrs where node.isRemoved == false {
                let size = node.getDataSize()
                meta += size.meta
                data += size.data
            }
        }
        let result = DataSize(data: data, meta: meta)
        return result
    }

    /**
     * `toIDString` returns the IDString of this node.
     */
    var toIDString: String {
        self.id.toIDString
    }
}

/**
 * `ticketKnown` returns true if the given ticket is causally known to the
 * editor, i.e. the editor's version vector covers the ticket's lamport clock
 * for the same actor. For local operations (no version vector), all tickets are
 * considered known.
 */
private func ticketKnown(_ versionVector: VersionVector?, _ ticket: TimeTicket) -> Bool {
    guard let versionVector else {
        return true
    }
    guard let lamport = versionVector.get(ticket.actorID) else {
        return false
    }
    return lamport >= ticket.lamport
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

        // Rebuild runtime merge state from the persisted `mergedFrom` field.
        // Only `mergedFrom` and `mergedAt` are written to the snapshot encoding;
        // `mergedInto` is a cache reconstructed here so replicas loaded from a
        // snapshot can still handle concurrent ops that target merged-away
        // parents (redirect, propagation, split skip).
        self.rebuildMergeState()
    }

    /**
     * `rebuildMergeState` reconstructs the `mergedInto` cache on source parents
     * from the persisted ``CRDTTreeNode/mergedFrom`` field on moved children.
     * For snapshots written before `mergedAt` was added to the proto, it also
     * falls back to the source's `removedAt` — an approximation that may be
     * wrong if the source was later overwritten by a concurrent delete, but it
     * is the best available without the persisted merge ticket.
     */
    private func rebuildMergeState() {
        self.indexTree.traverseAll { node, _ in
            guard let mergedFrom = node.mergedFrom, let parent = node.parent else {
                return
            }
            guard let src = self.findFloorNode(mergedFrom) else {
                return
            }

            // Back-compat: older snapshots lack mergedAt on moved children.
            if node.mergedAt == nil, let removedAt = src.removedAt {
                node.mergedAt = removedAt
            }

            if src.mergedInto == nil {
                src.mergedInto = parent.id
            }
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
     * `advancePastUnknownSplitSiblings` follows the `insNextID` chain of the
     * given node, advancing past element-type split siblings that the editing
     * client did not know about (not in `versionVector`).
     */
    private func advancePastUnknownSplitSiblings(_ node: CRDTTreeNode, _ versionVector: VersionVector?) -> CRDTTreeNode {
        guard let versionVector else {
            return node
        }

        var current = node
        while let insNextID = current.insNextID {
            guard let next = self.findFloorNode(insNextID), !next.isText else {
                break
            }

            // Stop if the sibling has been moved to a different parent
            // (e.g., by a higher-level concurrent split).
            if next.parent !== current.parent {
                break
            }

            let actorID = next.id.createdAt.actorID
            if let knownLamport = versionVector.get(actorID), knownLamport >= next.id.createdAt.lamport {
                break
            }

            current = next
        }

        return current
    }

    /**
     * `hasUnknownSplitSibling` checks whether the given element node has a split
     * sibling (via `insNextID`) whose creation the editor did not know about.
     * Used to prevent styling via End tokens when a concurrent split extended
     * the range into the split sibling.
     */
    private func hasUnknownSplitSibling(_ node: CRDTTreeNode, _ versionVector: VersionVector) -> Bool {
        guard let insNextID = node.insNextID else {
            return false
        }

        guard let next = self.findFloorNode(insNextID), !next.isText else {
            return false
        }

        // NOTE: Unlike advancePastUnknownSplitSiblings, the parent-equality
        // check is intentionally omitted. In multi-level splits (splitLevel>=2),
        // the split sibling may have been moved to a different parent by the
        // recursive ancestor split. The End-token guard must still fire because
        // the node WAS split — insNextID is only set by SplitElement.
        let actorID = next.id.createdAt.actorID
        guard let knownLamport = versionVector.get(actorID) else {
            return true
        }

        return knownLamport < next.id.createdAt.lamport
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
    func findNodesAndSplitText(
        _ pos: CRDTTreePos,
        _ editedAt: TimeTicket? = nil
    ) throws -> (TreeNodePair, DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        // 01. Find the parent and left sibling node of the given position.
        let (parent, leftSibling) = try pos.toTreeNodePair(tree: self)
        var leftNode = leftSibling

        // 02. Determine whether the position is left-most and the exact parent
        // in the current tree.
        let isLeftMost = parent === leftNode
        let realParent = leftNode.parent != nil && !isLeftMost ? leftNode.parent! : parent

        // 02-1. If the parent has been tombstoned by a merge, redirect to the
        // merge destination using the forwarding pointer. The insertion boundary
        // is the first child in the target whose `mergedFrom` points back at the
        // tombstoned parent (i.e. the first child moved by the merge, in target
        // child order).
        if realParent.isRemoved, isLeftMost, let mergedInto = realParent.mergedInto {
            if let mergeTarget = self.findFloorNode(mergedInto), !mergeTarget.isRemoved {
                let allChildren = mergeTarget.innerChildren
                for (index, targetChild) in allChildren.enumerated() {
                    guard let childMergedFrom = targetChild.mergedFrom, childMergedFrom == realParent.id else {
                        continue
                    }
                    if index == 0 {
                        return ((mergeTarget, mergeTarget), diff)
                    }
                    return ((mergeTarget, allChildren[index - 1]), diff)
                }
                // Fallback: insert at leftmost of merge target.
                return ((mergeTarget, mergeTarget), diff)
            }
        }

        // 03. Split text node if the left node is a text node.
        if leftNode.isText {
            let (_, splitedDiff) = try leftNode.split(self, pos.leftSiblingID.offset - leftNode.id.offset)
            diff = splitedDiff
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

        return ((realParent, leftNode), diff)
    }

    /**
     * `style` applies the given attributes of the given range.
     */
    @discardableResult
    func style(
        _ range: TreePosRange,
        _ attributes: [String: String]?,
        _ editedAt: TimeTicket,
        _ versionVector: VersionVector?
    ) throws -> ([GCPair], [TreeChange], DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        let ((fromParent, fromLeftRaw), fromDiff) = try self.findNodesAndSplitText(range.0, editedAt)
        let ((toParent, toLeftRaw), toDiff) = try self.findNodesAndSplitText(range.1, editedAt)
        diff.addDataSizes(others: fromDiff, toDiff)

        // Advance past split siblings unknown to the editing client so the range
        // covers all concurrent split products. Skip when leftNode == parent.
        let fromLeft = fromLeftRaw !== fromParent ? self.advancePastUnknownSplitSiblings(fromLeftRaw, versionVector) : fromLeftRaw
        let toLeft = toLeftRaw !== toParent ? self.advancePastUnknownSplitSiblings(toLeftRaw, versionVector) : toLeftRaw

        var changes: [TreeChange] = []
        var pairs = [GCPair]()
        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { token, _ in
            let (node, tokenType) = token
            let actorID = node.createdAt.actorID
            var clientLamportAtChange: Int64 = .max

            if let versionVector {
                clientLamportAtChange = versionVector.get(actorID) ?? 0
            }
            if node.canStyle(
                editedAt,
                clientLamportAtChange
            ), !node.isText, let attributes {
                // Skip styling via End token when the node has an unknown split
                // sibling. The End token is in the range only because a
                // concurrent split extended the range into the sibling.
                if tokenType == .end, let versionVector, self.hasUnknownSplitSibling(node, versionVector) {
                    return
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

                for attr in attributes {
                    let key = attr.key
                    let curr = node.attrs?.getNodeByKey(key)
                    if let curr, tokenType != .end {
                        diff.addDataSizes(others: curr.getDataSize())
                    }
                }
            }
        }

        return (pairs, changes, diff)
    }

    /**
     * `removeStyle` removes the given attributes of the given range.
     */
    func removeStyle(
        _ range: TreePosRange,
        _ attributesToRemove: [String],
        _ editedAt: TimeTicket,
        _ versionVector: VersionVector? = nil
    ) throws -> ([GCPair], [TreeChange], DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        let ((fromParent, fromLeftRaw), fromDiff) = try self.findNodesAndSplitText(range.0, editedAt)
        let ((toParent, toLeftRaw), toDiff) = try self.findNodesAndSplitText(range.1, editedAt)
        diff.addDataSizes(others: fromDiff, toDiff)

        // Advance past split siblings unknown to the editing client so the range
        // covers all concurrent split products. Skip when leftNode == parent.
        let fromLeft = fromLeftRaw !== fromParent ? self.advancePastUnknownSplitSiblings(fromLeftRaw, versionVector) : fromLeftRaw
        let toLeft = toLeftRaw !== toParent ? self.advancePastUnknownSplitSiblings(toLeftRaw, versionVector) : toLeftRaw

        var changes: [TreeChange] = []
        var pairs = [GCPair]()
        let value = TreeChangeValue.attributesToRemove(attributesToRemove)

        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { token, _ in
            let (node, tokenType) = token
            let actorID = node.createdAt.actorID
            var clientLamportAtChange: Int64 = .max

            if let versionVector {
                clientLamportAtChange = versionVector.get(actorID) ?? 0
            }
            if node.canStyle(
                editedAt,
                clientLamportAtChange
            ), !attributesToRemove.isEmpty {
                // Skip styling via End token when the node has an unknown split
                // sibling. The End token is in the range only because a
                // concurrent split extended the range into the sibling.
                if tokenType == .end, let versionVector, self.hasUnknownSplitSibling(node, versionVector) {
                    return
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

        return (pairs, changes, diff)
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
        _ versionVector: VersionVector? = nil
    ) throws -> ([TreeChange], [GCPair], DataSize, [CRDTTreeNode], Int) {
        // 01. find nodes from the given range and split nodes.
        var diff = DataSize(data: 0, meta: 0)
        let ((fromParent, fromLeftRaw), fromDiff) = try self.findNodesAndSplitText(range.0, editedAt)
        let ((toParent, toLeftRaw), toDiff) = try self.findNodesAndSplitText(range.1, editedAt)
        diff.addDataSizes(others: fromDiff, toDiff)

        // 01-1. Advance past split siblings unknown to the editing client.
        // When a concurrent SplitElement created siblings linked via insNextID,
        // the editor's position was computed against the unsplit tree. Advance
        // past siblings the editor could not have seen so that the range
        // starts/ends after all concurrent split products. Skip when
        // leftNode == parent (leftmost child position).
        let fromLeft = fromLeftRaw !== fromParent ? self.advancePastUnknownSplitSiblings(fromLeftRaw, versionVector) : fromLeftRaw
        let toLeft = toLeftRaw !== toParent ? self.advancePastUnknownSplitSiblings(toLeftRaw, versionVector) : toLeftRaw

        let fromIdx = try self.toIndex(fromParent, fromLeft)
        let fromPath = try self.toPath(fromParent, fromLeft)

        var nodesToBeRemoved = [CRDTTreeNode]()
        var tokensToBeRemoved = [TreeToken<CRDTTreeNode>]()
        var toBeMovedToFromParents = [CRDTTreeNode]()
        var toBeMergedNodes = [CRDTTreeNode]()
        try self.traverseInPosRange(fromParent, fromLeft, toParent, toLeft) { treeToken, ended in
            // NOTE(hackerwins): If the node overlaps as a start tag with the
            // range then we need to move the remaining children to fromParent.
            let (node, tokenType) = treeToken
            if tokenType == .start, !ended {
                // Fix 9: Skip merge for elements created by concurrent
                // operations. The editor didn't know about this element, so
                // crossing into it is an artifact of a concurrent split, not an
                // intentional merge.
                if ticketKnown(versionVector, node.createdAt) {
                    toBeMergedNodes.append(node)
                    toBeMovedToFromParents.append(contentsOf: node.children)
                }
            }

            // NOTE(sigmaith): Determine if the node's creation event was visible.
            let creationKnown = ticketKnown(versionVector, node.createdAt)

            // NOTE(sigmaith): Determine if existing tombstone was already causally known.
            let tombstoneKnown = node.removedAt != nil && ticketKnown(versionVector, node.removedAt!)

            // NOTE(sejongk): If the node is removable or its parent is going to
            // be removed, then this node should be removed. Do not cascade-delete
            // children of merge-boundary nodes (toBeMergedNodes), because those
            // children are moved rather than deleted.
            if node.canDelete(
                editedAt,
                creationKnown,
                tombstoneKnown
            ) || (nodesToBeRemoved.contains(where: { $0 === node.parent }) && !toBeMergedNodes.contains(where: { $0 === node.parent })) {
                // NOTE(hackerwins): If the node overlaps as an end token with the
                // range then we need to keep the node.
                if tokenType == .text || tokenType == .start {
                    nodesToBeRemoved.append(node)

                    // Cascade delete to split siblings created by concurrent
                    // SplitElement. Only for element nodes.
                    if !node.isText, node.insNextID != nil, !toBeMergedNodes.contains(where: { $0 === node }) {
                        var nextID = node.insNextID
                        while let id = nextID, let next = self.findFloorNode(id) {
                            if !ticketKnown(versionVector, next.id.createdAt) {
                                nodesToBeRemoved.append(next)
                                // Cascade through the full subtree, not just immediate children.
                                traverseAll(node: next) { descendant, _ in
                                    if descendant !== next {
                                        nodesToBeRemoved.append(descendant)
                                    }
                                }
                            }
                            if next.insNextID == nil {
                                break
                            }
                            nextID = next.insNextID
                        }
                    }
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
            if node.remove(editedAt) {
                pairs.append(GCPair(parent: self, child: node))
            }
        }

        // 03. Merge: move the nodes that are marked as moved. Only `mergedFrom`
        // and `mergedAt` are written on the moved child — both are persisted in
        // the snapshot encoding. `mergedAt` must be captured explicitly here
        // (not read from source.removedAt at use time) because the source's
        // `removedAt` is mutated by LWW when a later concurrent tombstone
        // targets the same node.
        for node in toBeMovedToFromParents where node.removedAt == nil {
            if let parent = node.parent {
                node.mergedFrom = parent.id
                node.mergedAt = editedAt
                // Detach from old parent to prevent ghost references. The child
                // may already have been detached by a concurrent operation
                // (e.g., cascade delete of split sibling), so ignore the error.
                try? parent.detachChild(child: node)
            }
            try fromParent.append(contentsOf: [node])
        }

        // Set forwarding pointer on merge-source nodes. This is a runtime cache
        // rebuilt from `mergedFrom` on snapshot load.
        for src in toBeMergedNodes {
            src.mergedInto = fromParent.id
        }

        // 03-1. Propagate deletes to children moved by prior merges. When a
        // merge-source node is fully deleted (not a merge boundary), its former
        // children in the merge target should also be deleted. Skip when
        // `mergedInto` points to `fromParent` (concurrent merge). The list of
        // moved children is recomputed on the fly from the merge target's
        // children filtered by `mergedFrom`.
        for node in nodesToBeRemoved {
            guard let mergedInto = node.mergedInto,
                  !toBeMergedNodes.contains(where: { $0 === node }),
                  mergedInto != fromParent.id
            else {
                continue
            }
            guard let mergeTarget = self.findFloorNode(mergedInto) else {
                continue
            }
            for targetChild in mergeTarget.innerChildren {
                guard let childMergedFrom = targetChild.mergedFrom, childMergedFrom == node.id else {
                    continue
                }
                if targetChild.removedAt != nil {
                    continue
                }
                if targetChild.remove(editedAt) {
                    pairs.append(GCPair(parent: self, child: targetChild))
                }
                // Also tombstone descendants if the moved child is an element.
                traverseAll(node: targetChild) { descendant, _ in
                    if descendant !== targetChild, descendant.removedAt == nil {
                        if descendant.remove(editedAt) {
                            pairs.append(GCPair(parent: self, child: descendant))
                        }
                    }
                }
            }
        }

        // 04. Split: split the element nodes for the given split level.
        if splitLevel > 0 {
            var splitCount = 0
            var parent = fromParent
            var left = fromLeft
            while splitCount < splitLevel {
                try parent.split(self, Int32(parent.findOffset(node: left) + 1), issueTimeTicket(), versionVector)
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
                    } else {
                        print(node.getDataSize())
                        diff.addDataSizes(others: node.getDataSize())
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
        return (changes, pairs, diff, nodesToBeRemoved, fromIdx)
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
     * `pathToTreePos` converts the given path of the node to the TreePos.
     */
    func pathToTreePos(_ path: [Int]) throws -> TreePos<CRDTTreeNode> {
        return try self.indexTree.pathToTreePos(path)
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
     * `getDataSize` returns the data usage of this element.
     */
    func getDataSize() -> DataSize {
        var data = 0
        var meta = self.getMetaUsage()
        self.indexTree.traverse { node, _ in
            if node.removedAt != nil {
                return
            }

            let size = node.getDataSize()
            data += size.data
            meta += size.meta
        }

        return DataSize(
            data: data,
            meta: meta
        )
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
        let ((fromParent, fromLeft), _) = try self.findNodesAndSplitText(range.0)
        let ((toParent, toLeft), _) = try self.findNodesAndSplitText(range.1)

        return try (self.toPath(fromParent, fromLeft), self.toPath(toParent, toLeft))
    }

    /**
     * `posRangeToIndexRange` converts the given position range to the path range.
     */
    func posRangeToIndexRange(_ range: TreePosRange) throws -> (Int, Int) {
        let ((fromParent, fromLeft), _) = try self.findNodesAndSplitText(range.0)
        let ((toParent, toLeft), _) = try self.findNodesAndSplitText(range.1)

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

        // When a concurrent merge redirects the to-position into an earlier part
        // of the tree, the range becomes empty (prior merge handled it).
        if fromIdx > toIdx {
            return
        }

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

extension CRDTTreeNode {
    var toXML: String {
        return CRDTTreeNode.toXML(node: self)
    }
}
