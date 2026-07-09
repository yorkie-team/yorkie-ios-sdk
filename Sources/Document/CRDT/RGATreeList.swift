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

import Foundation

// MARK: - RGATreeListElementEntry

/// Holds the stable identity of an element in the list.
///
/// A live element maps 1-to-1 with its current position node. When a move operation wins
/// the LWW race, the old position node becomes a *dead position node* (its `elementEntry`
/// is set to `nil`) and a new position node is inserted at the winning location.
final class RGATreeListElementEntry {
    /// The actual CRDT element.
    let element: CRDTElement

    /// The current winning position node for this element.
    ///
    /// Updated whenever a `moveAfter` wins the LWW race for this element.
    var positionNode: RGATreeListNode

    /// The `executedAt` of the move operation that established the current position.
    ///
    /// `nil` for elements that have never been moved. Mirrors `posMovedAt` in the JS implementation.
    var posMovedAt: TimeTicket?

    init(element: CRDTElement, positionNode: RGATreeListNode) {
        self.element = element
        self.positionNode = positionNode
        self.posMovedAt = nil
    }
}

// MARK: - RGATreeListNode

/// A node of ``RGATreeList``.
///
/// Each node represents a *position slot* in the list, not necessarily a live element.
/// A *dead position node* has `elementEntry == nil` and its `positionRemovedAt` is set;
/// it contributes zero to the index-tree weight and is a GC target.
final class RGATreeListNode {
    /// The element value carried by this position slot.
    ///
    /// Dead position nodes carry a `null` placeholder; callers must check
    /// `elementEntry == nil` to detect them rather than inspecting `value`.
    let value: CRDTElement

    /// The order-statistic index node backing this position in ``RGATreeList``'s
    /// `nodeMapByIndex`. Created once at construction and cleared when the
    /// position is physically purged (see ``RGATreeList``).
    var indexNode: TreeListNode<RGATreeListNode>!

    fileprivate var previous: RGATreeListNode?
    fileprivate var next: RGATreeListNode?

    /// The position creation time, which is the stable key for this position slot.
    ///
    /// For normal (non-moved) nodes this equals `value.createdAt`.
    /// For nodes inserted by `moveAfter`, this is the `executedAt` ticket of the move.
    private(set) var positionCreatedAt: TimeTicket

    /// Set when this position node is superseded by a later LWW-winning move.
    /// A non-nil value means this is a dead position node.
    private(set) var positionRemovedAt: TimeTicket?

    /// The ``RGATreeListElementEntry`` this position node is the winning slot for.
    /// `nil` for dead position nodes.
    private(set) var elementEntry: RGATreeListElementEntry?

    // MARK: Initializers

    /// Creates a node wrapping a live element.
    fileprivate init(value: CRDTElement, positionCreatedAt: TimeTicket) {
        self.value = value
        self.positionCreatedAt = positionCreatedAt
        // `indexNode` is implicitly nil here, so `self` is fully initialised and
        // may be captured by its backing index node.
        self.indexNode = TreeListNode(self)
    }

    /// Creates the sentinel dummy-head node.
    fileprivate static func createDummy() -> RGATreeListNode {
        let dummyValue = Primitive(value: .null, createdAt: .initial)
        dummyValue.removedAt = .initial
        let node = RGATreeListNode(value: dummyValue, positionCreatedAt: .initial)
        // Dummy head has no entry; it is never a GC target.
        return node
    }

    // MARK: Internal helpers

    /// The element-level `createdAt`, used to look up the element entry.
    fileprivate var createdAt: TimeTicket {
        return self.value.createdAt
    }

    /// The positioned-at time for insertion-order arbitration.
    ///
    /// Uses `positionCreatedAt` as the LWW register key, mirroring the JS implementation.
    fileprivate var positionedAt: TimeTicket {
        return self.positionCreatedAt
    }

    /// Returns `true` for a dead position node (no element) *or* when the
    /// underlying element has been removed.
    ///
    /// This is the weight predicate for ``TreeList``: such nodes contribute
    /// zero to the live (logical) index. It mirrors the JS `RGATreeListNode.isRemoved`.
    var isRemoved: Bool {
        guard let entry = self.elementEntry else {
            return true
        }
        return entry.element.isRemoved
    }

