/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

class ContentChange<T: RGATreeSplitValue> {
    let actor: ActorID
    let from: Int
    let to: Int
    var content: T?

    init(actor: ActorID, from: Int, to: Int, content: T? = nil) {
        self.actor = actor
        self.from = from
        self.to = to
        self.content = content
    }
}

protocol RGATreeSplitValue {
    init()
    var count: Int { get }
    func substring(from: Int, to: Int) -> Self
    /// Shortens this value in place, keeping the object identity. A split has to
    /// keep the LEFT node's value object, because `CRDTRoot` identifies a GC
    /// pair's parent by object identity: replacing it orphans every pair already
    /// registered against it, so the tombstone survives while the ledger says it
    /// was collected.
    func truncate(_ offset: Int)
    func getDataSize() -> DataSize

    /// Returns the pairs for the tombstones this value carries, for a value
    /// that has any (``CRDTTextValue``'s removed attributes). Declared as a
    /// requirement, with a default empty implementation below, so a
    /// conforming type's override is reached through the generic `T` bound as
    /// well as through any existential.
    func getGCPairs() -> [GCPair]
}

extension RGATreeSplitValue {
    /// Most values carry no tombstones of their own.
    func getGCPairs() -> [GCPair] {
        return []
    }
}

/**
 * `RGATreeSplitPosStruct` is a structure represents the meta data of the node pos.
 * It is used to serialize and deserialize the node pos.
 */
public struct RGATreeSplitPosStruct: Codable {
    let id: RGATreeSplitNodeIDStruct
    let relativeOffset: Int32
}

/**
 * `RGATreeSplitNodeIDStruct` is a structure represents the meta data of the node id.
 * It is used to serialize and deserialize the node id.
 */
public struct RGATreeSplitNodeIDStruct: Codable {
    let createdAt: TimeTicketStruct
    let offset: Int32
}

/**
 * `RGATreeSplitNodeID` is an ID of RGATreeSplitNode.
 */
class RGATreeSplitNodeID: Equatable, Comparable, CustomDebugStringConvertible {
    static let initial = RGATreeSplitNodeID(TimeTicket.initial, 0)

    /**
     * `createdAt` the creation time of this ID.
     */
    let createdAt: TimeTicket
    /**
     * `offset` the offset of this ID.
     */
    let offset: Int32

    init(_ createdAt: TimeTicket, _ offset: Int32) {
        self.createdAt = createdAt
        self.offset = offset
    }

    /**
     * `==` returns whether given ID equals to this ID or not.
     */
    static func == (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.offset == rhs.offset
    }

    static func < (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.offset < rhs.offset
        } else {
            return lhs.createdAt < rhs.createdAt
        }
    }

    /**
     * `hasSameCreatedAt` returns whether given ID has same creation time with this ID.
     */
    func hasSameCreatedAt(_ other: RGATreeSplitNodeID) -> Bool {
        self.createdAt == other.createdAt
    }

    /**
     * `split` creates a new ID with an offset from this ID.
     */
    func split(_ offset: Int32) -> RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.createdAt, self.offset + offset)
    }

    /**
     * `toTestString` returns a String containing
     * the meta data of the node id for debugging purpose.
     */
    var toTestString: String {
        "\(self.createdAt.toTestString):\(self.offset)"
    }

    /**
     * `toIDString` returns a string that can be used as an ID for this node id.
     */
    var toIDString: String {
        "\(self.createdAt.toIDString):\(self.offset)"
    }

    var debugDescription: String {
        self.toTestString
    }
}

extension RGATreeSplitNodeID {
    /**
     * `fromStruct` creates a new instance of RGATreeSplitPos from the given struct.
     */
    static func fromStruct(_ value: RGATreeSplitNodeIDStruct) throws -> RGATreeSplitNodeID {
        try RGATreeSplitNodeID(TimeTicket.fromStruct(value.createdAt), value.offset)
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: RGATreeSplitNodeIDStruct {
        RGATreeSplitNodeIDStruct(createdAt: self.createdAt.toStruct, offset: self.offset)
    }
}

/**
 * `RGATreeSplitNodePos` is the position of the text inside the node.
 */
class RGATreeSplitPos: Equatable {
    /**
     * `id` returns the ID of this RGATreeSplitNodePos.
     */
    let id: RGATreeSplitNodeID

    /**
     * `relativeOffset` returns the relative offset of this RGATreeSplitNodePos.
     */
    let relativeOffset: Int32

    init(_ id: RGATreeSplitNodeID, _ relativeOffset: Int32) {
        self.id = id
        self.relativeOffset = relativeOffset
    }

    /**
     * `absoluteID` returns the absolute id of this RGATreeSplitNodePos.
     */
    var absoluteID: RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.id.createdAt, self.id.offset + self.relativeOffset)
    }

    /**
     *`toTestString` returns a String containing
     * the meta data of the position for debugging purpose.
     */
    var toTestString: String {
        "\(self.id.toTestString):\(self.relativeOffset)"
    }

    /**
     * `==` returns whether given pos equal to this pos or not.
     */
    static func == (lhs: RGATreeSplitPos, rhs: RGATreeSplitPos) -> Bool {
        lhs.id == rhs.id && lhs.relativeOffset == rhs.relativeOffset
    }
}

extension RGATreeSplitPos {
    /**
     * `fromStruct` creates a new instance of RGATreeSplitPos from the given struct.
     */
    static func fromStruct(_ value: RGATreeSplitPosStruct) throws -> RGATreeSplitPos {
        try RGATreeSplitPos(RGATreeSplitNodeID.fromStruct(value.id), value.relativeOffset)
    }

    /**
     * `toStruct` returns the structure of this position.
     */
    var toStruct: RGATreeSplitPosStruct {
        RGATreeSplitPosStruct(id: self.id.toStruct, relativeOffset: self.relativeOffset)
    }
}

typealias RGATreeSplitPosRange = (RGATreeSplitPos, RGATreeSplitPos)

/**
 * `RestoreSpan` identifies a run of characters from a single original
 * insertion: the absolute-offset interval [start, end) of the insertion
 * created at `createdAt`. `value` is a deep copy of the removed content,
 * carried so that purged nodes can be recreated (GC-safe).
 */
struct RestoreSpan<T: RGATreeSplitValue> {
    let createdAt: TimeTicket
    let start: Int32
    let end: Int32
    let value: T
}

/**
 * `RGATreeSplitNode` is a node of RGATreeSplit.
 */
class RGATreeSplitNode<T: RGATreeSplitValue>: SplayNode<T> {
    /**
     * `id` returns the ID of this RGATreeSplitNode.
     */
    let id: RGATreeSplitNodeID

    /**
     * `removedAt` returns the remove time of this node.
     */
    private(set) var removedAt: TimeTicket?

    // The removal ledger. `dels` are the deletions that removed this node while it was live in the
    // deleter's view; `cancels` are the deletions undo cancelled. `removedAt` is the latest
    // uncancelled deletion. `!ledgered` means the ledger is just `removedAt`.
    private var ledgered = false
    private var dels: [TimeTicket]?
    private var cancels: [LedgerCancel]?
    // The reading of the ledger above, kept because a ledger grows a pair per delete-and-undo cycle
    // and rebuilding it on every walk makes churning one quadratic. Every write of the ledger
    // either drops it or updates it.
    private var index: LedgerIndex?

    /**
     * `prev` returns a previous node of this node.
     */
    private(set) weak var prev: RGATreeSplitNode<T>?

    /**
     * `next`  returns a next node of this node.
     */
    private(set) weak var next: RGATreeSplitNode<T>? {
        didSet {}
    }

    /**
     * `insPrev` returns a previous node of this node insertion.
     */
    private(set) weak var insPrev: RGATreeSplitNode<T>?

    /**
     * `insNext` returns a next node of this node insertion.
     */
    private(set) weak var insNext: RGATreeSplitNode<T>?

    init(_ id: RGATreeSplitNodeID, _ value: T? = nil, _ removedAt: TimeTicket? = nil) {
        self.id = id
        self.removedAt = removedAt

        super.init(value ?? T())
    }

    /**
     * `createdAt` returns creation time of the Id of RGATreeSplitNode.
     */
    var createdAt: TimeTicket {
        self.id.createdAt
    }

    /**
     * `length` returns the length of this node.
     */
    override var length: Int {
        guard self.removedAt == nil else {
            return 0
        }

        return self.contentLength
    }

    /**
     * `contentLength` returns the length of this value.
     */
    var contentLength: Int {
        self.value.count
    }

    /**
     * `insPrevID` returns a ID of previous node insertion.
     */
    var insPrevID: RGATreeSplitNodeID? {
        self.insPrev?.id
    }

    /**
     * `setPrev` sets a previous node of this node.
     */
    func setPrev(_ node: RGATreeSplitNode<T>?) {
        self.prev = node
        node?.next = self
    }

