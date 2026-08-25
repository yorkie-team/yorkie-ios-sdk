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

/// `PosBoundary` selects how a position inside a merged-away parent resolves in
/// ``CRDTTree/findNodesAndSplitText(_:_:_:)``.
enum PosBoundary {
    /// The insertion boundary in the merge target, before the first moved child,
    /// so RGA ordering breaks ties between concurrent inserts.
    case insert
    /// The position right after the merge-source tombstone, so a style range
    /// neither grows over nor shrinks past nodes concurrently inserted there.
    case range
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
 * `TreeRestoreSpan` identifies a node an edit transitioned visible → tombstoned,
 * for identity-preserving Tree undo/redo. For text nodes the span is the
 * absolute-offset interval `[id.offset, id.offset + length)` of the original
 * insertion (split-invariant); for element nodes it is the whole node.
 * `value`/`attrs` are deep-copied so a GC-purged node can be recreated.
 * `leftSiblingID`/`rightSiblingID` are the deleted run's external boundary
 * anchors captured at tombstone time — redundant on purpose: since a run's spans
 * are carried together, restore can rebuild the run's internal order from the op
 * itself and needs only ONE surviving boundary to place it (id-order is not
 * sibling-order in a tree).
 */
struct TreeRestoreSpan {
    let id: CRDTTreeNodeID
    let nodeType: TreeNodeType
    let isText: Bool
    /// Text length; 0 for elements.
    let length: Int32
    /// Text content copy.
    let value: NSString?
    /// Element attribute snapshot.
    let attrs: RHT?
    let parentID: CRDTTreeNodeID?
    /// `nil` → was first child.
    let leftSiblingID: CRDTTreeNodeID?
    /// `nil` → was last child.
    let rightSiblingID: CRDTTreeNodeID?
}

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
     * `unremove` clears the tombstone of this node (identity-preserving
     * restore). Mirrors ``remove(_:)``'s ancestor-size bookkeeping so the node
     * becomes visible again in place.
     */
    func unremove() {
        guard self.removedAt != nil else {
            return
        }
        self.removedAt = nil
        // `updateAncestorsSize` signs the delta by the node's own `isRemoved`,
        // which is now false, so this adds the size back.
        self.updateAncestorsSize()
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
     * Attributes are deep-copied so that a concurrent style operation whose range
     * was computed before a split also covers the right part of the split.
     */
    func cloneElement(issueTimeTicket: TimeTicket) -> CRDTTreeNode {
        let clone = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: issueTimeTicket, offset: 0),
                                 type: self.type,
                                 removedAt: self.removedAt)
        clone.attrs = self.attrs?.deepcopy()
        return clone
    }

    /**
     * `isSplitSiblingSkipForBoundaryMigration` returns true when `child` is an
     * element split sibling (has `insPrevID` and is not a text node). Such nodes
     * are split products handled by §7.4 and must be skipped during §7.3
     * boundary insert migration in ``IndexTreeNode/splitElement(_:_:_:)``.
     */
    func isSplitSiblingSkipForBoundaryMigration(_ child: CRDTTreeNode) -> Bool {
        child.insPrevID != nil && !child.isText
    }

    /**
     * `isUnknownToEditor` returns true when the editor did not know about
     * `child` at the time of the split. Used by §7.3 to decide whether a child
     * migrates left during boundary insert migration.
     */
    func isUnknownToEditor(_ child: CRDTTreeNode, versionVector: VersionVector) -> Bool {
        guard let lamport = versionVector.get(child.id.createdAt.actorID) else {
            return true
        }
        return lamport < child.id.createdAt.lamport
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

        if let split {
            split.insPrevID = self.id
            if let insNextID = self.insNextID {
                let insNext = tree.findFloorNode(insNextID)
                split.insNextID = insNextID

                if let insNext {
                    insNext.insPrevID = split.id

                    // §7.4 Empty Sibling Re-Parenting: when the existing insNext
                    // sibling lives in a different parent (due to a prior
                    // parent-level split), move the new empty split sibling into
                    // that parent. Skip when insNext has been tombstoned (e.g. by
                    // an undo boundary deletion): re-parenting into a removed
                    // element would make the new split sibling invisible.
                    if !self.isText,
                       let insNextParent = insNext.parent,
                       !insNext.isRemoved,
                       insNextParent !== split.parent,
                       split.innerChildren.isEmpty
                    {
                        try split.parent?.detachChild(child: split)
                        try insNextParent.insertBefore(split, insNext)
                    }
                }
            }
            self.insNextID = split.id
            tree.registerNode(split)

            // NOTE: A piece split off an already-tombstoned node inherits
            // `removedAt` without going through `remove()`, so no GC pair is
            // created for it in the normal deletion path. Register it here so
            // it can be purged; otherwise it stays in the tree forever.
            // The piece was never live, so its size goes straight to docSize.gc
            // when the pair is registered; report a zero diff to the caller
            // (which accounts diffs to docSize.live).
            if split.removedAt != nil {
                tree.registerPendingGCPair(split, diff)
                return (split, DataSize(data: 0, meta: 0))
            }
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

        // NOTE: Only called when a root is built from a snapshot. Removed
        // attribute nodes are skipped by `getDataSize`, so they were never
        // counted into docSize.live — hence `gcOnlySize`.
        if let attrs = self.attrs {
            for node in attrs where node.removedAt != nil {
                pairs.append(GCPair(parent: self, child: node, gcOnlySize: node.getDataSize()))
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

    /**
     * `pendingGCPairs` buffers GC pairs for nodes that were created
     * already-tombstoned by splitting a removed node. Such pieces inherit
     * `removedAt` without ever passing through `remove()`, so they would
     * otherwise never be registered for GC. `edit` and `style` drain this
     * buffer into their returned GC pairs.
     */
    private var pendingGCPairs: [GCPair] = []

    init(root: CRDTTreeNode, createdAt: TimeTicket) {
        self.createdAt = createdAt
        self.indexTree = IndexTree(root: root)
        self.nodeMapByID = LLRBTree()

        // Registering every node is the cost of loading a document, so it runs
        // without the duplicate check: a plain put per node, then one comparison
        // to see whether any ID was claimed twice. Only a tree that carries
        // duplicates pays for resolving them.
        var nodeCount = 0
        self.indexTree.traverseAll { node, _ in
            self.nodeMapByID.put(node.id, node)
            nodeCount += 1
        }
        if self.nodeMapByID.size != nodeCount {
            self.indexTree.traverseAll { node, _ in
                self.registerNode(node)
            }
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
     * `resolveMergeTarget` follows the `mergedInto` forwarding chain from the
     * given node while the current node is a merge-away tombstone, returning the
     * final live target. When a merge lands on a parent that a prior concurrent
     * merge already merged away (a chained merge P->Q->R, applied Q->R before
     * this P->Q), the children must flow to that parent's final destination so
     * the merge chain stays flat (P->R, not P->Q) and both replicas converge.
     * The seen set guards against cycles from a concurrent mutual merge.
     */
    private func resolveMergeTarget(_ node: CRDTTreeNode) -> CRDTTreeNode {
        var target = node
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(target)]
        while target.isRemoved, let mergedInto = target.mergedInto {
            guard let next = self.findFloorNode(mergedInto), !seen.contains(ObjectIdentifier(next)) else {
                break
            }
            seen.insert(ObjectIdentifier(next))
            target = next
        }
        return target
    }

    /**
     * `advancePastUnknownSplitSiblings` follows the `insNextID` chain of the
     * given node, advancing past element-type split siblings that the editing
     * client did not know about (not in `versionVector`).
     */
    private func advancePastUnknownSplitSiblings(
        _ node: CRDTTreeNode,
        _ versionVector: VersionVector?,
        relaxParentCheck: Bool = false,
        skipActorID: String? = nil
    ) -> CRDTTreeNode {
        guard let versionVector else {
            return node
        }

        var current = node
        while let insNextID = current.insNextID {
            guard let next = self.findFloorNode(insNextID), !next.isText else {
                break
            }

            // §7.5: Skip the parent check when relaxParentCheck is true — at
            // ancestor iterations of the split loop, a concurrent recursive
            // split may have moved the sibling to a different parent.
            if !relaxParentCheck, next.parent !== current.parent {
                break
            }

            let actorID = next.id.createdAt.actorID

            // §7.7: Stop at siblings created by the current operation's actor.
            // They are our own split products, not concurrent ones.
            if let skipActorID, actorID == skipActorID {
                break
            }

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
     * `registerNode` registers the given node to the tree, keeping a live node
     * over a tombstone when both claim the same ID.
     *
     * Documents written by older clients can carry two nodes under one ID (an
     * undo that re-inserted a deleted piece by copy). A plain put lets the
     * winner depend on the order the nodes were registered — operation order on
     * a live document, document order on one rebuilt from a snapshot — so after
     * a reload the same position resolves to a different node and its offset can
     * fall outside that node. Keeping the live one makes both orders agree for a
     * live/tombstone pair, which is the shape those documents carry.
     *
     * Two nodes in the same state keep the last-registered-wins behavior, and
     * stay order-dependent: element IDs issued for a split can legitimately
     * collide with an inserted node's ID (see the delimiter note in
     * ``TreeEditOperation``), and that resolution order is what the rest of the
     * tree already assumes.
     *
     * A node this refuses stays in the index tree while another node answers for
     * its ID, so it is reachable by traversal but not by lookup. That is the
     * intended trade for a duplicate: the alternative is unregistering a node
     * that positions still resolve through.
     */
    func registerNode(_ node: CRDTTreeNode) {
        if let entry = self.nodeMapByID.floorEntry(node.id),
           entry.value !== node,
           entry.key == node.id,
           node.isRemoved,
           entry.value.isRemoved == false
        {
            return
        }

        self.nodeMapByID.put(node.id, node)
    }

    /**
     * `dropDuplicateContents` returns the contents that would not put a second
     * node under an ID already in the tree.
     *
     * Content created by an edit carries that edit's lamport and actor, so a
     * content node whose ID names another change is a copy of a node that
     * already exists — what the copy-reinsert undo path sends when it reverses a
     * deletion. Inserting it would leave two nodes under one identity, so the
     * copy is dropped and the rest of the edit applies.
     *
     * Content from this edit's own change is kept even when its ID collides: the
     * delimiters an element split consumes are simulated rather than replayed,
     * so an ID issued here can legitimately collide, and dropping it would lose
     * a node the client already inserted.
     *
     * Dropping rather than failing is deliberate: such changes are already in
     * the history of existing documents, and a change that cannot be replayed is
     * a document that can never be loaded again. A collision anywhere in a
     * content node's subtree drops that whole subtree, on the grounds that a
     * copy is copied whole.
     *
     * - Parameters:
     *   - contents: The content nodes this edit is about to insert.
     *   - editedAt: The ticket of the edit inserting them.
     * - Returns: The subset of `contents` whose IDs are free.
     */
    func dropDuplicateContents(_ contents: [CRDTTreeNode], _ editedAt: TimeTicket) -> [CRDTTreeNode] {
        contents.filter { content in
            var reused = false
            traverseAll(node: content) { node, _ in
                let createdAt = node.id.createdAt
                if createdAt.lamport == editedAt.lamport, createdAt.actorID == editedAt.actorID {
                    return
                }

                if let entry = self.nodeMapByID.floorEntry(node.id), entry.key == node.id {
                    reused = true
                }
            }

            return reused == false
        }
    }

    /**
     * `registerPendingGCPair` buffers a GC pair for a node that was born
     * tombstoned (split off an already-removed node). The pair is picked up
     * by the next `edit` or `style` call via `drainPendingGCPairs`. `size`
     * is the net-new size created by the split; it is accounted to
     * docSize.gc at registration since the node was never live.
     */
    func registerPendingGCPair(_ node: CRDTTreeNode, _ size: DataSize) {
        self.pendingGCPairs.append(GCPair(parent: self, child: node, gcOnlySize: size))
    }

    /**
     * `drainPendingGCPairs` returns the buffered GC pairs and clears the
     * buffer.
     */
    func drainPendingGCPairs() -> [GCPair] {
        let pairs = self.pendingGCPairs
        self.pendingGCPairs = []
        return pairs
    }

    /**
     * `findNodesAndSplitText` finds `TreePos` of the given `CRDTTreeNodeID` and
     * splits nodes for the given split level.
     *
     * The ids of the given `pos` are the ids of the node in the CRDT perspective.
     * This is different from `TreePos` which is a position of the tree in the
     * physical perspective.
     *
     * `boundary` selects how a position inside a merged-away parent resolves:
     * ``PosBoundary/insert`` places it at the insertion boundary in the merge
     * target (before the first moved child, so RGA ordering breaks ties), while
     * ``PosBoundary/range`` places it right after the merge-source tombstone so a
     * style range neither grows over nor shrinks past nodes concurrently inserted
     * at that anchor.
     */
    func findNodesAndSplitText(
        _ pos: CRDTTreePos,
        _ editedAt: TimeTicket? = nil,
        _ boundary: PosBoundary = .insert
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
            // §9.3 Range Boundary at Merged-Away Anchors: a range boundary
            // resolves to the position right after the merge-source tombstone,
            // not the insertion boundary below. The insertion boundary sits
            // before the first moved child, so it would extend a style range over
            // nodes concurrently inserted between the tombstone and the moved
            // children — nodes the styling client saw outside its range (after
            // the then-live parent).
            if boundary == .range, let tombstoneParent = realParent.parent {
                return ((tombstoneParent, realParent), diff)
            }
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
     *
     * - Returns: A tuple of GC pairs, tree changes, data size delta, previous attribute values
     *   captured from the first styled node (for undo reverse op), and keys of attributes that
     *   did not previously exist on the first styled node (for undo reverse op).
     */
    @discardableResult
    func style(
        _ range: TreePosRange,
        _ attributes: [String: String]?,
        _ editedAt: TimeTicket,
        _ versionVector: VersionVector?
    ) throws -> ([GCPair], [TreeChange], DataSize, [String: String], [String]) {
        var diff = DataSize(data: 0, meta: 0)
        let ((fromParent, fromLeftRaw), fromDiff) = try self.findNodesAndSplitText(range.0, editedAt, .range)
        let ((toParent, toLeftRaw), toDiff) = try self.findNodesAndSplitText(range.1, editedAt, .range)
        diff.addDataSizes(others: fromDiff, toDiff)

        // Advance past split siblings unknown to the editing client so the range
        // covers all concurrent split products. Skip when leftNode == parent.
        let fromLeft = fromLeftRaw !== fromParent ? self.advancePastUnknownSplitSiblings(fromLeftRaw, versionVector) : fromLeftRaw
        let toLeft = toLeftRaw !== toParent ? self.advancePastUnknownSplitSiblings(toLeftRaw, versionVector) : toLeftRaw

        var changes: [TreeChange] = []
        var pairs = [GCPair]()
        var prevAttributes = [String: String]()
        var newAttrKeys = [String]()
        var capturedPrev = false
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

                // Capture previous attribute values from the first styled node
                // for the reverse operation (undo).
                if !capturedPrev {
                    for key in attributes.keys {
                        // A tombstoned (removed) attribute counts as absent, so the
                        // reverse op removes the key rather than restoring a stale value.
                        if node.attrs?.has(key: key) == true, let existing = node.attrs?.getNodeByKey(key)?.value {
                            prevAttributes[key] = existing
                        } else {
                            newAttrKeys.append(key)
                        }
                    }
                    capturedPrev = true
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

                // Propagate style to unknown split siblings so that a style
                // operation whose range was determined before the split also
                // covers the right part of the split node.
                if tokenType == .start, let versionVector {
                    var current = node
                    while let insNextID = current.insNextID {
                        guard let next = self.findFloorNode(insNextID), !next.isText else {
                            break
                        }
                        if ticketKnown(versionVector, next.id.createdAt) {
                            break
                        }
                        let siblingPairs = next.setAttrs(attributes, editedAt)
                        var siblingAffectedAttrs = [String: String]()
                        for (_, curr) in siblingPairs {
                            if let key = curr?.key {
                                siblingAffectedAttrs[key] = attributes[key]
                            }
                        }
                        if !siblingAffectedAttrs.isEmpty {
                            let parentOfNext = next.parent!
                            let previousNext = next.prevSibling ?? next.parent!
                            try changes.append(TreeChange(actor: editedAt.actorID,
                                                          type: .style,
                                                          from: self.toIndex(parentOfNext, previousNext),
                                                          to: self.toIndex(next, next),
                                                          fromPath: self.toPath(parentOfNext, previousNext),
                                                          toPath: self.toPath(next, next),
                                                          value: TreeChangeValue.attributes(siblingAffectedAttrs),
                                                          splitLevel: 0))
                            for (prev, _) in siblingPairs where prev != nil {
                                pairs.append(GCPair(parent: next, child: prev))
                            }
                        }
                        for attr in attributes {
                            let key = attr.key
                            let curr = next.attrs?.getNodeByKey(key)
                            if let curr {
                                diff.addDataSizes(others: curr.getDataSize())
                            }
                        }
                        current = next
                    }
                }
            }
        }

        pairs.append(contentsOf: self.drainPendingGCPairs())

        return (pairs, changes, diff, prevAttributes, newAttrKeys)
    }

    /**
     * `removeStyle` removes the given attributes of the given range.
     *
     * - Returns: A tuple of GC pairs, tree changes, data size delta, and previous attribute values
     *   captured from the first styled node (for undo reverse op).
     */
    func removeStyle(
        _ range: TreePosRange,
        _ attributesToRemove: [String],
        _ editedAt: TimeTicket,
        _ versionVector: VersionVector? = nil
    ) throws -> ([GCPair], [TreeChange], DataSize, [String: String]) {
        var diff = DataSize(data: 0, meta: 0)
        let ((fromParent, fromLeftRaw), fromDiff) = try self.findNodesAndSplitText(range.0, editedAt, .range)
        let ((toParent, toLeftRaw), toDiff) = try self.findNodesAndSplitText(range.1, editedAt, .range)
        diff.addDataSizes(others: fromDiff, toDiff)

        // Advance past split siblings unknown to the editing client so the range
        // covers all concurrent split products. Skip when leftNode == parent.
        let fromLeft = fromLeftRaw !== fromParent ? self.advancePastUnknownSplitSiblings(fromLeftRaw, versionVector) : fromLeftRaw
        let toLeft = toLeftRaw !== toParent ? self.advancePastUnknownSplitSiblings(toLeftRaw, versionVector) : toLeftRaw

        var changes: [TreeChange] = []
        var pairs = [GCPair]()
        let value = TreeChangeValue.attributesToRemove(attributesToRemove)
        var prevAttributes = [String: String]()
        var capturedPrev = false

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

                // Capture previous attribute values from the first styled node
                // for the reverse operation (undo).
                if !capturedPrev {
                    for key in attributesToRemove where node.attrs?.has(key: key) == true {
                        if let existing = node.attrs?.getNodeByKey(key)?.value {
                            prevAttributes[key] = existing
                        }
                    }
                    capturedPrev = true
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

                // Propagate remove-style to unknown split siblings so that a
                // removeStyle operation whose range was determined before the
                // split also covers the right part of the split node.
                if tokenType == .start, let versionVector {
                    var current = node
                    while let insNextID = current.insNextID {
                        guard let next = self.findFloorNode(insNextID), !next.isText else {
                            break
                        }
                        if ticketKnown(versionVector, next.id.createdAt) {
                            break
                        }
                        if next.attrs == nil {
                            next.attrs = RHT()
                        }
                        var removedAny = false
                        for key in attributesToRemove {
                            let nodesToBeRemoved = next.attrs!.remove(key: key, executedAt: editedAt)
                            removedAny = removedAny || !nodesToBeRemoved.isEmpty
                            for rhtNode in nodesToBeRemoved {
                                pairs.append(GCPair(parent: next, child: rhtNode))
                            }
                        }
                        if removedAny {
                            let parentOfNext = next.parent!
                            let previousNext = next.prevSibling ?? next.parent!
                            try changes.append(TreeChange(actor: editedAt.actorID,
                                                          type: .removeStyle,
                                                          from: self.toIndex(parentOfNext, previousNext),
                                                          to: self.toIndex(next, next),
                                                          fromPath: self.toPath(parentOfNext, previousNext),
                                                          toPath: self.toPath(next, next),
                                                          value: TreeChangeValue.attributesToRemove(attributesToRemove),
                                                          splitLevel: 0))
                        }
                        current = next
                    }
                }
            }
        }

        pairs.append(contentsOf: self.drainPendingGCPairs())

        return (pairs, changes, diff, prevAttributes)
    }

    /**
     * `applySplitLevel` performs the `splitLevel` ancestor splits for an edit,
     * advancing past concurrent split siblings at each level (§7.5/§7.7) and
     * skipping the current operation's own split products.
     */
    private func applySplitLevel(_ splitLevel: Int32, from: (parent: CRDTTreeNode, left: CRDTTreeNode), editedAt: TimeTicket, issueTimeTicket: () -> TimeTicket, versionVector: VersionVector?) throws {
        var splitCount: Int32 = 0
        var parent = from.parent
        var left: CRDTTreeNode = from.left
        while splitCount < splitLevel {
            // §7.5 Per-Iteration Advance: advance past unknown element split
            // siblings at the current ancestor level. skipActorID (§7.7) prevents
            // advancing past our own split products.
            if left !== parent {
                left = self.advancePastUnknownSplitSiblings(
                    left,
                    versionVector,
                    relaxParentCheck: true,
                    skipActorID: editedAt.actorID
                )
                if let leftParent = left.parent, leftParent !== parent {
                    parent = leftParent
                }
            }

            // Stop the walk once the node to split has no parent. Splitting the
            // root dereferences its nil parent, so the guard must precede the
            // split rather than follow it.
            guard let nextParent = parent.parent else {
                break
            }

            let rawOffset = left !== parent ? try parent.findOffset(node: left, includeRemoved: true) + 1 : 0
            try parent.split(self, Int32(rawOffset), issueTimeTicket(), versionVector)
            left = parent
            parent = nextParent
            splitCount += 1
        }
    }

    /// `narrowedCollectRange` narrows the edit traversal range when `fromLeft` and
    /// `toLeft` straddle a concurrent element split: it follows `fromLeft`'s
    /// `insNextID` chain to find a split sibling in `toParent`. Returns the
    /// (parent, left) pair to traverse; the original `fromParent`/`fromLeft` are
    /// preserved by the caller for the merge, split, and insert steps.
    /// VV-independent for clone/root consistency.
    ///
    /// - Parameters:
    ///   - fromParent: The parent node at the start of the edit range.
    ///   - fromLeft: The left sibling node at the start of the edit range.
    ///   - toParent: The parent node at the end of the edit range.
    ///   - toLeft: The left sibling node at the end of the edit range. When
    ///     `toLeft === toParent` (offset 0, leftmost child position), narrowing
    ///     is skipped because the narrowed `collectFromLeft` would be a child at
    ///     offset >= 1, producing a backwards range that suppresses the intended merge.
    private func narrowedCollectRange(fromParent: CRDTTreeNode, fromLeft: CRDTTreeNode, toParent: CRDTTreeNode, toLeft: CRDTTreeNode) -> (CRDTTreeNode, CRDTTreeNode) {
        guard fromLeft !== fromParent, fromParent !== toParent else {
            return (fromParent, fromLeft)
        }
        var current = fromLeft
        while let insNextID = current.insNextID {
            guard let next = self.findFloorNode(insNextID), !next.isText else {
                break
            }
            if let nextParent = next.parent, nextParent === toParent {
                // Skip narrowing when toLeft === toParent (leftmost child
                // position, offset 0). The narrowed collectFromLeft would be
                // a child at offset >= 1, producing a backwards range that
                // suppresses the intended merge.
                if toLeft !== toParent {
                    return (toParent, next)
                }
                break
            }
            current = next
        }
        return (fromParent, fromLeft)
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
    ) throws -> ([TreeChange], [GCPair], DataSize, [CRDTTreeNode], Int, Int, Set<String>, [TreeRestoreSpan], [TreeRestoreSpan], Int) {
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

        // Phase 3: Range Narrowing — narrow the traversal range when fromLeft and
        // toLeft straddle a concurrent element split. The original
        // fromParent/fromLeft are preserved for merge, split, and insert steps.
        let (collectFromParent, collectFromLeft) = self.narrowedCollectRange(fromParent: fromParent, fromLeft: fromLeft, toParent: toParent, toLeft: toLeft)

        let fromIdx = try self.toIndex(fromParent, fromLeft)
        let fromPath = try self.toPath(fromParent, fromLeft)

        var nodesToBeRemoved = [CRDTTreeNode]()
        var tokensToBeRemoved = [TreeToken<CRDTTreeNode>]()
        var toBeMovedToFromParents = [CRDTTreeNode]()
        var toBeMergedNodes = [CRDTTreeNode]()
        var preTombstoned = Set<String>()
        try self.traverseInPosRange(collectFromParent, collectFromLeft, toParent, toLeft, includeRemoved: true) { treeToken, ended in
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
                    // Include removed children (innerChildren) so tombstones move
                    // with the merge and survive as RGA anchors; a concurrent
                    // insert referencing one then resolves in the merge target
                    // and orders via the RGA tie-break.
                    toBeMovedToFromParents.append(contentsOf: node.innerChildren)
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
                    // Track nodes already tombstoned before this edit so the
                    // reverse operation does not accidentally resurrect them.
                    if node.isRemoved {
                        preTombstoned.insert(node.toIDString)
                    }
                    nodesToBeRemoved.append(node)

                    // Cascade delete to split siblings created by concurrent
                    // SplitElement. Only for element nodes.
                    if !node.isText, node.insNextID != nil, !toBeMergedNodes.contains(where: { $0 === node }) {
                        nodesToBeRemoved.append(contentsOf: self.collectUnknownSplitSiblings(of: node, versionVector))
                    }
                }
                tokensToBeRemoved.append((node, tokenType))
            }
        }

        // NOTE(hackerwins): If concurrent deletion happens, we need to seperate the
        // range(from, to) into multiple ranges.
        var changes = try self.makeDeletionChanges(tokensToBeRemoved, editedAt)

        // 01-2. Count merged nodes before children are moved (step 03).
        // The undo system uses this count to generate a split reverse op
        // instead of re-inserting empty shells.
        let mergeLevel = toBeMergedNodes.count

        // 02. Delete: delete the nodes that are marked as removed.
        var (pairs, removedSpans) = self.applyDeletions(nodesToBeRemoved, editedAt)
        // Captured in the insert phase: identity spans of the nodes this edit
        // inserts, so an undo re-removes them by identity (not by index, which
        // would clobber concurrently-restored content) and a redo revives them.
        var insertedSpans = [TreeRestoreSpan]()
        // Track how many GC pairs exist right after the plain-delete loop; if the
        // merge phases (steps 03/03-1) add more, this edit involved merge-child
        // propagation and its captured spans are NOT a complete description of
        // the deletion — the op layer then falls back to the copy-reinsert
        // reverse.
        let deletePairCount = pairs.count

        // 03. Merge: move the nodes that are marked as moved, then set the
        // forwarding pointer on merge-source nodes. Returns the resolved
        // destination, which differs from `fromParent` in a chained merge.
        let mergeDest = try self.applyMergeMoves(toBeMovedToFromParents, fromParent, editedAt)

        // 03-1. Propagate deletes to children moved by prior merges. When a
        // merge-source node is fully deleted (not a merge boundary), its former
        // children in the merge target should also be deleted.
        pairs.append(contentsOf: self.propagateDeletesToMergedChildren(nodesToBeRemoved, mergeDest, toBeMergedNodes, editedAt))

        // 04. Split: split the element nodes for the given split level.
        if splitLevel > 0 {
            try self.applySplitLevel(splitLevel, from: (fromParent, fromLeft), editedAt: editedAt, issueTimeTicket: issueTimeTicket, versionVector: versionVector)

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
        //
        // The identity check runs here rather than on entry: resolving the range
        // above splits text nodes, and a split can create the very ID a content
        // node carries. Checking before that would let the copy through and leave
        // two nodes under one ID. `insertedContentSize` is measured now, while the
        // content is still detached — inserting under a removed parent tombstones
        // it and shrinks what its size reads back as.
        let contents = contents.map { self.dropDuplicateContents($0, editedAt) }
        let insertedContentSize = contents?.reduce(0) { $0 + $1.paddedSize } ?? 0

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
                        diff.addDataSizes(others: node.getDataSize())
                    }

                    self.registerNode(node)

                    // Capture this inserted node's identity span for
                    // identity-preserving insert undo/redo.
                    insertedSpans.append(self.makeRestoreSpan(node))
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
        pairs.append(contentsOf: self.drainPendingGCPairs())

        // Identity-preserving restore only covers plain deletions. If this edit
        // merged nodes, or its merge propagation removed extra nodes, the
        // captured spans don't fully describe the deletion → signal the op layer
        // (empty spans) to keep the copy-reinsert reverse.
        let spansComplete = mergeLevel == 0 && pairs.count == deletePairCount

        // `traverseAll` is post-order (children before parent), so reverse to get
        // parent-before-child — the order `restore` needs to recreate a purged
        // subtree top-down (a child's recreate resolves its parent by identity).
        let outRemoved = spansComplete ? removedSpans : []
        let outInserted = spansComplete ? Array(insertedSpans.reversed()) : []
        return (changes, pairs, diff, nodesToBeRemoved, fromIdx, mergeLevel, preTombstoned, outRemoved, outInserted, insertedContentSize)
    }

    /**
     * `applyMergeMoves` moves each node marked for merge into `fromParent`,
     * recording `mergedFrom`/`mergedAt` (both persisted in the snapshot encoding;
     * `mergedAt` is captured here because the source's `removedAt` may be
     * overwritten by a later LWW tombstone) and re-parenting it from its old
     * parent. It then sets the `mergedInto` forwarding cache on the merge-source
     * nodes.
     */
    private func applyMergeMoves(_ toBeMovedToFromParents: [CRDTTreeNode], _ fromParent: CRDTTreeNode, _ editedAt: TimeTicket) throws -> CRDTTreeNode {
        // §6.3 Chained-Merge Flattening: a merge chain P->Q->R is kept flat so
        // runtime state matches what `rebuildMergeState` derives from a snapshot
        // (which can only ever represent the compressed chain, because it records
        // one `mergedFrom` pointer per child and reads the child's final physical
        // parent). The destination is resolved through `resolveMergeTarget`, so
        // children merged into an already-merged-away parent forward to the final
        // live target instead of piling up under the removed intermediate.
        let dest = self.resolveMergeTarget(fromParent)
        for node in toBeMovedToFromParents {
            // A moved child must have a source parent to record; skip otherwise
            // rather than append an untracked node (a node without `mergedFrom`
            // is invisible to the merge-delete propagation and rebuild logic).
            guard let parent = node.parent else {
                continue
            }
            // Tombstoned children are moved too (kept removed): they stay as RGA
            // anchors so a concurrent insert referencing one resolves in the
            // merge target and orders via the RGA tie-break, converging with the
            // replica that inserted before the merge. `moveChild` keeps the size
            // accounting correct for both live and tombstoned children
            // (visible-neutral for the latter), so index positions stay correct.
            //
            // `mergedFrom` and `mergedAt` are stamped together, only on the first
            // move, so a child carried through a chained merge keeps its original
            // source P and the original P->Q merge ticket. Stamping `mergedAt` on
            // every move would diverge: a replica that applied P->Q then Q->R
            // would record the Q->R ticket, while a replica where Q was already
            // merged records the P->Q ticket on the single forwarded move.
            if node.mergedFrom == nil {
                node.mergedFrom = parent.id
                node.mergedAt = editedAt
            }
            try dest.moveChild(child: node)
            // Point this child's original source at the resolved destination,
            // path-compressing a transitive source (a prior merge whose children
            // were just relocated again) from the now-removed intermediate to the
            // final target. This runtime cache is rebuilt from `mergedFrom` on
            // snapshot load. Deriving `mergedInto` from a *moved* child — one that
            // had a parent above — mirrors `rebuildMergeState`, which likewise
            // skips parentless children, so runtime and snapshot agree. (A
            // parentless child, detached by a concurrent split cascade, is
            // skipped above and must not repoint its source here.)
            //
            // `mergedInto` is set solely from moved children (never from the
            // merge-source list directly), so it is set only when
            // `rebuildMergeState` can reconstruct it — a source with no moved
            // child of its own (e.g. an intermediate that only relayed another
            // source's children) is left unset on both paths, keeping runtime and
            // snapshot consistent.
            if let mergedFrom = node.mergedFrom, let src = self.findFloorNode(mergedFrom) {
                src.mergedInto = dest.id
            }
        }

        return dest
    }

    /**
     * `collectUnknownSplitSiblings` walks the `insNextID` chain from the given
     * node and collects the split siblings (and their subtrees) whose creation
     * the editor did not know about, so they can be cascade-deleted alongside
     * the node being removed.
     */
    private func collectUnknownSplitSiblings(of node: CRDTTreeNode, _ versionVector: VersionVector?) -> [CRDTTreeNode] {
        var result = [CRDTTreeNode]()
        var nextID = node.insNextID
        while let id = nextID, let next = self.findFloorNode(id) {
            if !ticketKnown(versionVector, next.id.createdAt) {
                result.append(next)
                // Cascade through the full subtree, not just immediate children.
                traverseAll(node: next) { descendant, _ in
                    if descendant !== next {
                        result.append(descendant)
                    }
                }
            }
            if next.insNextID == nil {
                break
            }
            nextID = next.insNextID
        }
        return result
    }

    /**
     * `propagateDeletesToMergedChildren` tombstones the children (and their
     * descendants) that a prior merge moved out of each fully-deleted
     * merge-source node into its merge target. Skips merge boundaries and the
     * concurrent-merge case where `mergedInto` points back at `fromParent`. The
     * moved children are recomputed from the merge target's children filtered by
     * `mergedFrom`. Returns the GC pairs for the newly tombstoned nodes.
     */
    /// Skips when `mergedInto` points to the merge destination (concurrent
    /// merge). The comparison is against the resolved `dest`, not `fromParent`:
    /// the forwarding pointers set by ``applyMergeMoves(_:_:_:)`` point at the
    /// flattened target, so a chained merge (`dest !== fromParent`) must
    /// recognise a concurrent-merge boundary by `dest`.
    private func propagateDeletesToMergedChildren(_ nodesToBeRemoved: [CRDTTreeNode], _ dest: CRDTTreeNode, _ toBeMergedNodes: [CRDTTreeNode], _ editedAt: TimeTicket) -> [GCPair] {
        var pairs = [GCPair]()
        for node in nodesToBeRemoved {
            guard let mergedInto = node.mergedInto,
                  !toBeMergedNodes.contains(where: { $0 === node }),
                  mergedInto != dest.id,
                  let mergeTarget = self.findFloorNode(mergedInto)
            else {
                continue
            }
            for targetChild in mergeTarget.innerChildren {
                guard let childMergedFrom = targetChild.mergedFrom,
                      childMergedFrom == node.id,
                      targetChild.removedAt == nil
                else {
                    continue
                }
                if targetChild.remove(editedAt) {
                    pairs.append(GCPair(parent: self, child: targetChild))
                }
                // Also tombstone descendants if the moved child is an element.
                traverseAll(node: targetChild) { descendant, _ in
                    if descendant !== targetChild, descendant.removedAt == nil, descendant.remove(editedAt) {
                        pairs.append(GCPair(parent: self, child: descendant))
                    }
                }
            }
        }
        return pairs
    }

    /// `editT` edits the given range with the given value.
    /// Uses integer indexes instead of a ``CRDTTreePos`` pair. For testing only.
    @discardableResult
    func editT(
        _ range: (Int, Int),
        _ contents: [CRDTTreeNode]?,
        _ splitLevel: Int32,
        _ editedAt: TimeTicket,
        _ issueTimeTicket: () -> TimeTicket
    ) throws -> ([TreeChange], [GCPair], DataSize, [CRDTTreeNode], Int, Int, Set<String>, [TreeRestoreSpan], [TreeRestoreSpan], Int) {
        let fromPos = try self.findPos(range.0)
        let toPos = try self.findPos(range.1)
        return try self.edit(
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
    func toIndex(_ parentNode: CRDTTreeNode, _ leftNode: CRDTTreeNode, _ includeRemoved: Bool = false) throws -> Int {
        guard let treePos = try self.toTreePos(parentNode, leftNode, includeRemoved) else {
            return -1
        }

        return try self.indexTree.indexOf(treePos, includeRemoved)
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
                                    includeRemoved: Bool = false,
                                    callback: @escaping (TreeToken<CRDTTreeNode>, Bool) throws -> Void) throws
    {
        let fromIdx = try self.toIndex(fromParent, fromLeft, includeRemoved)
        let toIdx = try self.toIndex(toParent, toLeft, includeRemoved)

        // When a concurrent merge redirects the to-position into an earlier part
        // of the tree, the range becomes empty (prior merge handled it).
        if fromIdx > toIdx {
            return
        }

        return try self.indexTree.tokensBetween(fromIdx, toIdx, includeRemoved, callback)
    }

    /**
     * `toTreePos` converts the given CRDTTreePos to local TreePos<CRDTTreeNode>.
     */
    private func toTreePos(_ parentNode: CRDTTreeNode, _ leftNode: CRDTTreeNode, _ includeRemoved: Bool = false) throws -> TreePos<CRDTTreeNode>? {
        var parentNode = parentNode

        if !includeRemoved, parentNode.isRemoved {
            var childNode = parentNode
            while parentNode.isRemoved {
                childNode = parentNode
                parentNode = childNode.parent!
            }

            let childOffset = try parentNode.findOffset(node: childNode, includeRemoved: includeRemoved)

            return TreePos(node: parentNode, offset: Int32(childOffset))
        }

        if parentNode === leftNode {
            return TreePos(node: parentNode, offset: 0)
        }

        var offset = try parentNode.findOffset(node: leftNode, includeRemoved: includeRemoved)

        if includeRemoved || leftNode.isRemoved == false {
            if leftNode.isText {
                return TreePos(node: leftNode, offset: Int32(leftNode.paddedLength(includeRemoved: includeRemoved)))
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
        // `nodeMapByID` is keyed by ID, so an unconditional remove would also
        // unregister a different node that shares this one's ID — see
        // ``registerNode(_:)``. Only drop the entry this node actually holds.
        if let entry = self.nodeMapByID.floorEntry(node.id), entry.value === node, entry.key == node.id {
            self.nodeMapByID.remove(node.id)
        }

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
        // NOTE: `traverse` only visits visible children, which never includes
        // removed nodes. `traverseAll` is required to register tombstones
        // (including pieces split off a tombstoned node) after snapshot load.
        // These pairs carry `gcOnlySize` because `getDataSize` of the freshly
        // built root only counted visible nodes into docSize.live.
        self.indexTree.traverseAll { node, _ in
            if node.removedAt != nil {
                pairs.append(GCPair(parent: self, child: node, gcOnlySize: node.getDataSize()))
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

// MARK: - Identity-preserving Tree undo/redo (yorkie-js-sdk#1297)

extension CRDTTree {
    /**
     * `applyDeletions` tombstones each node this edit removes and captures one
     * ``TreeRestoreSpan`` per node it actually transitioned visible → tombstoned.
     *
     * `remove` returning true is exactly that transition, so pre-tombstoned nodes
     * and LWW overwrites are excluded automatically. `nodesToBeRemoved` is in
     * traversal order → parents precede children, which ``restore(_:)`` relies on
     * when recreating purged subtrees.
     */
    private func applyDeletions(_ nodesToBeRemoved: [CRDTTreeNode], _ editedAt: TimeTicket) -> ([GCPair], [TreeRestoreSpan]) {
        var pairs = [GCPair]()
        var removedSpans = [TreeRestoreSpan]()
        for node in nodesToBeRemoved where node.remove(editedAt) {
            pairs.append(GCPair(parent: self, child: node))
            removedSpans.append(self.makeRestoreSpan(node))
        }
        return (pairs, removedSpans)
    }

    /**
     * `restore` re-establishes the nodes described by `spans` under their
     * ORIGINAL identities (identity-preserving Tree undo): live → skip
     * (idempotent), tombstoned → unremove in place, purged → recreate. Spans
     * must be in parent-before-child order (``edit(_:_:_:_:_:_:)`` captures them
     * that way).
     *
     * - Returns: a tuple of
     *   - `untombstoned`: nodes revived in place (the caller unregisters their GC
     *     pairs);
     *   - `recreated`: brand-new nodes rebuilt for purged ranges (the caller adds
     *     their size to Live);
     *   - `pairs`: pending GC pairs for born-removed remainders split off a removed
     *     straddler (the caller registers them BEFORE unregistering the
     *     un-tombstoned ones);
     *   - `diff`: the metadata overhead of splitting live straddlers (the caller
     *     `acc`s it to Live).
     */
    func restore(_ spans: [TreeRestoreSpan]) throws -> ([CRDTTreeNode], [CRDTTreeNode], [GCPair], DataSize) {
        var untombstoned = [CRDTTreeNode]()
        var recreated = [CRDTTreeNode]()
        var diff = DataSize(data: 0, meta: 0)

        for span in spans {
            if !span.isText {
                if let node = self.findFloorNode(span.id), node.id == span.id {
                    if node.isRemoved {
                        node.unremove()
                        untombstoned.append(node)
                    }
                    continue
                }
                if let created = try self.recreateFromSpan(span, span.id.offset, span.length) {
                    recreated.append(created)
                }
                continue
            }

            // Text: pieces may be split finer than the span, and a concurrent op
            // or a post-GC recreate can leave pieces whose boundaries straddle it.
            // Isolate the exact `[start, end)` sub-range out of every overlapping
            // piece — splitting at the span boundaries, live or removed — so all
            // replicas converge on identical text-node segmentation (the tree
            // analogue of ``RGATreeSplit.isolateRange``). Then revive the removed
            // parts and recreate the purged gaps.
            let start = span.id.offset
            let end = start + span.length
            let pieces = self.findPiecesOverlapping(span.id.createdAt, start, end)

            var cursor = start
            var pieceIdx = 0
            while cursor < end {
                let piece = pieceIdx < pieces.count ? pieces[pieceIdx] : nil
                let pieceStart = piece?.id.offset ?? Int32.max
                let pieceEnd = piece.map { $0.id.offset + Int32($0.size) } ?? Int32.max

                if let piece, pieceStart <= cursor {
                    let overlapEnd = Swift.min(pieceEnd, end)
                    let target = try self.isolateTextRange(piece, cursor, overlapEnd, &diff)
                    if target.isRemoved {
                        target.unremove()
                        untombstoned.append(target)
                    }
                    cursor = overlapEnd
                    if overlapEnd >= pieceEnd {
                        pieceIdx += 1
                    }
                } else {
                    let gapEnd = Swift.min(pieceStart, end)
                    if let created = try self.recreateFromSpan(span, cursor, gapEnd - cursor) {
                        recreated.append(created)
                    }
                    cursor = gapEnd
                }
            }
        }

        // Splitting a removed straddler buffers born-removed remainders as pending
        // GC pairs (see ``CRDTTreeNode.split(_:_:_:_:)``). The caller registers
        // these BEFORE unregistering the un-tombstoned targets, so a target that
        // was itself a split-born piece is walked gc -> live correctly (mirrors the
        // Text path).
        let pairs = self.drainPendingGCPairs()
        return (untombstoned, recreated, pairs, diff)
    }

    /**
     * `isolateTextRange` splits `piece` so that a node exactly covering the
     * absolute-offset interval `[from, to)` of its insertion exists, and returns
     * it. Splitting at the caller's boundaries — rather than skipping a piece that
     * straddles them — is what lets concurrent restores converge on the same
     * text-node segmentation across replicas (the tree analogue of
     * ``RGATreeSplit.isolateRange``). A live split's metadata overhead is added to
     * `diff`; a removed split buffers a pending GC pair internally (contributing
     * zero here).
     *
     * Requires `pieceStart <= from < to <= pieceEnd`.
     */
    private func isolateTextRange(
        _ piece: CRDTTreeNode,
        _ from: Int32,
        _ to: Int32,
        _ diff: inout DataSize
    ) throws -> CRDTTreeNode {
        var node = piece
        if from > node.id.offset {
            let (right, splitDiff) = try node.split(self, from - node.id.offset)
            diff.addDataSizes(others: splitDiff)
            // The caller's invariants (``restore(_:)``'s cursor, ``retombstone(_:_:)``'s
            // clamp) guarantee a real split here. Returning the unsplit — wider —
            // node instead would un-tombstone or re-tombstone content OUTSIDE the
            // span, silently diverging the replicas: precisely what isolating is
            // meant to prevent. Fail loudly rather than corrupt the document.
            guard let right else {
                throw YorkieError(
                    code: .errInvalidArgument,
                    message: "isolateTextRange: split failed at \(from) for piece \(node.id)"
                )
            }
            node = right
        }
        if to < node.id.offset + Int32(node.size) {
            let (_, splitDiff) = try node.split(self, to - node.id.offset)
            diff.addDataSizes(others: splitDiff)
        }
        return node
    }

    /**
     * `retombstone` re-deletes the nodes described by `spans` (redo of an
     * identity-preserving undo). Live pieces only; idempotent. A piece that
     * straddles a span boundary is split at that boundary so only the in-span range
     * is re-removed (symmetric with ``restore(_:)``'s isolate, so undo/redo stay
     * mirror images and segmentation stays convergent).
     *
     * - Returns: the GC pairs for the newly tombstoned nodes, and the live-split
     *   metadata overhead.
     */
    func retombstone(_ spans: [TreeRestoreSpan], _ executedAt: TimeTicket) throws -> ([GCPair], DataSize) {
        var pairs = [GCPair]()
        var diff = DataSize(data: 0, meta: 0)
        for span in spans {
            let start = span.id.offset
            let end = start + Swift.max(span.length, 1)
            let pieces: [CRDTTreeNode]
            if span.isText {
                pieces = self.findPiecesOverlapping(span.id.createdAt, start, end)
            } else if let node = self.findFloorNode(span.id), node.id == span.id {
                pieces = [node]
            } else {
                pieces = []
            }

            for piece in pieces {
                if piece.isRemoved {
                    continue
                }
                var target = piece
                if piece.isText {
                    let from = Swift.max(piece.id.offset, start)
                    let to = Swift.min(piece.id.offset + Int32(piece.size), end)
                    target = try self.isolateTextRange(piece, from, to, &diff)
                }
                if target.remove(executedAt) {
                    pairs.append(GCPair(parent: self, child: target))
                }
            }
        }
        return (pairs, diff)
    }

    /**
     * `findPiecesOverlapping` collects surviving pieces (live or tombstoned) of
     * the text insertion `createdAt` overlapping `[start, end)`, in ascending
     * offset order, via descending floorEntry probes.
     */
    private func findPiecesOverlapping(_ createdAt: TimeTicket, _ start: Int32, _ end: Int32) -> [CRDTTreeNode] {
        var pieces = [CRDTTreeNode]()
        var probe = end - 1
        while probe >= 0 {
            guard let node = self.findFloorNode(CRDTTreeNodeID(createdAt: createdAt, offset: probe)), node.isText else {
                break
            }
            let nodeStart = node.id.offset
            let nodeEnd = nodeStart + Int32(node.size)
            if nodeEnd <= start {
                break
            }
            if nodeStart < end, nodeEnd > start {
                pieces.append(node)
            }
            if nodeStart <= start {
                break
            }
            probe = nodeStart - 1
        }
        return pieces.reversed()
    }

    /**
     * `makeRestoreSpan` captures the identity span of `node` — its id, type,
     * content/attribute copy, and the external boundary anchors of its position
     * — so an undo can re-establish it later even if it has been GC-purged.
     */
    private func makeRestoreSpan(_ node: CRDTTreeNode) -> TreeRestoreSpan {
        var leftSiblingID: CRDTTreeNodeID?
        var rightSiblingID: CRDTTreeNodeID?
        let parent = node.parent
        if let parent {
            let siblings = parent.innerChildren
            if let idx = siblings.firstIndex(where: { $0 === node }) {
                if idx > 0 {
                    leftSiblingID = self.leftAnchorID(siblings[idx - 1])
                }
                if idx < siblings.count - 1 {
                    rightSiblingID = siblings[idx + 1].id
                }
            }
        }

        return TreeRestoreSpan(id: node.id,
                               nodeType: node.type,
                               isText: node.isText,
                               length: node.isText ? Int32(node.size) : 0,
                               value: node.isText ? node.value as NSString : nil,
                               attrs: node.attrs?.deepcopy(),
                               parentID: parent?.id,
                               leftSiblingID: leftSiblingID,
                               rightSiblingID: rightSiblingID)
    }

    /**
     * `recreateFromSpan` rebuilds a purged node (or purged text sub-range) under
     * its original identity and attaches it. Anchor ladder, each rung doing
     * floor-lookup + parent-identity check:
     *   (a) same-insertion successor/predecessor piece (text) → exact slot;
     *   (b) captured left boundary sibling still under this parent → after it;
     *   (c) captured right boundary sibling still under this parent → before it;
     *   (d) deterministic id-order fallback: insert among the parent's current
     *       children at the first position whose id compares greater than the
     *       node's id (a pure function of ids → identical on every replica).
     *
     * A genuinely absent parent → skip: the node stays unplaced/invisible, which
     * is convergent because every replica resolves parent-absent identically.
     */
    private func recreateFromSpan(_ span: TreeRestoreSpan, _ offset: Int32, _ length: Int32) throws -> CRDTTreeNode? {
        guard let parentID = span.parentID,
              let parent = self.findFloorNode(parentID),
              parent.id == parentID
        else {
            // Parent gone (purged, and not part of this undo's spans). Leave the
            // node unplaced; a later parent-restore will bring it back.
            return nil
        }

        let node: CRDTTreeNode
        if span.isText {
            // Slice in UTF-16 with an EXCLUSIVE end. Tree text offsets are UTF-16
            // throughout (`CRDTTreeNode.value`'s setter sets `size` from
            // `NSString.length`, and `splitText` slices with `NSString`), whereas
            // `String.substring(from:to:)` indexes by grapheme AND treats `to` as
            // inclusive — either would silently produce a node whose value and
            // `size` disagree with JS, corrupting ancestor index accounting.
            let base = Int(offset - span.id.offset)
            let source: NSString = span.value ?? ""
            guard base >= 0, length >= 0, base + Int(length) <= source.length else {
                return nil
            }
            let value = source.substring(with: NSRange(location: base, length: Int(length))) as NSString
            node = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: span.id.createdAt, offset: offset),
                                type: span.nodeType,
                                value: value)
        } else {
            node = CRDTTreeNode(id: span.id,
                                type: span.nodeType,
                                attributes: span.attrs?.deepcopy())
        }

        let siblings = parent.innerChildren

        // (a) same-insertion successor / predecessor piece (text): exact slot.
        if span.isText {
            if let succ = self.findFloorNode(CRDTTreeNodeID(createdAt: span.id.createdAt, offset: offset + length)),
               succ.isText, succ.parent === parent, succ.id.offset == offset + length,
               let succIdx = siblings.firstIndex(where: { $0 === succ })
            {
                try parent.insertAt(node, succIdx)
                self.registerNode(node)
                return node
            }
            if offset > span.id.offset || offset > 0 {
                if let pred = self.findFloorNode(CRDTTreeNodeID(createdAt: span.id.createdAt, offset: offset - 1)),
                   pred.isText, pred.parent === parent
                {
                    try parent.insertAfter(node, pred)
                    self.registerNode(node)
                    return node
                }
            }
        }

        // (b) captured left boundary sibling, if it still exists under this parent.
        if let leftSiblingID = span.leftSiblingID,
           let left = self.findFloorNode(leftSiblingID), left.parent === parent
        {
            try parent.insertAfter(node, left)
            self.registerNode(node)
            return node
        }

        // (c) captured right boundary sibling (redundant anchor): insert before it.
        if let rightSiblingID = span.rightSiblingID,
           let right = self.findFloorNode(rightSiblingID), right.parent === parent,
           let rightIdx = siblings.firstIndex(where: { $0 === right })
        {
            try parent.insertAt(node, rightIdx)
            self.registerNode(node)
            return node
        }

        // (d) deterministic id-order fallback: first slot whose child id > node id.
        // `CRDTTreeNodeID` is `Comparable` on (createdAt, offset), which is the
        // total order this rung needs.
        let insertIdx = siblings.firstIndex { $0.id > node.id } ?? siblings.count
        try parent.insertAt(node, insertIdx)
        self.registerNode(node)
        return node
    }

    /**
     * `leftAnchorID` returns the id to store as a restore span's left-sibling
     * anchor. For a text node the anchor is its LAST character's offset, not its
     * start: a concurrent delete may later split the left neighbour, and only the
     * last-char offset floor-resolves to the rightmost fragment (the true left
     * neighbour of the restored node). For elements (never split by offset) the
     * node's own id is exact. Right-sibling anchors always use the start offset,
     * which floor-resolves to the leftmost fragment — the true right neighbour.
     */
    private func leftAnchorID(_ sibling: CRDTTreeNode) -> CRDTTreeNodeID {
        guard sibling.isText else {
            return sibling.id
        }
        return CRDTTreeNodeID(createdAt: sibling.id.createdAt, offset: sibling.id.offset + Int32(sibling.size) - 1)
    }
}