    /// A debug representation of the node's element, used by ``TreeList/toTestString``.
    var toTestString: String {
        guard let entry = self.elementEntry else {
            return ""
        }
        return entry.element.toJSON()
    }

    /// Removes the underlying element value at the given time.
    @discardableResult
    fileprivate func remove(_ at: TimeTicket) -> Bool {
        return self.value.remove(at)
    }

    /// Unlinks this node from its neighbours (doubly-linked list surgery).
    fileprivate func release() {
        if let previous {
            previous.next = self.next
        }
        if let next {
            next.previous = self.previous
        }
        self.previous = nil
        self.next = nil
    }

    // MARK: Public accessors

    /// Returns the position creation time, which is the stable identifier for this slot.
    func getPositionCreatedAt() -> TimeTicket {
        return self.positionCreatedAt
    }

    /// Returns the time at which this position slot was garbage-collected (killed).
    func getPositionRemovedAt() -> TimeTicket? {
        return self.positionRemovedAt
    }

    /// Returns the element entry for this position, or `nil` if this is a dead node.
    func getElementEntry() -> RGATreeListElementEntry? {
        return self.elementEntry
    }

    /// Marks this position node as dead by setting the removal time and clearing the entry.
    fileprivate func markDead(at removedAt: TimeTicket) {
        self.positionRemovedAt = removedAt
        self.elementEntry = nil
    }

    /// Attaches an element entry to this position node (used during snapshot restore).
    fileprivate func setElementEntry(_ entry: RGATreeListElementEntry?) {
        self.elementEntry = entry
    }
}

// MARK: TreeListValue conformance

extension RGATreeListNode: TreeListValue {}

// MARK: GCChild conformance

extension RGATreeListNode: GCChild {
    /// Returns the ID string keyed on `positionCreatedAt` so the GC pair map can
    /// address dead position nodes independently of their element's `createdAt`.
    var toIDString: String {
        return self.positionCreatedAt.toIDString
    }

    /// Returns the time this position node was killed (i.e., `positionRemovedAt`).
    var removedAt: TimeTicket? {
        return self.positionRemovedAt
    }

    /// Returns the meta data size of this position node: one ticket for the
    /// position, plus another when the position has been removed (matching JS).
    func getDataSize() -> DataSize {
        var meta = timeTicketSize
        if self.positionRemovedAt != nil {
            meta += timeTicketSize
        }
        return DataSize(data: 0, meta: meta)
    }
}

// MARK: - RGATreeList

/// A replicated growable array using an LWW position register for convergent array moves.
///
/// Each element has a stable identity held in ``RGATreeListElementEntry``, separate from
/// its current position slot. When two concurrent moves target the same element the one
/// with the later `executedAt` wins; the old position becomes a *dead position node*
/// that is eventually garbage-collected.
class RGATreeList {
    private let dummyHead: RGATreeListNode
    private var last: RGATreeListNode
    private let nodeMapByIndex: TreeList<RGATreeListNode>

    /// Maps a position node's `positionCreatedAt` to the node itself.
    private var nodeMapByPositionCreatedAt: [TimeTicket: RGATreeListNode]

    /// Maps an element's `createdAt` to its ``RGATreeListElementEntry``.
    private var elementMapByCreatedAt: [TimeTicket: RGATreeListElementEntry]

    init() {
        self.dummyHead = RGATreeListNode.createDummy()
        self.last = self.dummyHead
        self.nodeMapByIndex = TreeList(self.dummyHead.indexNode)
        self.nodeMapByPositionCreatedAt = [self.dummyHead.positionCreatedAt: self.dummyHead]
        self.elementMapByCreatedAt = [:]
    }

    deinit {
        // ARC cannot collect the intra-node reference cycles on its own: the
        // doubly-linked list (`previous`/`next`) and each node's `indexNode`
        // (which strongly holds the node back via `TreeListNode.value`) are all
        // strong. Walk the list once at teardown and clear these so the whole
        // node graph deallocates with the list rather than leaking.
        var node: RGATreeListNode? = self.dummyHead
        while let current = node {
            let next = current.next
            current.previous = nil
            current.next = nil
            current.indexNode = nil
            node = next
        }
    }

    // MARK: Length