    /**
     * `setNext`  sets a next node of this node.
     */
    func setNext(_ node: RGATreeSplitNode<T>?) {
        self.next = node
        node?.prev = self
    }

    /**
     * `setInsPrev` sets a previous node of this node insertion.
     */
    func setInsPrev(_ node: RGATreeSplitNode<T>?) {
        self.insPrev = node
        node?.insNext = self
    }

    /**
     * `setInsNext` sets a next node of this node insertion.
     */
    func setInsNext(_ node: RGATreeSplitNode<T>?) {
        self.insNext = node
        node?.insPrev = self
    }

    /**
     * `hasNext` checks if next node exists.
     */
    var hasNext: Bool {
        self.next != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    var hasInsPrev: Bool {
        self.insPrev != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    var hasInsNext: Bool {
        self.insNext != nil
    }

    /**
     * `isRemoved` checks if removed time exists.
     */
    var isRemoved: Bool {
        self.removedAt != nil
    }

    /**
     * `split` creates a new split node of the given offset.
     */
    func split(_ offset: Int32) -> RGATreeSplitNode<T> {
        let node = RGATreeSplitNode(
            self.id.split(offset),
            self.splitValue(offset),
            self.removedAt
        )
        node.copyLedger(from: self)
        return node
    }

    /**
     * `canRemove` checks if node is able to delete.
     * Returns true if the node can be removed based on the editedAt time.
     * If creationKnown is false, the node cannot be removed.
     * If the node has no removedAt (alive), it can be removed.
     * If tombstoneKnown is false and editedAt is after removedAt, allow overwrite.
     */
    func canRemove(
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
     * `canStyle` checks if node is able to set style.
     */
    ///
    /// The only question is whether the styling change knew this node existed.
    /// It deliberately does NOT ask whether the node has since been removed, and
    /// that is a convergence requirement: a style is applied unconditionally on
    /// the replica that issues it — the node is live there — and can never be
    /// retracted afterwards, so every other replica has to apply it too. Any rule
    /// that reads `removedAt` is delivery-order dependent, because `removedAt` is
    /// last-writer-wins and mutable while a style is evaluated once, when it
    /// arrives.
    ///
    /// The cost is that a style covers text the same client had already deleted,
    /// invisibly, so undoing the style and then the deletion brings the text back
    /// without the attributes it carried.
    func canStyle(_ versionVector: VersionVector?) -> Bool {
        ticketKnown(versionVector, self.createdAt)
    }

    /**
     * `setRemovedAt` sets the remove time of this node. It drops the ledger.
     */
    func setRemoveAt(_ removeAt: TimeTicket?) {
        self.removedAt = removeAt
        self.ledgered = false
        self.dels = nil
        self.cancels = nil
        self.index = nil
    }

    /**
     * `createRange` creates ranges of RGATreeSplitNodePos.
     */
    var createPosRange: RGATreeSplitPosRange {
        (RGATreeSplitPos(self.id, 0), RGATreeSplitPos(self.id, Int32(self.length)))
    }

    /**
     * `deepcopy` returns a new instance of this RGATreeSplitNode without structural info.
     */
    func deepcopy() -> RGATreeSplitNode<T> {
        // The value has to be copied, not shared. `Document` builds its clone
        // from the root and applies every operation to both; a shared value means
        // the clone's split or style mutates the root as a side effect, and the
        // root's own application then sees an already-mutated value.
        let node = RGATreeSplitNode(self.id, self.value.substring(from: 0, to: self.value.count), self.removedAt)
        node.copyLedger(from: self)
        return node
    }

    /**
     * `toTestString` returns a String containing
     * the meta data of the node for debugging purpose.
     */
    var toTestString: String {
        "\(self.id.toTestString) \(String(describing: self.value))"
    }

    private func splitValue(_ offset: Int32) -> T {
        // Take the right part first -- `substring` deep-copies the attributes --
        // then shorten this value IN PLACE rather than replacing it, so the GC
        // pairs registered against it keep pointing at a live object.
        let right = self.value.substring(from: Int(offset), to: self.value.count)
        self.value.truncate(Int(offset))
        return right
    }
}

// MARK: - Removal ledger

/// An undo that cancelled one deletion of a node.
struct LedgerCancel {
    let deletion: TimeTicket
    let cancelledAt: TimeTicket
}

/// One deletion of a removal ledger beside the cancel that covers it, if an undo cancelled it.
private final class LedgerEntry {
    let removal: TimeTicket
    var cancelledAt: TimeTicket?

    init(removal: TimeTicket, cancelledAt: TimeTicket? = nil) {
        self.removal = removal
        self.cancelledAt = cancelledAt
    }
}

/// The reading of a removal ledger every walk of it needs: each deletion with its cancel, those
/// entries by deletion, the deletions no cancel covers, and the cancels by the deletion each one
/// cancels -- which covers the cancel of a deletion the ledger itself does not hold.
private final class LedgerIndex {
    var entries: [LedgerEntry] = []
    var byKey: [String: LedgerEntry] = [:]
    var live: [TimeTicket] = []
    var cancelled: [String: TimeTicket] = [:]
}

/// The removal ledger of a Text piece (yorkie-team/yorkie#2310, yorkie-js-sdk#1514).
///
/// Each piece keeps the deletions that removed it and the undos that cancelled some of them. An
/// undo cancels only its own actor's removal, and a deletion or redo removes only what its author
/// saw live. `removedAt` is the latest uncancelled deletion.
extension RGATreeSplitNode {
    func copyLedger(from other: RGATreeSplitNode<T>) {
        self.ledgered = other.ledgered
        self.dels = other.dels
        self.cancels = other.cancels
        self.index = nil
    }

    /// The removal ledger: whether there is one, the deletions and the cancels.
    var ledger: (ledgered: Bool, dels: [TimeTicket], cancels: [LedgerCancel]) {
        (self.ledgered, self.dels ?? [], self.cancels ?? [])
    }

    /// Whether the ledger holds a cancel, the only thing ``pruneStable(_:)`` can drop.
    var hasCancels: Bool {
        !(self.cancels?.isEmpty ?? true)
    }

    /// The deletions in the ledger without building one: a node without a ledger was removed by
    /// `removedAt` alone, if at all.
    private func removals() -> [TimeTicket] {
        if self.ledgered {
            return self.dels ?? []
        }
        return self.removedAt.map { [$0] } ?? []
    }

    private func ensureLedger() {
        if !self.ledgered {
            self.ledgered = true
            self.dels = self.removedAt.map { [$0] } ?? []
            self.index = nil
        }
    }

    /// Reads the ledger into the form every walk of it wants, and keeps that reading until the
    /// ledger is written again. A deletion is cancelled at most once (``cancelRemoval(_:at:)`` and
    /// ``setRemovalEvents(_:)`` both pair one to one), so a cancel is indexed by the deletion it
    /// cancels. A decoded ledger is as long as whoever sent it made it, so every walk takes this
    /// index rather than scanning the cancels per deletion, which would be quadratic.
    private func ledgerIndex() -> LedgerIndex {
        if let index = self.index {
            return index
        }
        let index = LedgerIndex()
        for cancel in self.cancels ?? [] {
            index.cancelled[cancel.deletion.toIDString] = cancel.cancelledAt
        }
        for deletion in self.removals() {
            let key = deletion.toIDString
            if index.byKey[key] != nil {
                continue
            }
            let entry = LedgerEntry(removal: deletion, cancelledAt: index.cancelled[key])
            index.entries.append(entry)
            index.byKey[key] = entry
            if entry.cancelledAt == nil {
                index.live.append(deletion)
            }
        }
        self.index = index
        return index
    }

    private func recompute() {
        var latest: TimeTicket?
        for deletion in self.ledgerIndex().live {
            if let current = latest, !deletion.after(current) {
                continue
            }
            latest = deletion
        }
        self.removedAt = latest
    }

    /// Adds a deletion to the ledger.
    ///
    /// A node's first removal is just `removedAt`; the ledger is built only when a second removal
    /// or a cancel needs it.
    ///
    /// - Parameter removedAt: The ticket of the deletion.
    func recordRemoval(_ removedAt: TimeTicket) {
        if !self.ledgered, self.removedAt == nil {
            self.removedAt = removedAt
            self.index = nil
            return
        }
        self.ensureLedger()
        // An actor removes a piece only while it is live in its view, so it never holds two
        // uncancelled removals; a change whose vector leaves out its own earlier removal is not
        // honest, and recording it would break the pairing `removal_events` relies on and grow the
        // ledger.
        let mine = self.uncancelledRemovalBy(removedAt.actorID)
        if let mine, mine != removedAt {
            return
        }
        let index = self.ledgerIndex()
        let key = removedAt.toIDString
        if mine == nil, index.byKey[key] == nil {
            self.dels?.append(removedAt)
            let entry = LedgerEntry(removal: removedAt)
            index.entries.append(entry)
            index.byKey[key] = entry
            index.live.append(removedAt)
        }
        self.recompute()
    }

    /// Cancels one deletion (an undo of it).
    ///
    /// - Parameters:
    ///   - deletion: The deletion to cancel.
    ///   - at: The ticket of the undo.
    /// - Returns: Whether the node is live afterwards.
    @discardableResult
    func cancelRemoval(_ deletion: TimeTicket, at: TimeTicket) -> Bool {
        self.ensureLedger()
        if self.cancels == nil {
            self.cancels = []
        }
        let index = self.ledgerIndex()
        let key = deletion.toIDString
        if index.cancelled[key] == nil {
            self.cancels?.append(LedgerCancel(deletion: deletion, cancelledAt: at))
            index.cancelled[key] = at
            if let entry = index.byKey[key] {
                entry.cancelledAt = at
                if let live = index.live.firstIndex(of: deletion) {
                    index.live.remove(at: live)
                }
            }
        }
        self.recompute()
        return self.removedAt == nil
    }

    /// Drops each removal whose cancel is known to every replica, with that cancel.
    ///
    /// A change that arrives later knows both, so the pair never decides
    /// ``isRemovedInView(_:)`` again, and dropping it keeps an undo-heavy text from carrying every
    /// removal it ever had. A removal is older than its cancel by the same actor, so the cancel
    /// being known is enough. What is left is the default ledger once `removedAt` alone says it.
    ///
    /// - Parameter vector: The versions every replica has seen.
    func pruneStable(_ vector: VersionVector) {
        var cancels = [LedgerCancel]()
        var dropped = Set<String>()
        for cancel in self.cancels ?? [] {
            if !vector.afterOrEqual(other: cancel.cancelledAt) {
                cancels.append(cancel)
                continue
            }
            dropped.insert(cancel.deletion.toIDString)
        }
        var dels = self.dels
        if !dropped.isEmpty, let current = dels {
            dels = current.filter { !dropped.contains($0.toIDString) }
        }
        self.dels = dels
        self.cancels = cancels
        self.index = nil
        let onlyRemovedAt: Bool = {
            guard let dels, !dels.isEmpty else {
                return true
            }
            return dels.count == 1 && self.removedAt != nil && dels[0] == self.removedAt
        }()
        if cancels.isEmpty, onlyRemovedAt {
            self.ledgered = false
            self.dels = nil
            self.cancels = nil
        }
    }

    /// Returns the removal by `actor` no undo cancelled, if any.
    ///
    /// - Parameter actor: The actor whose removal to find.
    /// - Returns: The ticket of that removal.
    func uncancelledRemovalBy(_ actor: ActorID) -> TimeTicket? {
        self.ledgerIndex().live.first { $0.actorID == actor }
    }

    /// Tells whether GC must keep this tombstone under `vector`, the versions every replica has
    /// seen.
    ///
    /// A node removed by two or more deletions no undo cancelled stays: an undo of one of them must
    /// find it still held by the others, and a purged node could not say so. A node whose ledger is
    /// not yet stable stays too: every deletion and every cancel in it must be known to all
    /// replicas, so any change that arrives after the purge already knew them, and a node a restore
    /// recreates with only the removal it cancels answers ``isRemovedInView(_:)`` as the full
    /// ledger would. Once that holds and a single removal is left, a restore that finds the piece
    /// gone can only be cancelling that removal, and recreates it.
    ///
    /// - Parameter vector: The versions every replica has seen.
    /// - Returns: Whether the node must stay.
    func heldFromPurge(_ vector: VersionVector) -> Bool {
        guard self.ledgered else {
            return false
        }
        // A cancelled deletion is older than its cancel by the same actor, so a stable cancel makes
        // it stable too; an uncancelled one is `removedAt`, which GC checks first, or one of two
        // that keep the node anyway.
        let liveCount = self.ledgerIndex().live.count
        for cancel in self.cancels ?? [] where !vector.afterOrEqual(other: cancel.cancelledAt) {
            return true
        }
        return liveCount >= 2
    }

    /// Tells whether the node was removed in the view of the given version vector: a deletion it
    /// knew that no undo it knew cancelled.
    ///
    /// - Parameter vector: The version vector of the view.
    /// - Returns: Whether the node is removed in that view.
    func isRemovedInView(_ vector: VersionVector) -> Bool {
        for entry in self.ledgerIndex().entries {
            if !ticketKnown(vector, entry.removal) {
                continue
            }
            if let cancelledAt = entry.cancelledAt, ticketKnown(vector, cancelledAt) {
                continue
            }
            return true
        }
        return false
    }

    /// Returns the ledger as one list: every removal and every cancel's ticket except `removedAt`,
    /// in ticket order.
    ///
    /// Empty when `removedAt` says it all. An actor's events alternate in ticket order -- it
    /// removes a piece only while the piece is live in its view, and its undo cancels its one
    /// uncancelled removal -- so ``setRemovalEvents(_:)`` can tell them apart by place.
    ///
    /// - Returns: The removal events.
    func getRemovalEvents() -> [TimeTicket] {
        guard self.ledgered else {
            return []
        }
        var events = (self.dels ?? []).filter { self.removedAt == nil || $0 != self.removedAt }
        events.append(contentsOf: (self.cancels ?? []).map { $0.cancelledAt })
        return events.sorted()
    }

    /// Rebuilds the ledger from `removedAt` and the events ``getRemovalEvents()`` returned: per
    /// actor, in ticket order, a removal then the cancel of it.
    ///
    /// - Parameter events: The removal events.
    /// - Throws: `errInvalidArgument` on a repeated ticket, which would pair a cancel with a
    ///   removal that is not older, and when the result does not reproduce `removedAt`. The node is
    ///   left as it was.
    func setRemovalEvents(_ events: [TimeTicket]) throws {
        guard !events.isEmpty else {
            return
        }
        let removedAt = self.removedAt
        var all = events
        if let removedAt {
            all.append(removedAt)
        }
        all.sort()
        for idx in 1 ..< all.count where all[idx] == all[idx - 1] {
            throw YorkieError(code: .errInvalidArgument, message: "removal events repeat a ticket")
        }

        var dels = [TimeTicket]()
        var cancels = [LedgerCancel]()
        var open = [ActorID: TimeTicket]()
        for ticket in all {
            if let deletion = open[ticket.actorID] {
                cancels.append(LedgerCancel(deletion: deletion, cancelledAt: ticket))
                open[ticket.actorID] = nil
                continue
            }
            dels.append(ticket)
            open[ticket.actorID] = ticket
        }

        self.ledgered = true
        self.dels = dels
        self.cancels = cancels
        self.index = nil
        self.recompute()
        if self.removedAt != removedAt {
            self.removedAt = removedAt
            self.ledgered = false
            self.dels = nil
            self.cancels = nil
            self.index = nil
            throw YorkieError(code: .errInvalidArgument, message: "removal events do not reproduce removed_at")
        }
    }
}

extension RGATreeSplitNode: GCChild {
    /**
     * `getDataSize` returns the data of this node.
     */
    func getDataSize() -> DataSize {
        let dataSize = self.value.getDataSize()
        var meta = dataSize.meta + timeTicketSize

        // Add meta size for removedAt if present
        if self.removedAt != nil {
            meta += timeTicketSize
        }

        return .init(
            data: dataSize.data,
            meta: meta
        )
    }

    var toIDString: String {
        self.id.toIDString
    }
}

/**
 * `RGATreeSplit` is a block-based list with improved index-based lookup in RGA.
 * The difference from RGATreeList is that it has data on a block basis to
 * reduce the size of CRDT metadata. When an edit occurs on a block,
 * the block is split.
 */
class RGATreeSplit<T: RGATreeSplitValue> {
    /**
     * `head` returns head of RGATreeSplitNode.
     */
    private(set) var head: RGATreeSplitNode<T>
    private var treeByIndex: SplayTree<T>
    private var treeByID: LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<T>>

    /**
     * `pendingGCPairs` buffers GC pairs for garbage that no `remove()` call
     * produced: nodes created already-tombstoned by splitting a removed node,
     * and attribute tombstones duplicated by a value copy (a split, or
     * `restore` recreating a purged piece; see `bookCopiedAttrTombstones`).
     * Either would otherwise never be registered for GC. Callers that split or
     * restore nodes (`edit`, `CRDTText.setStyle`, `CRDTText.removeStyle`,
     * `restore`) drain this buffer into their returned GC pairs.
     */
    private var pendingGCPairs: [GCPair] = []

    /**
     * `cancelled` holds the nodes whose ledger has a cancel, the only ones
     * `pruneLedgers` can drop anything from. `nil` until first needed: a tree
     * decoded from a snapshot or deep-copied fills it with one scan.
     */
    private var cancelled: [ObjectIdentifier: RGATreeSplitNode<T>]?

    /// Records that the ledger of `node` has a cancel.
    private func trackCancelled(_ node: RGATreeSplitNode<T>) {
        if self.cancelled == nil {
            self.scanCancelled()
        }
        self.cancelled?[ObjectIdentifier(node)] = node
    }

    private func scanCancelled() {
        var cancelled = [ObjectIdentifier: RGATreeSplitNode<T>]()
        for node in self where node.hasCancels {
            cancelled[ObjectIdentifier(node)] = node
        }
        self.cancelled = cancelled
    }

    /// Whether any node's removal ledger holds a cancel.
    var hasCancelledRemovals: Bool {
        if self.cancelled == nil {
            self.scanCancelled()
        }
        return !(self.cancelled?.isEmpty ?? true)
    }

    /// Drops, from every node's ledger, the removals whose cancels the given vector covers (see
    /// ``RGATreeSplitNode/pruneStable(_:)``).
    ///
    /// - Parameter vector: The versions every replica has seen.
    /// - Returns: How many nodes still hold a cancel.
    @discardableResult
    func pruneLedgers(_ vector: VersionVector) -> Int {
        if self.cancelled == nil {
            self.scanCancelled()
        }
        for (key, node) in self.cancelled ?? [:] {
            node.pruneStable(vector)
            if !node.hasCancels {
                self.cancelled?.removeValue(forKey: key)
            }
        }
        return self.cancelled?.count ?? 0
    }

    init() {
        self.head = RGATreeSplitNode(RGATreeSplitNodeID.initial)
        self.treeByIndex = SplayTree()
        self.treeByID = LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<T>>()
        self.treeByIndex.insert(self.head)
        self.treeByID.put(self.head.id, self.head)
    }

    /**
     * `edit` does following steps
     * 1. split nodes with from and to
     * 2. delete between from and to
     * 3. insert a new node
     * 4. add removed node
     * @param range - range of RGATreeSplitNode
     * @param editedAt - edited time
     * @param value - value
     * @returns `(RGATreeSplitNodePos, [String: TimeTicket], [GCPair], [Change])`
     */
    @discardableResult
    func edit(
        _ range: RGATreeSplitPosRange,
        _ editedAt: TimeTicket,
        _ value: T?,
        _ versionVector: VersionVector? = nil
    ) throws -> (RGATreeSplitPos, [GCPair], DataSize, [ContentChange<T>], [T], [RestoreSpan<T>]) {
        var diff = DataSize(data: 0, meta: 0)

        // 01. split nodes with from and to
        let (toLeft, diffTo, toRight) = try self.findNodeWithSplit(range.1, editedAt)
        let (fromLeft, diffFrom, fromRight) = try self.findNodeWithSplit(range.0, editedAt)
        diff.addDataSizes(others: diffFrom, diffTo)

        // 02. delete between from and to
        let nodesToDelete = self.findBetween(fromRight, toRight)
        var (changes, removedNodes, alreadyRemovedIDs) = try self.deleteNodes(
            nodesToDelete,
            editedAt,
            versionVector
        )

        let caretID = toRight?.id ?? toLeft.id
        var caretPos = RGATreeSplitPos(caretID, 0)

        // 03. insert a new node
        if let value {
            let idx = try self.posToIndex(fromLeft.createPosRange.1, true)

            let inserted = self.insertAfter(
                fromLeft,
                RGATreeSplitNode(RGATreeSplitNodeID(editedAt, 0), value)
            )

            diff.addDataSizes(others: inserted.getDataSize())

            if !changes.isEmpty, changes[changes.count - 1].from == idx {
                changes[changes.count - 1].content = value
            } else {
                changes.append(ContentChange<T>(actor: editedAt.actorID, from: idx, to: idx, content: value))
            }

            caretPos = RGATreeSplitPos(inserted.id, Int32(inserted.contentLength))
        }

        // 04. add removed node
        var pairs = [GCPair]()
        var removedValues = [T]()
        var removedSpans = [RestoreSpan<T>]()
        for removedNode in removedNodes {
            // NOTE: Nodes that were already tombstoned keep their existing GC
            // pair (the pair reads `removedAt` from the node at collection
            // time); re-registering would toggle the pair off and leak the node.
            if !alreadyRemovedIDs.contains(removedNode.toIDString) {
                pairs.append(GCPair(parent: self, child: removedNode))
            }
            removedValues.append(removedNode.value)
            // Capture split-invariant character identities. `substring` over the
            // whole value deep-copies it, so later splits of the tombstone
            // cannot mutate the captured content.
            removedSpans.append(
                RestoreSpan(
                    createdAt: removedNode.createdAt,
                    start: removedNode.id.offset,
                    end: removedNode.id.offset + Int32(removedNode.contentLength),
                    value: removedNode.value.substring(from: 0, to: removedNode.value.count)
                )
            )
        }

        pairs.append(contentsOf: self.drainPendingGCPairs())

        return (caretPos, pairs, diff, changes, removedValues, removedSpans)
    }

    /**
     * `normalizePos` converts a local position `(id, rel)` into a single absolute offset
     * measured from the head `(0:0)` of the physical chain.
     *
     * The offset is the live length of every node before the floor node of `id`, plus `rel`.
     * It used to be summed over the `prev` chain; it is now read from `treeByIndex`, which
     * holds the same sum: every node on the chain is in it, in chain order, weighted by its
     * live length (a tombstone stays in with weight zero; only `purge` takes a node out, and
     * `purge` unlinks it from the chain too). Every edit execution calls this, so a linear
     * walk here made typing a document quadratic.
     *
     * This is a one-to-one port of the Go implementation (yorkie#2107), and the result is the
     * chain walk's result for every input, including a floor lookup that lands on an earlier
     * piece: `rel` is added in the id space of the floor node, not resolved through the
     * absolute id. Resolution stays the same on purpose -- `Document.applyChange` reconciles
     * the undo stacks against these offsets, so they must agree with what every other replica,
     * Go included, computes.
     */
    func normalizePos(_ pos: RGATreeSplitPos) throws -> RGATreeSplitPos {
        guard let node = self.findFloorNode(pos.id) else {
            throw YorkieError(code: .errInvalidArgument, message: "the node of the given id should be found: \(pos.id.toTestString)")
        }

        // A node `findFloorNode` returns is always in `treeByIndex` (see above), so `indexOf`
        // cannot answer -1 here.
        let index = self.treeByIndex.indexOf(node)
        guard index >= 0 else {
            throw YorkieError(code: .errInvalidArgument, message: "the node of the given id should be indexed: \(pos.id.toTestString)")
        }

        return RGATreeSplitPos(self.head.id, Int32(index) + pos.relativeOffset)
    }

    /**
     * `refinePos` remaps the given pos to the current split chain.
     *
     * It traverses the physical `next` chain counting only live characters (removed nodes are
     * treated as length 0). When the offset exceeds the current node, it advances, subtracting
     * lengths, until the offset fits; if it runs out of nodes it snaps to the end of the last node.
     */
    func refinePos(_ pos: RGATreeSplitPos) throws -> RGATreeSplitPos {
        guard var node = self.findFloorNode(pos.id) else {
            throw YorkieError(code: .errInvalidArgument, message: "the node of the given id should be found: \(pos.id.toTestString)")
        }

        var offsetInPart = Int(pos.relativeOffset)
        var partLen = node.contentLength
        while offsetInPart > partLen {
            offsetInPart -= partLen
            guard let next = node.next else {
                return RGATreeSplitPos(node.id, Int32(partLen))
            }
            node = next
            partLen = node.length
        }

        return RGATreeSplitPos(node.id, Int32(offsetInPart))
    }

    /**
     * `findNodePos` finds RGATreeSplitNodePos of given offset.
     */
    func indexToPos(_ idx: Int) throws -> RGATreeSplitPos {
        let (node, offset) = try self.treeByIndex.findForText(idx)
        guard let splitNode = node as? RGATreeSplitNode<T> else {
            throw YorkieError(code: .errInvalidArgument, message: "no element for index \(idx)")
        }

        return RGATreeSplitPos(splitNode.id, Int32(offset))
    }

    /**
     * `findIndexesFromRange` finds indexes based on range.
     */
    func findIndexesFromRange(_ range: RGATreeSplitPosRange) throws -> (Int, Int) {
        let (fromPos, toPos) = range
        return try (self.posToIndex(fromPos, false), self.posToIndex(toPos, true))
    }

    /**
     * `posToIndex` finds index based on node position.
     */
    func posToIndex(_ pos: RGATreeSplitPos, _ preferToLeft: Bool) throws -> Int {
        let absoluteID = pos.absoluteID
        guard let node = preferToLeft ? try? self.findFloorNodePreferToLeft(absoluteID) : self.findFloorNode(absoluteID) else {
            let message = "the node of the given id should be found: \(absoluteID.toTestString)"
            throw YorkieError(code: .errInvalidArgument, message: message)
        }
        let index = self.treeByIndex.indexOf(node)
        let offset = node.isRemoved ? 0 : absoluteID.offset - node.id.offset

        return index + Int(offset)
    }

    /**
     * `findNode` finds node of given id.
     */
    func findNode(_ id: RGATreeSplitNodeID) -> RGATreeSplitNode<T>? {
        self.findFloorNode(id)
    }

    /**
     * `length` returns size of RGATreeList.
     */
    var length: Int {
        self.treeByIndex.length
    }

    /**
     * `getTreeByIndex` returns the tree by index for debugging purpose.
     */
    func getTreeByIndex() -> SplayTree<T> {
        return self.treeByIndex
    }

    /**
     * `getTreeByID` returns the tree by ID for debugging purpose.
     */
    func getTreeByID() -> LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<T>> {
        return self.treeByID
    }

    /**
     * `toJSON` returns the JSON encoding of this Array.
     */
    var toJSON: String {
        var result = [String]()

        for item in self where !item.isRemoved {
            result.append("\(item.value)")
        }

        return result.joined(separator: "")
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> RGATreeSplit<T> {
        let clone = RGATreeSplit<T>()

        var node: RGATreeSplitNode<T>? = self.head.next
        var prev: RGATreeSplitNode<T>? = clone.head
        var current: RGATreeSplitNode<T>?

        while node != nil {
            current = clone.insertAfter(prev!, node!.deepcopy())
            if let insPrevID = node!.insPrevID {
                current?.setInsPrev(clone.findNode(insPrevID))
            }

            prev = current
            node = node!.next
        }

        return clone
    }

    /**
     * `toTestString` returns a String containing the meta data of the node
     * for debugging purpose.
     */
    var toTestString: String {
        var result = [String]()

        for item in self {
            if !item.isRemoved {
                result.append("[\(item.toTestString)]")
            } else {
                result.append("{\(item.toTestString)}")
            }
        }

        return result.joined(separator: "")
    }

    /**
     * `insertAfter` inserts the given node after the given previous node.
     */
    @discardableResult
    func insertAfter(_ prevNode: RGATreeSplitNode<T>, _ newNode: RGATreeSplitNode<T>) -> RGATreeSplitNode<T> {
        let next = prevNode.next
        newNode.setPrev(prevNode)

        if next != nil {
            next!.setPrev(newNode)
        }

        self.treeByID.put(newNode.id, newNode)
        self.treeByIndex.insert(previousNode: prevNode, newNode: newNode)

        return newNode
    }

    /**
     * `findNodeWithSplit` splits and return nodes of the given position.
     */
    func findNodeWithSplit(
        _ pos: RGATreeSplitPos,
        _ editedAt: TimeTicket
    ) throws -> (RGATreeSplitNode<T>, DataSize, RGATreeSplitNode<T>?) {
        let absoluteID = pos.absoluteID
        var node = try self.findFloorNodePreferToLeft(absoluteID)
        let relativeOffset = absoluteID.offset - node.id.offset

        let (_, diff) = try self.splitNode(node, relativeOffset)

        while let next = node.next, next.createdAt.after(editedAt) {
            node = next
        }

        return (node, diff, node.next)
    }

    private func findFloorNodePreferToLeft(_ id: RGATreeSplitNodeID) throws -> RGATreeSplitNode<T> {
        guard let node = self.findFloorNode(id) else {
            let message = "the node of the given id should be found: \(id.toTestString)"
            throw YorkieError(code: .errInvalidArgument, message: message)
        }

        if id.offset > 0, node.id.offset == id.offset {
            // NOTE: InsPrev may not be present due to GC.
            if let insPrev = node.insPrev {
                return insPrev
            }
        }

        return node
    }

    private func findFloorNode(_ id: RGATreeSplitNodeID) -> RGATreeSplitNode<T>? {
        guard let entry = self.treeByID.floorEntry(id) else {
            return nil
        }

        if !(entry.key == id), !entry.key.hasSameCreatedAt(id) {
            return nil
        }

        return entry.value
    }

    /**
     * `findBetween` returns nodes between fromNode and toNode.
     */
    func findBetween(_ fromNode: RGATreeSplitNode<T>?, _ toNode: RGATreeSplitNode<T>?) -> [RGATreeSplitNode<T>] {
        var nodes = [RGATreeSplitNode<T>]()

        var current: RGATreeSplitNode<T>? = fromNode
        while current != nil, current! !== toNode {
            nodes.append(current!)
            current = current!.next
        }

        return nodes
    }

    @discardableResult
    private func splitNode(_ node: RGATreeSplitNode<T>, _ offset: Int32) throws -> (RGATreeSplitNode<T>?, DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        // A negative offset is as out of range as one past the end. `findNodeWithSplit` derives the
        // offset by subtracting the node's own offset from the position's, so a position resolved
        // through an `insPrev` link into a node of a HIGHER offset -- which only a forged link can
        // produce -- arrives here negative. Without this guard `split` would clamp it into an
        // out-of-range slice (an `NSRangeException` on iOS) rather than fail (yorkie-js-sdk#1449).
        guard offset >= 0, offset <= node.contentLength else {
            let message = "offset should be between 0 and the length of the node"
            throw YorkieError(code: .errInvalidArgument, message: message)
        }

        if offset == 0 {
            return (node, diff)
        } else if offset == node.contentLength {
            return (node.next, diff)
        }

        let prvSize = node.getDataSize()

        let splitNode = node.split(offset)
        if splitNode.hasCancels {
            self.cancelled?[ObjectIdentifier(splitNode)] = splitNode
        }
        self.treeByIndex.updateWeight(splitNode)
        self.insertAfter(node, splitNode)

        if node.hasInsNext {
            node.insNext!.setInsPrev(splitNode)
        }
        splitNode.setInsPrev(node)

        diff.addDataSizes(others: node.getDataSize(), splitNode.getDataSize())
        diff.subDataSize(others: prvSize)

        // A split deep-copies the value's attributes, so every tombstone among
        // them is duplicated under the new node.
        self.bookCopiedAttrTombstones(splitNode.value)

        // NOTE: A piece split off an already-tombstoned node inherits
        // `removedAt` without going through `remove()`, so no GC pair is
        // created for it in the normal deletion path. Buffer one here so it
        // can be purged; otherwise it stays in the list forever. The piece
        // was never live, so the net-new size created by the split goes
        // straight to docSize.gc when the pair is registered; report a zero
        // diff to the caller (which accounts diffs to docSize.live).
        if splitNode.isRemoved {
            self.pendingGCPairs.append(GCPair(parent: self, child: splitNode, gcOnlySize: diff))
            return (splitNode, DataSize(data: 0, meta: 0))
        }

        return (splitNode, diff)
    }

    /**
     * `restore` re-establishes the characters described by `spans` under
     * their ORIGINAL identities. For each span, per overlapping region:
     *   - live piece exists       → skip (idempotent; another undo restored it)
     *   - tombstoned piece exists → cancel the undoing actor's own removal; the
     *                               piece revives unless another removal holds it
     *   - no piece exists (GC'd)  → recreate a node with the original ID
     *
     * Returns `(untombstonedNodes, recreatedNodes, changes, liveDiff,
     * pendingGCPairs)`. `changes` describes the revived content as insertions
     * (ascending index) so editor bindings and remote sync can be driven the
     * same way as a normal edit.
     *
     * The caller must, in order: (1) register every pair in `pendingGCPairs` —
     * these are fragments `splitNode` buffered while isolating a target range
     * out of a larger tombstoned piece (see `drainPendingGCPairs`);
     * (2) unregister GC pairs for `untombstonedNodes`. Registering first is
     * required for `untombstonedNodes` entries whose node was itself one of
     * those split-born fragments (a target isolated from the interior of a
     * tombstone) — such a node was never registered under its own id, so
     * step (1) creates the entry that step (2) then correctly walks from gc
     * back to live; entries that remain tombstoned (siblings of the restored
     * target) simply stay registered. Finally, `root.acc(liveDiff)` accounts
     * the size of any nodes recreated from scratch (the GC'd-away case), which
     * `splitNode`'s buffering does not cover.
     *
     * - Parameters:
     *   - spans: The identity-addressed runs to revive.
     *   - executedAt: The timestamp of the operation performing the restore.
     *   - fallbackAnchor: Position used to anchor a recreated fragment when
     *     every related piece has been purged.
     * - Returns: The untombstoned nodes, recreated nodes, resulting changes,
     *   the live-bucket size delta, and the GC pairs buffered by splits.
     */
    func restore(
        _ spans: [RestoreSpan<T>],
        _ executedAt: TimeTicket,
        _ fallbackAnchor: RGATreeSplitPos? = nil
    ) throws -> ([RGATreeSplitNode<T>], [RGATreeSplitNode<T>], [ContentChange<T>], DataSize, [GCPair]) {
        var untombstoned = [RGATreeSplitNode<T>]()
        var recreated = [RGATreeSplitNode<T>]()
        var liveDiff = DataSize(data: 0, meta: 0)

        // The last node placed at the current cursor (un-tombstoned or recreated),
        // in document order. When a recreated fragment has no surviving same-
        // insertion anchor, chaining after this keeps a multi-fragment run in
        // left-to-right order instead of each fragment prepending at the same fixed
        // fallback anchor — which would rebuild the run reversed. Spans arrive in
        // document order, so this is always the recreated fragment's left neighbour.
        var chainAnchor: RGATreeSplitNode<T>?
        for span in spans {
            let pieces = self.findPiecesOverlapping(span.createdAt, span.start, span.end)

            var cursor = span.start
            var pieceIdx = 0
            while cursor < span.end {
                let piece = pieceIdx < pieces.count ? pieces[pieceIdx] : nil
                let pieceStart = piece?.id.offset ?? Int32.max
                let pieceEnd = piece.map { $0.id.offset + Int32($0.contentLength) } ?? Int32.max

                if let piece, pieceStart <= cursor {
                    // Covered by an existing piece.
                    let overlapEnd = Swift.min(pieceEnd, span.end)
                    if piece.isRemoved {
                        let (target, _) = try self.isolateRange(piece, cursor, overlapEnd)
                        // An undo reverses its own actor's change, so the removal it cancels is the
                        // one uncancelled removal by that actor: one actor cannot remove a piece
                        // already removed in its view. No other removal holds it if there is none.
                        var live = false
                        if let deletion = target.uncancelledRemovalBy(executedAt.actorID) {
                            live = target.cancelRemoval(deletion, at: executedAt)
                            self.trackCancelled(target)
                        }
                        if live {
                            // Repair splay weights on the path to root (length 0 → len).
                            self.treeByIndex.splayNode(target)
                            untombstoned.append(target)
                        }
                        chainAnchor = target
                    } else {
                        chainAnchor = piece
                    }
                    cursor = overlapEnd
                    if overlapEnd >= pieceEnd {
                        pieceIdx += 1
                    }
                } else {
                    // Gap: recreate [cursor, gapEnd) with its original ID. A purged piece had a
                    // single uncancelled removal, stable on every replica (see `heldFromPurge`),
                    // so this restore can only be cancelling that one.
                    let gapEnd = Swift.min(pieceStart, span.end)
                    let value = span.value.substring(from: Int(cursor - span.start), to: Swift.min(Int(gapEnd - span.start), span.value.count))
                    // `substring` deep-copied the span's attributes, tombstones
                    // included, exactly as a split does. Book them here for the
                    // same reason `splitNode` does -- see
                    // `bookCopiedAttrTombstones`. The buffer is drained below
                    // into this call's returned pairs.
                    self.bookCopiedAttrTombstones(value)
                    let newNode = RGATreeSplitNode(RGATreeSplitNodeID(span.createdAt, cursor), value)
                    // The purged removal was known to every replica before the purge, so every
                    // change that can arrive later knows it. A stand-in removal by the same actor
                    // at lamport 0, which every such change's vector covers, keeps that answer for
                    // `isRemovedInView`, with this cancel. The pair is dropped once the cancel is
                    // known everywhere (`pruneStable`); until then snapshots carry it, as Go
                    // records the same.
                    let stable = TimeTicket(lamport: 0, delimiter: 0, actorID: executedAt.actorID)
                    newNode.recordRemoval(stable)
                    newNode.cancelRemoval(stable, at: executedAt)
                    self.trackCancelled(newNode)
                    liveDiff.addDataSizes(others: newNode.getDataSize())
                    let prev = try self.findRestoreAnchor(
                        span.createdAt,
                        cursor,
                        gapEnd,
                        executedAt,
                        fallbackAnchor,
                        chainAnchor
                    )
                    _ = self.insertAfter(prev, newNode)
                    // `insertAfter` only maintains the physical prev/next chain. Relink
                    // the separate insertion chain (`insPrev`/`insNext`) too, the same
                    // way `splitNode` does, so a recreated interior fragment is not
                    // skipped by the surviving same-insertion neighbours. Otherwise a
                    // later edit whose boundary lands on this fragment resolves through
                    // a stale insertion pointer in `findFloorNodePreferToLeft` and
                    // miscomputes its offset (yorkie-js-sdk#1327).
                    //
                    // The neighbours are the nearest surviving pieces, not just the ones covering
                    // the adjacent offsets: with the piece before the gap purged too, the one
                    // before that would keep pointing past the new fragment, and purging it later
                    // would hand the piece after the gap an `insPrev` that skips the fragment.
                    if cursor > 0 {
                        let prevID = RGATreeSplitNodeID(span.createdAt, cursor - 1)
                        if let insPrev = self.treeByID.floorEntry(prevID), insPrev.key.hasSameCreatedAt(prevID) {
                            newNode.setInsPrev(insPrev.value)
                        }
                    }
                    let nextID = RGATreeSplitNodeID(span.createdAt, gapEnd)
                    if let insNext = self.treeByID.ceilingEntry(nextID), insNext.key.hasSameCreatedAt(nextID) {
                        newNode.setInsNext(insNext.value)
                    }
                    recreated.append(newNode)
                    chainAnchor = newNode
                    cursor = gapEnd
                }
            }
        }

        let pendingGCPairs = self.drainPendingGCPairs()

        // Revived nodes are now live; report each as an insertion at its final
        // index. Ascending order keeps the indices valid when applied in
        // sequence (each earlier insertion is already present).
        var changes = [ContentChange<T>]()
        for node in untombstoned + recreated {
            let (from, _) = try self.findIndexesFromRange(node.createPosRange)
            changes.append(ContentChange<T>(actor: executedAt.actorID, from: from, to: from, content: node.value))
        }
        changes.sort { $0.from < $1.from }

        return (untombstoned, recreated, changes, liveDiff, pendingGCPairs)
    }

    /**
     * `retombstone` re-deletes the characters described by `spans` (redo of an
     * identity-preserving undo). Only pieces live in the redo's view are
     * affected: a piece removed in that view, or purged, is skipped
     * (idempotent), and a piece removed here by a deletion the redo never saw
     * records the redo without being re-tombstoned.
     *
     * Returns `(pairs, changes, diff, recorded)`: GCPairs for the newly
     * tombstoned nodes and the born-dead remainders the splits left behind, the
     * removed regions as deletions so editor bindings and remote sync can be
     * driven the same way as a normal edit, the metadata-size overhead from
     * splitting the (live) pieces to isolate the target range, and the pieces
     * the removal was recorded on, which the reverse has to name. The caller
     * must `root.acc(diff)` before registering `pairs`, mirroring how a normal
     * edit's boundary splits are accounted before its resulting tombstones are
     * registered. Indices are captured before each removal, so applying them in
     * emission order stays consistent.
     *
     * - Parameters:
     *   - spans: The identity-addressed runs to re-remove.
     *   - executedAt: The timestamp of the operation performing the removal.
     *   - versionVector: The version vector of the change carrying the redo.
     * - Returns: The GC pairs, resulting changes, the live-bucket size delta,
     *   and the spans the removal was recorded on.
     */
    func retombstone(
        _ spans: [RestoreSpan<T>],
        _ executedAt: TimeTicket,
        _ versionVector: VersionVector? = nil
    ) throws -> ([GCPair], [ContentChange<T>], DataSize, [RestoreSpan<T>]) {
        var pairs = [GCPair]()
        var changes = [ContentChange<T>]()
        var diff = DataSize(data: 0, meta: 0)
        // The pieces the removal was recorded on, which the reverse names: a restore never reaches
        // a piece that holds no removal by its actor.
        var recorded = [RestoreSpan<T>]()
        func record(_ span: RestoreSpan<T>, _ target: RGATreeSplitNode<T>) {
            let start = target.id.offset
            let end = start + Int32(target.contentLength)
            recorded.append(RestoreSpan(
                createdAt: span.createdAt,
                start: start,
                end: end,
                value: span.value.substring(from: Int(start - span.start), to: Int(end - span.start))
            ))
        }
        let inView = versionVector.flatMap { $0.size() > 0 ? $0 : nil }

        for span in spans {
            let pieces = self.findPiecesOverlapping(span.createdAt, span.start, span.end)
            for piece in pieces {
                let pieceStart = piece.id.offset
                let pieceEnd = pieceStart + Int32(piece.contentLength)
                if piece.isRemoved {
                    // A piece live in the redo's view but removed here by a deletion the redo never
                    // saw still records the redo's deletion, so a later undo of that other deletion
                    // keeps it removed.
                    if let inView, !piece.isRemovedInView(inView) {
                        let (target, _) = try self.isolateRange(
                            piece,
                            Swift.max(pieceStart, span.start),
                            Swift.min(pieceEnd, span.end)
                        )
                        target.recordRemoval(executedAt)
                        record(span, target)
                    }
                    continue
                }
                // A piece live here but removed in the redo's view (by a deletion whose undo the
                // redo never saw) is left alone, as the redoing replica left it: like a deletion, a
                // redo removes only what was live in its view.
                if let inView, piece.isRemovedInView(inView) {
                    continue
                }
                let (target, splitDiff) = try self.isolateRange(
                    piece,
                    Swift.max(pieceStart, span.start),
                    Swift.min(pieceEnd, span.end)
                )
                // `piece` was live, so the split overhead belongs to the live
                // bucket, same as a normal edit's boundary splits.
                diff.addDataSizes(others: splitDiff)
                // Capture the visible range while `target` is still live.
                let (from, to) = try self.findIndexesFromRange(target.createPosRange)
                target.recordRemoval(executedAt)
                record(span, target)
                self.treeByIndex.splayNode(target)
                pairs.append(GCPair(parent: self, child: target))
                if from < to {
                    changes.append(ContentChange<T>(actor: executedAt.actorID, from: from, to: to))
                }
            }
        }

        // Isolating a range inside an already-tombstoned piece buffers born-dead remainders, and a
        // split books the attribute tombstones it copies. Hand them to the caller with the rest:
        // unregistered, they would never be purged and their size would stay uncharged.
        pairs.append(contentsOf: self.drainPendingGCPairs())

        return (pairs, changes, diff, recorded)
    }

    /// Re-snapshots `spans` against the content they address as it stands now.
    ///
    /// Returns an equivalent span set (same insertion identities, same overall intervals) whose
    /// values carry the current attributes. A span is captured when the edit it reverses runs, so
    /// attributes applied to the run afterwards -- a peer's style, which `canStyle` admits even on a
    /// tombstone -- are missing from it; a replica that purged the run would then recreate it with
    /// the stale snapshot while a replica that still holds the tombstone revives the live
    /// attributes, and the two diverge.
    ///
    /// Regions covered by a surviving piece (live or tombstoned) are taken from that piece, so a span
    /// crossing several pieces splits into one span per piece. Regions with no surviving piece keep
    /// the original snapshot -- it is all this replica knows about them. Read-only: the copies it
    /// makes are payload, never inserted, so they book no attribute tombstones.
    ///
    /// - Parameter spans: The spans to re-snapshot.
    /// - Returns: The refreshed spans.
    func refreshSpans(_ spans: [RestoreSpan<T>]) -> [RestoreSpan<T>] {
        var refreshed = [RestoreSpan<T>]()
        func fromSnapshot(_ span: RestoreSpan<T>, _ start: Int32, _ end: Int32) {
            refreshed.append(RestoreSpan(
                createdAt: span.createdAt,
                start: start,
                end: end,
                value: span.value.substring(from: Int(start - span.start), to: Int(end - span.start))
            ))
        }

        for span in spans {
            let pieces = self.findPiecesOverlapping(span.createdAt, span.start, span.end)
            var cursor = span.start
            for piece in pieces {
                let pieceStart = piece.id.offset
                let start = Swift.max(pieceStart, cursor)
                let end = Swift.min(pieceStart + Int32(piece.contentLength), span.end)
                if end <= start {
                    continue
                }
                if start > cursor {
                    fromSnapshot(span, cursor, start)
                }
                refreshed.append(RestoreSpan(
                    createdAt: span.createdAt,
                    start: start,
                    end: end,
                    value: piece.value.substring(from: Int(start - pieceStart), to: Int(end - pieceStart))
                ))
                cursor = end
            }
            if cursor < span.end {
                fromSnapshot(span, cursor, span.end)
            }
        }

        return refreshed
    }

    /**
     * `findPiecesOverlapping` collects existing nodes (live or tombstoned)
     * belonging to the insertion `createdAt` that overlap the absolute-offset
     * interval [start, end), in ascending offset order. Works by descending
     * floorEntry probes over `treeByID`.
     */
    private func findPiecesOverlapping(
        _ createdAt: TimeTicket,
        _ start: Int32,
        _ end: Int32
    ) -> [RGATreeSplitNode<T>] {
        var pieces = [RGATreeSplitNode<T>]()
        var probe = end - 1

        while probe >= 0 {
            let key = RGATreeSplitNodeID(createdAt, probe)
            guard let entry = self.treeByID.floorEntry(key), entry.key.hasSameCreatedAt(key) else {
                break
            }
            let node = entry.value
            let nodeStart = node.id.offset
            let nodeEnd = nodeStart + Int32(node.contentLength)
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
     * `findPieceCovering` returns the node of insertion `createdAt` whose
     * absolute-offset range covers `offset`, if present.
     */
    private func findPieceCovering(
        _ createdAt: TimeTicket,
        _ offset: Int32
    ) -> RGATreeSplitNode<T>? {
        let key = RGATreeSplitNodeID(createdAt, offset)
        guard let entry = self.treeByID.floorEntry(key), entry.key.hasSameCreatedAt(key) else {
            return nil
        }
        let node = entry.value
        let nodeStart = node.id.offset
        let nodeEnd = nodeStart + Int32(node.contentLength)
        if nodeStart <= offset, offset < nodeEnd {
            return node
        }
        return nil
    }

    /**
     * `findRestoreAnchor` returns the physical node to insert a recreated
     * fragment [gapStart, gapEnd) of insertion `createdAt` AFTER.
     *
     * Resolution ladder (all rules key on op-carried data + ID lookups only):
     *  (a) a piece covering gapEnd exists → directly before it
     *      (originally-adjacent successor; exact original slot)
     *  (b) nearest surviving piece of the same insertion left of gapStart
     *      → directly after it
     *  (c) nearest surviving piece of the same insertion at or after gapEnd
     *      → directly before it
     *  (d) chain anchor: the previously placed fragment of this same restore
     *      (document order) → after it, so a purged multi-fragment run is
     *      rebuilt left-to-right rather than reversed
     *  (e) the operation's fallback anchor (refined)
     *  (f) head (deterministic last resort)
     */
    private func findRestoreAnchor(
        _ createdAt: TimeTicket,
        _ gapStart: Int32,
        _ gapEnd: Int32,
        _ executedAt: TimeTicket,
        _ fallbackAnchor: RGATreeSplitPos?,
        _ chainAnchor: RGATreeSplitNode<T>? = nil
    ) throws -> RGATreeSplitNode<T> {
        if let succ = self.findPieceCovering(createdAt, gapEnd), let prev = succ.prev {
            return prev
        }

        if gapStart > 0 {
            let key = RGATreeSplitNodeID(createdAt, gapStart - 1)
            if let entry = self.treeByID.floorEntry(key), entry.key.hasSameCreatedAt(key) {
                return entry.value
            }
        }

        // The nearest surviving piece of the insertion after the gap, not the rightmost one:
        // anchoring before a later piece would place the gap after the pieces in between, and a
        // deletion that later spans from the gap to one of them would run from its start to the end
        // of the text.
        let afterKey = RGATreeSplitNodeID(createdAt, gapEnd)
        if let after = self.treeByID.ceilingEntry(afterKey),
           after.key.hasSameCreatedAt(afterKey),
           let prev = after.value.prev
        {
            return prev
        }

        // (d) No surviving piece of this insertion anchors the fragment. When the
        // whole run was purged, every fragment lands here; anchoring after the
        // fragment placed just before it (document order) keeps the run forward.
        if let chainAnchor {
            return chainAnchor
        }

        if let fallbackAnchor {
            // The anchor may have been fully purged; fall through to the head
            // when it can no longer be resolved.
            if let left = try? self.findNodeWithSplit(self.refinePos(fallbackAnchor), executedAt).0 {
                return left
            }
        }

        return self.head
    }

    /**
     * `isolateRange` splits `piece` so that a node exactly covering the
     * absolute-offset interval [from, to) exists, and returns it along with the
     * net metadata-size overhead the split(s) introduced.
     *
     * When `piece` is live, this overhead is a normal live-bucket cost (same as
     * any other boundary split) and the caller should `root.acc` it. When
     * `piece` is tombstoned, `splitNode` itself buffers the overhead of any
     * born-removed fragment via `pendingGCPairs` (see `drainPendingGCPairs`),
     * so the returned diff is zero in that case — the caller must still drain
     * and register those pairs.
     *
     * Requires: `pieceStart <= from < to <= pieceEnd`.
     */
    private func isolateRange(
        _ piece: RGATreeSplitNode<T>,
        _ from: Int32,
        _ to: Int32
    ) throws -> (RGATreeSplitNode<T>, DataSize) {
        var diff = DataSize(data: 0, meta: 0)
        var node = piece
        let nodeStart = node.id.offset
        if from > nodeStart {
            let (right, splitDiff) = try self.splitNode(node, from - nodeStart)
            diff.addDataSizes(others: splitDiff)
            if let right {
                node = right
            }
        }
        let newStart = node.id.offset
        if to < newStart + Int32(node.contentLength) {
            let (_, splitDiff) = try self.splitNode(node, to - newStart)
            diff.addDataSizes(others: splitDiff)
        }
        return (node, diff)
    }

    /**
     * `bookCopiedAttrTombstones` registers the attribute tombstones a freshly
     * copied value has just duplicated. `CRDTTextValue.substring` -- which both
     * `splitNode` and `restore`'s recreate path go through -- deep-copies the
     * whole RHT, tombstones included; it has to, or a piece would resolve a
     * concurrent style differently from a replica that never split or never
     * lost it. Each copy is a fresh piece of garbage under a new parent with no
     * registration of its own: the original's pair names the original's
     * parent, so without this the copy sits in the RHT forever, uncounted and
     * unpurgeable. The copy was never in `docSize.live` -- `getDataSize`
     * excludes removed attributes -- so `gcOnlySize` charges it to gc alone,
     * and `purge` subtracts the same size back out.
     */
    private func bookCopiedAttrTombstones(_ value: T) {
        self.pendingGCPairs.append(contentsOf: value.getGCPairs())
    }

    /**
     * `drainPendingGCPairs` returns the GC pairs buffered in `pendingGCPairs`
     * and clears the buffer.
     */
    func drainPendingGCPairs() -> [GCPair] {
        let pairs = self.pendingGCPairs
        self.pendingGCPairs = []
        return pairs
    }

    private func deleteNodes(
        _ candidates: [RGATreeSplitNode<T>],
        _ editedAt: TimeTicket,
        _ vector: VersionVector? = nil
    ) throws -> ([ContentChange<T>],
                 [RGATreeSplitNode<T>],
                 Set<String>)
    {
        guard !candidates.isEmpty else {
            return ([], [], [])
        }
        // An empty vector is a local change too, as yorkie-js-sdk and the server
        // read it; treating it as remote made every node look unknown, so the
        // deletion removed nothing.
        let isLocal = vector == nil || vector?.size() == 0
        // 01. Collect nodes to remove and keep.
        var nodesToRemove: [RGATreeSplitNode<T>] = []
        var nodesToKeep: [RGATreeSplitNode<T>?] = []
        let (leftEdge, rightEdge) = try findEdgesOfCandidates(candidates)
        nodesToKeep.append(leftEdge)

        for node in candidates {
            let creationKnown = isLocal || vector!.afterOrEqual(other: node.createdAt)
            let tombstoneKnown = node.isRemoved && (isLocal || vector!.afterOrEqual(other: node.removedAt!))

            // Once a tombstone can be cancelled by an undo, "the deleter knew the node" is not
            // enough -- the node has to have been LIVE in the deleter's view. A node the deleter saw
            // removed and an undo revived here has to survive the deletion on every replica.
            let liveInView = isLocal
                ? !node.isRemoved
                : creationKnown && !node.isRemovedInView(vector!)
            if liveInView, node.canRemove(editedAt, creationKnown, tombstoneKnown) {
                nodesToRemove.append(node)
            } else {
                // A node this deletion saw live but someone else removed concurrently records the
                // deletion all the same. Otherwise an undo of the other deletion revives it on
                // replicas that applied the two in one order and not in the other.
                if !isLocal, liveInView, node.isRemoved {
                    node.recordRemoval(editedAt)
                }
                nodesToKeep.append(node)
            }
        }
        nodesToKeep.append(rightEdge)

        // 02. Create value changes with previous indexes before deletion.
        let changes = try makeChanges(nodesToKeep, editedAt)

        // 03. Mark tombstones for removal. Keep `nodesToRemove` (document) order so callers can
        // reconstruct the removed content left-to-right (Swift Dictionary is unordered).
        // Nodes that were already removed (concurrent LWW overwrite of an
        // existing tombstone) are tracked separately: they already have a
        // registered GC pair, and registering a second one would
        // toggle-unregister the first.
        var removedNodes: [RGATreeSplitNode<T>] = []
        var alreadyRemovedIDs = Set<String>()
        for node in nodesToRemove {
            if node.isRemoved {
                alreadyRemovedIDs.insert(node.toIDString)
            }
            node.recordRemoval(editedAt)
            removedNodes.append(node)
        }

        // 04. Clear the index tree of the given deletion boundaries.
        self.deleteIndexNodes(nodesToKeep)

        return (changes, removedNodes, alreadyRemovedIDs)
    }

    /**
     * `findEdgesOfCandidates` finds the edges outside `candidates`,
     * (which has not already been deleted, or be undefined but not yet implemented)
     * right edge is undefined means `candidates` contains the end of text.
     */
    private func findEdgesOfCandidates(_ candidates: [RGATreeSplitNode<T>]) throws -> (RGATreeSplitNode<T>, RGATreeSplitNode<T>?) {
        guard let prev = candidates[0].prev else {
            throw YorkieError(code: .errInvalidArgument, message: "prev must not nil!")
        }

        return (prev, candidates[safe: candidates.count - 1]?.next)
    }

    private func makeChanges(_ boundaries: [RGATreeSplitNode<T>?], _ editedAt: TimeTicket) throws -> [ContentChange<T>] {
        var changes = [ContentChange<T>]()
        var fromIdx: Int, toIdx: Int

        for index in 0 ..< (boundaries.count - 1) {
            guard let leftBoundary = boundaries[index] else {
                continue
            }

            let rightBoundary = boundaries[index + 1]

            if leftBoundary.next === rightBoundary {
                continue
            }

            guard let range = leftBoundary.next?.createPosRange else {
                throw YorkieError(code: .errUnexpected, message: "The next node of leftBoundary is nil")
            }

            fromIdx = try self.findIndexesFromRange(range).0
            if rightBoundary != nil {
                guard let range = rightBoundary!.prev?.createPosRange else {
                    throw YorkieError(code: .errUnexpected, message: "The prev node of rightBoundary is nil")
                }

                toIdx = try self.findIndexesFromRange(range).1
            } else {
                toIdx = self.treeByIndex.length
            }

            if fromIdx < toIdx {
                changes.append(ContentChange<T>(actor: editedAt.actorID, from: fromIdx, to: toIdx, content: nil))
            }
        }

        return changes.reversed()
    }

    /**
     * `deleteIndexNodes` clears the index nodes of the given deletion boundaries.
     * The boundaries mean the nodes that will not be deleted in the range.
     */
    private func deleteIndexNodes(_ boundaries: [RGATreeSplitNode<T>?]) {
        for index in 0 ..< (boundaries.count - 1) {
            let leftBoundary = boundaries[index]
            let rightBoundary = boundaries[index + 1]
            // If there is no node to delete between boundaries, do notting.
            if leftBoundary != nil, leftBoundary!.next !== rightBoundary {
                self.treeByIndex.cutOffRange(leftBoundary!, rightBoundary)
            }
        }
    }
}

extension RGATreeSplit: GCParent {
    /**
     * `purge` physically purges the given node from RGATreeSplit.
     */
    func purge(node: any GCChild) {
        guard let node = node as? RGATreeSplitNode<T> else {
            return
        }
        self.cancelled?.removeValue(forKey: ObjectIdentifier(node))
        self.treeByIndex.delete(node)
        self.treeByID.remove(node.id)

        node.prev?.setNext(node.next)
        node.next?.setPrev(node.prev)

        node.setPrev(nil)
        node.setNext(nil)

        node.insPrev?.setInsNext(node.insNext)
        node.insNext?.setInsPrev(node.insPrev)

        node.setInsPrev(nil)
        node.setInsNext(nil)
    }

    /**
     * `purgeBarrierAt` implements `GCParent.purgeBarrierAt`. `findNodeWithSplit`
     * skips forward while the next node was created after the incoming edit,
     * so a tombstone whose `createdAt` precedes the edit stops that walk.
     * Unlinking it hands the next node the stopping decision, which is only the
     * same decision once that node is causally stable.
     */
    func purgeBarrierAt(node: any GCChild) -> TimeTicket? {
        guard let node = node as? RGATreeSplitNode<T> else {
            return nil
        }
        return node.next?.createdAt
    }
}

extension RGATreeSplit: Sequence {
    func makeIterator() -> NodeIterator {
        NodeIterator(head: self.head)
    }

    class NodeIterator: IteratorProtocol {
        // swiftlint: disable nesting
        typealias Element = RGATreeSplitNode<T>

        private var head: Element?

        init(head: Element?) {
            self.head = head
        }

        func next() -> Element? {
            let next = self.head
            self.head = self.head?.next
            return next
        }
        // swiftlint: enable nesting
    }
}