    /// The number of live (non-removed) elements in this list.
    var length: Int {
        return self.nodeMapByIndex.length
    }

    // MARK: Private helpers

    /// Walks forward from `node` skipping nodes whose `positionedAt` is after `executedAt`.
    ///
    /// This is the LWW-correct way to find the insertion point: we skip over any
    /// concurrent insertions that were committed *after* `executedAt`.
    private func findNextBeforeExecutedAt(node: RGATreeListNode, executedAt: TimeTicket) -> RGATreeListNode {
        var current = node
        while let next = current.next, next.positionedAt > executedAt {
            current = next
        }
        return current
    }

    /// Removes `node` from the index tree and position map, updating `last` if needed.
    private func release(node: RGATreeListNode) {
        if self.last === node, let prev = node.previous {
            self.last = prev
        }

        node.release()
        self.nodeMapByIndex.delete(node.indexNode)
        // Break the node <-> index-node cycle so the purged position deallocates.
        node.indexNode = nil
        self.nodeMapByPositionCreatedAt.removeValue(forKey: node.positionCreatedAt)
    }

    // MARK: Core insertion (private)

    /// Inserts a node into the linked list and index tree after the anchor.
    ///
    /// The `node` must have its `elementEntry` set before this call if it is a live node,
    /// so that ``TreeList`` sees the correct `isRemoved` weight during insertion.
    private func insertNodeIntoStructures(node: RGATreeListNode, after anchor: RGATreeListNode) {
        // Link into doubly-linked list.
        let anchorNext = anchor.next
        anchor.next = node
        node.previous = anchor
        node.next = anchorNext
        anchorNext?.previous = node

        if anchor === self.last {
            self.last = node
        }

        self.nodeMapByIndex.insertAfter(anchor.indexNode, node.indexNode)
        self.nodeMapByPositionCreatedAt[node.positionCreatedAt] = node
    }

    /// Inserts a bare position node (no element) after the node identified by `prevPositionCreatedAt`.
    ///
    /// This is used by `moveAfter` for both the winning and losing LWW paths to create a
    /// new position slot. The node is inserted using RGA ordering (skipping concurrent nodes
    /// with later timestamps) and added to the index tree and position map.
    ///
    /// - Parameters:
    ///   - prevPositionCreatedAt: The `positionCreatedAt` of the node to insert after.
    ///   - executedAt: The `executedAt` of the move, used as the new node's `positionCreatedAt`.
    /// - Returns: The newly created position node.
    @discardableResult
    private func insertPositionAfter(prevPositionCreatedAt: TimeTicket, executedAt: TimeTicket) throws -> RGATreeListNode {
        guard let prevNode = self.nodeMapByPositionCreatedAt[prevPositionCreatedAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given node: \(prevPositionCreatedAt)")
        }
        let anchor = self.findNextBeforeExecutedAt(node: prevNode, executedAt: executedAt)
        // Use a null placeholder as the node value — callers must check `elementEntry == nil`
        // to detect bare position nodes rather than accessing `.value` directly.
        let placeholder = Primitive(value: .null, createdAt: executedAt)
        let node = RGATreeListNode(value: placeholder, positionCreatedAt: executedAt)
        // No elementEntry set — this is a bare position node.
        self.insertNodeIntoStructures(node: node, after: anchor)
        return node
    }

    // MARK: Public insert (used by CRDTArray / Converter)

    /// Inserts `value` after the element identified by `prevCreatedAt`.
    ///
    /// This is the normal (non-move) insertion path; the new position slot's key is
    /// set to `value.createdAt`. The `prevCreatedAt` is interpreted as either a position
    /// node key (checked first in `nodeMapByPositionCreatedAt`) or an element key
    /// (fallback via `elementMapByCreatedAt`), mirroring the JS `insertAfter` algorithm.
    @discardableResult
    func insert(
        _ value: CRDTElement,
        prevCreatedAt: TimeTicket,
        executedAt: TimeTicket? = nil
    ) throws -> RGATreeListNode {
        let et = executedAt ?? value.createdAt
        // Resolve prevCreatedAt to the correct anchor position node.
        // JS insertAfter checks nodeMapByCreatedAt (position map) first, then elementMapByCreatedAt.
        let anchorNode: RGATreeListNode
        if let directNode = self.nodeMapByPositionCreatedAt[prevCreatedAt] {
            // prevCreatedAt is a known position node key (covers dummy head, normal nodes, and
            // position-identity keys from moved nodes).
            anchorNode = directNode
        } else if let prevEntry = self.elementMapByCreatedAt[prevCreatedAt] {
            // prevCreatedAt is an element key — use the element's current position node.
            anchorNode = prevEntry.positionNode
        } else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given node: \(prevCreatedAt)")
        }
        let anchor = self.findNextBeforeExecutedAt(node: anchorNode, executedAt: et)
        let newNode = RGATreeListNode(value: value, positionCreatedAt: value.createdAt)

        // Create and attach the entry BEFORE index-tree insertion so that `newNode.isRemoved`
        // is false (weight 1) when the node is inserted in `insertNodeIntoStructures`.
        let entry = RGATreeListElementEntry(element: value, positionNode: newNode)
        newNode.setElementEntry(entry)
        self.elementMapByCreatedAt[value.createdAt] = entry

        self.insertNodeIntoStructures(node: newNode, after: anchor)
        return newNode
    }

    /// Appends `value` after the last node.
    func insert(_ value: CRDTElement) throws {
        // Use the last node's positionCreatedAt (position identity) as the anchor.
        try self.insert(value, prevCreatedAt: self.last.positionCreatedAt)
    }

    // MARK: moveAfter — LWW position register

    /// Moves the element identified by `createdAt` to after `prevCreatedAt`, returning
    /// the dead position node that must be registered as a GC pair.
    ///
    /// Faithful port of the yorkie-js-sdk v0.7.6 `moveAfter` algorithm:
    /// - **LWW winner**: Creates a new position node at `prevCreatedAt`, wires up the entry,
    ///   kills the old position node (sets `positionRemovedAt`), and returns it for GC.
    /// - **LWW loser**: Creates a bare dead position node at `prevCreatedAt` (no entry,
    ///   `positionRemovedAt = executedAt`), refreshes its index weight, and returns it for GC.
    ///   Returns `nil` only when the node was already processed (idempotency check).
    ///
    /// No cascade re-linking is performed — that is not in the JS specification.
    ///
    /// - Parameters:
    ///   - createdAt: The `createdAt` of the element to move (element identity).
    ///   - prevCreatedAt: The POSITION node key after which to insert (position identity).
    ///   - executedAt: The operation's execution time, used as the LWW clock.
    /// - Returns: The dead position node (GC target), or `nil` if already processed.
    /// - Throws: ``YorkieError`` when the target element or previous position cannot be found.
    @discardableResult
    func moveAfter(createdAt: TimeTicket, prevCreatedAt: TimeTicket, executedAt: TimeTicket) throws -> RGATreeListNode? {
        guard let entry = self.elementMapByCreatedAt[createdAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given element: \(createdAt)")
        }

        guard self.nodeMapByPositionCreatedAt[prevCreatedAt] != nil else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the previous node: \(prevCreatedAt)")
        }

        // Idempotency: if a node with this executedAt was already created, skip entirely.
        if self.nodeMapByPositionCreatedAt[executedAt] != nil {
            return nil
        }

        // LWW loser path — this move was superseded by a later move of the same element.
        if let posMovedAt = entry.posMovedAt, !executedAt.after(posMovedAt) {
            // Still create a bare dead position node so GC pairs are complete.
            let deadPosNode = try self.insertPositionAfter(prevPositionCreatedAt: prevCreatedAt, executedAt: executedAt)
            deadPosNode.markDead(at: executedAt)
            self.nodeMapByIndex.updateWeight(deadPosNode.indexNode)
            return deadPosNode
        }

        // LWW winner path.
        // Build the new position node carrying the actual element value (not a placeholder),
        // so callers that access `.value` on indexed nodes get the real element.
        let oldPosNode = entry.positionNode
        guard let prevNode = self.nodeMapByPositionCreatedAt[prevCreatedAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the previous node: \(prevCreatedAt)")
        }
        let anchor = self.findNextBeforeExecutedAt(node: prevNode, executedAt: executedAt)
        let newPosNode = RGATreeListNode(value: entry.element, positionCreatedAt: executedAt)

        // Wire the entry BEFORE index-tree insertion so `newPosNode.isRemoved` is false (weight 1).
        newPosNode.setElementEntry(entry)
        entry.positionNode = newPosNode
        entry.posMovedAt = executedAt
        _ = entry.element.setMovedAt(executedAt)

        self.insertNodeIntoStructures(node: newPosNode, after: anchor)

        // Kill the old position node. Keep it in the index tree with weight 0
        // (refresh weights) rather than deleting it — JS keeps dead position
        // nodes in the tree until GC purge, and a subsequent insert/append may
        // still use this node as its anchor (e.g. when it is `last` after a
        // tail move). Deleting it here would leave that anchor unresolvable in
        // the index tree, so the appended element would never be indexed.
        oldPosNode.markDead(at: executedAt)
        self.nodeMapByIndex.updateWeight(oldPosNode.indexNode)
        // NOTE: do NOT reassign `last` here. JS leaves `last` pointing at the
        // now-dead slot when the moved element was the tail, so that subsequent
        // ops emit the same position-identity anchor as JS/Go peers. The
        // newPosNode insertion above already advanced `last` in the only case
        // JS does (when the anchor was `last`).

        return oldPosNode
    }

    // MARK: Snapshot restore helpers

    /// Restores a dead position node from a snapshot.
    ///
    /// Called by `fromArray` when decoding a node that has `positionCreatedAt` +
    /// `positionRemovedAt` but **no** element (the JS wire format for dead nodes).
    /// Inserts the node into the index tree and updates `last`, exactly as JS `addDeadPosition` does.
    func addDeadPosition(
        positionCreatedAt: TimeTicket,
        positionRemovedAt: TimeTicket
    ) throws {
        let placeholder = Primitive(value: .null, createdAt: positionCreatedAt)
        let node = RGATreeListNode(value: placeholder, positionCreatedAt: positionCreatedAt)
        node.markDead(at: positionRemovedAt)

        let prevNode = self.last
        // Link into doubly-linked list.
        prevNode.next = node
        node.previous = prevNode
        // Update last (mirrors JS: `this.last = node`).
        self.last = node
        // Insert into index tree (mirrors JS: `this.nodeMapByIndex.insertAfter(prevNode.indexNode, node.indexNode)`).
        self.nodeMapByIndex.insertAfter(prevNode.indexNode, node.indexNode)
        self.nodeMapByPositionCreatedAt[positionCreatedAt] = node
    }

    /// Restores a moved element's position from a snapshot.
    ///
    /// Called by `fromArray` when decoding a node that has `element` +
    /// `positionCreatedAt` + `positionMovedAt`.
    func addMovedElement(
        value: CRDTElement,
        positionCreatedAt: TimeTicket,
        positionMovedAt: TimeTicket
    ) throws {
        guard let prevNode = self.nodeMapByPositionCreatedAt[self.last.positionCreatedAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the last node")
        }
        let anchor = self.findNextBeforeExecutedAt(node: prevNode, executedAt: positionCreatedAt)
        let node = RGATreeListNode(value: value, positionCreatedAt: positionCreatedAt)

        // Set entry BEFORE index-tree insertion so `node.isRemoved` is false (weight 1).
        let entry = RGATreeListElementEntry(element: value, positionNode: node)
        entry.posMovedAt = positionMovedAt
        node.setElementEntry(entry)
        self.elementMapByCreatedAt[value.createdAt] = entry

        self.insertNodeIntoStructures(node: node, after: anchor)
    }

    // MARK: Backward-compatible move (tests + JSONArray local path)

    /// Moves the element identified by `createdAt` after `afterCreatedAt`.
    ///
    /// Delegates to ``moveAfter(createdAt:prevCreatedAt:executedAt:)`` and discards the
    /// dead position node return value. GC pair registration is the caller's responsibility
    /// (``MoveOperation`` does it via ``CRDTArray/moveAfter(createdAt:prevCreatedAt:executedAt:)``).
    @discardableResult
    func move(createdAt: TimeTicket, afterCreatedAt: TimeTicket, executedAt: TimeTicket) throws -> RGATreeListNode? {
        return try self.moveAfter(createdAt: createdAt, prevCreatedAt: afterCreatedAt, executedAt: executedAt)
    }

    // MARK: Element access

    /// Returns the element for the given `createdAt`, or throws if not found.
    func get(createdAt: TimeTicket) throws -> CRDTElement {
        guard let entry = self.elementMapByCreatedAt[createdAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given node: \(createdAt)")
        }
        return entry.element
    }

    /// Returns the index string for the element with the given `createdAt`.
    func subPath(createdAt: TimeTicket) throws -> String {
        guard let entry = self.elementMapByCreatedAt[createdAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given node: \(createdAt)")
        }
        return String(self.nodeMapByIndex.indexOf(entry.positionNode.indexNode))
    }

    // MARK: Deletion

    /// Marks the element identified by `createdAt` as deleted at `executedAt`.
    @discardableResult
    func delete(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        guard let entry = self.elementMapByCreatedAt[createdAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given node: \(createdAt)")
        }
        let node = entry.positionNode
        let alreadyRemoved = node.isRemoved
        if node.remove(executedAt), !alreadyRemoved {
            self.nodeMapByIndex.updateWeight(node.indexNode)
        }
        return node.value
    }

    /// Deletes the element at `index`.
    @discardableResult
    func deleteByIndex(index: Int, executedAt: TimeTicket) throws -> CRDTElement {
        let node = try self.getNode(index: index)
        if node.remove(executedAt) {
            self.nodeMapByIndex.updateWeight(node.indexNode)
        }
        return node.value
    }

    // MARK: Purge (hard delete)

    /// Physically removes the element node from the list (GC final step).
    func purge(_ value: CRDTElement) throws {
        guard let entry = self.elementMapByCreatedAt[value.createdAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "failed to find the given createdAt: \(value.createdAt)")
        }
        let node = entry.positionNode
        self.release(node: node)
        self.elementMapByCreatedAt.removeValue(forKey: value.createdAt)
    }

    /// Physically removes a dead position node from the list (GC final step for move-dead slots).
    func purgeDeadPosition(positionCreatedAt: TimeTicket) {
        guard let node = self.nodeMapByPositionCreatedAt[positionCreatedAt] else {
            return
        }
        if self.last === node, let prev = node.previous {
            self.last = prev
        }
        node.release()
        self.nodeMapByIndex.delete(node.indexNode)
        // Break the node <-> index-node cycle so the purged position deallocates.
        node.indexNode = nil
        self.nodeMapByPositionCreatedAt.removeValue(forKey: positionCreatedAt)
    }

    // MARK: Set (replace element at position)

    /// Replaces the element at `createdAt` with `element`.
    @discardableResult
    func set(
        createdAt: TimeTicket,
        element: CRDTElement,
        executedAt: TimeTicket
    ) throws -> CRDTElement {
        guard let existingEntry = self.elementMapByCreatedAt[createdAt] else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "cant find the given node: \(createdAt.toIDString)"
            )
        }
        let prevPosCreatedAt = existingEntry.positionNode.positionCreatedAt
        try self.insert(element, prevCreatedAt: prevPosCreatedAt, executedAt: executedAt)
        return try self.delete(createdAt: createdAt, executedAt: executedAt)
    }

    // MARK: Node access by index

    /// Returns the position node at `index` in the index tree.
    func getNode(index: Int) throws -> RGATreeListNode {
        guard index < self.length else {
            throw YorkieError(code: .errInvalidArgument, message: "length is smaller than or equal to: \(index)")
        }
        return try self.nodeMapByIndex.find(index).getValue()
    }

    // MARK: Previous / last

    /// Returns the position `createdAt` of the node immediately before the element at `createdAt`.
    ///
    /// Returns the POSITION node's `positionCreatedAt` (position identity), not the element's
    /// `value.createdAt`. This matches the JS `findPrevCreatedAt` which returns
    /// `node.getPositionCreatedAt()`.
    func getPreviousCreatedAt(ofCreatedAt createdAt: TimeTicket) throws -> TimeTicket {
        guard let entry = self.elementMapByCreatedAt[createdAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given node: \(createdAt)")
        }
        var previousNode: RGATreeListNode? = entry.positionNode
        repeat {
            previousNode = previousNode?.previous
        } while self.dummyHead !== previousNode && previousNode?.isRemoved == true

        // Return POSITION identity (`positionCreatedAt`).
        // Dummy head's positionCreatedAt == .initial, which is the sentinel for "insert at front".
        return previousNode?.positionCreatedAt ?? self.dummyHead.positionCreatedAt
    }

    /// Returns the last element, skipping bare position nodes (created by
    /// `moveAfter`/`addDeadPosition`) that have no element.
    func getLast() -> CRDTElement {
        var node = self.last
        while node.elementEntry == nil, node !== self.dummyHead {
            guard let prev = node.previous else { break }
            node = prev
        }
        return node.value
    }

    /// Returns the POSITION `createdAt` of the last node.
    ///
    /// Returns `last.positionCreatedAt` (position identity), not element identity,
    /// mirroring the JS `getLastCreatedAt()` which calls `this.last.getPositionCreatedAt()`.
    func getLastCreatedAt() -> TimeTicket {
        return self.last.positionCreatedAt
    }

    /// Returns the dummy head's element.
    func getHead() -> CRDTElement {
        return self.dummyHead.value
    }

    /// Returns the dummy head's position creation time.
    func getHeadPositionCreatedAt() -> TimeTicket {
        return self.dummyHead.positionCreatedAt
    }

    /// Returns the current POSITION node key for the element identified by `elemCreatedAt`.
    ///
    /// Mirrors the JS `posCreatedAt(elemCreatedAt)` which returns
    /// `entry.positionNode.getPositionCreatedAt()`.
    func posCreatedAt(elemCreatedAt: TimeTicket) throws -> TimeTicket {
        guard let entry = self.elementMapByCreatedAt[elemCreatedAt] else {
            throw YorkieError(code: .errInvalidArgument, message: "can't find the given element: \(elemCreatedAt)")
        }
        return entry.positionNode.positionCreatedAt
    }

    // MARK: All nodes (for snapshot serialisation and GC registration)

    /// Returns all nodes in linked-list order, including dead position nodes.
    ///
    /// Used by the Converter to serialise the full list (including dead position
    /// slots) and by `CRDTRoot` to register dead position nodes as GC pairs.
    func allNodes() -> [RGATreeListNode] {
        var result: [RGATreeListNode] = []
        var current = self.dummyHead.next
        while let node = current {
            result.append(node)
            current = node.next
        }
        return result
    }

    // MARK: Debug

    /// Returns a human-readable representation for testing.
    ///
    /// Dead position nodes are excluded — tests assert on element order only.
    var toTestString: String {
        var parts: [String] = []
        var current = self.dummyHead.next
        while let node = current {
            if let entry = node.elementEntry {
                // Use element's own createdAt for test readability, matching the prior format.
                let str = "\(entry.element.createdAt):\(entry.element.toJSON())"
                if node.isRemoved {
                    parts.append("{\(str)}")
                } else {
                    parts.append("[\(str)]")
                }
            }
            // Dead position nodes (elementEntry == nil) are not rendered.
            current = node.next
        }
        return parts.joined(separator: "-")
    }
}

// MARK: - GCParent conformance

extension RGATreeList: GCParent {
    /// Purges a dead position node from the linked list.
    func purge(node: any GCChild) {
        guard let posNode = node as? RGATreeListNode else { return }
        self.purgeDeadPosition(positionCreatedAt: posNode.positionCreatedAt)
    }
}

// MARK: - Sequence conformance

extension RGATreeList: Sequence {
    typealias Element = RGATreeListNode

    func makeIterator() -> RGATreeListIterator {
        return RGATreeListIterator(self.dummyHead.next)
    }
}

/// Iterates over all nodes in linked-list order (live and removed, but not dead position nodes).
///
/// Dead position nodes are excluded because they have no `elementEntry` and callers
/// that iterate via `Sequence` expect `RGATreeListNode` values with a live `value`.
class RGATreeListIterator: IteratorProtocol {
    private weak var iteratorNext: RGATreeListNode?

    init(_ firstNode: RGATreeListNode?) {
        self.iteratorNext = firstNode
    }

    func next() -> RGATreeListNode? {
        // Skip dead position nodes.
        while let current = self.iteratorNext, current.elementEntry == nil {
            self.iteratorNext = current.next
        }

        guard let result = self.iteratorNext else {
            return nil
        }

        defer {
            self.iteratorNext = result.next
        }
        return result
    }
}
