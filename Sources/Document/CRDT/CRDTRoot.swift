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
 * `GCCharge` is what `docSize.gc` is holding on behalf of one element, and
 * which element that is. See ``CRDTRoot/sizeInGC`` for why the identity matters.
 */
private struct GCCharge {
    let element: CRDTElement
    let size: DataSize
}

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
     * `sizeInGC` maps the creation time of every registered element whose size
     * counts toward `docSize.gc` rather than `docSize.live`, to the exact amount
     * charged and to the element it is charged for. Each element's size belongs
     * to exactly one of the two, and an element reaches gc by more routes than it
     * has removals: it can be removed itself, or be a descendant of a removed
     * container. Recording the amount rather than a flag keeps the two sides
     * symmetric even though `getDataSize` is not stable over an element's
     * lifetime -- it grows by a ticket the moment `removedAt` is set, which can
     * happen after the size has already moved.
     *
     * The identity is load-bearing. A createdAt is meant to name one element, but
     * it does not for the whole of a document's life: undo restores a `deepcopy`
     * of a removed element, and the copy keeps the original's createdAt while the
     * original is still a tombstone. Charging or releasing by key alone then
     * bills whichever of the two occupies the slot, and a size can be taken out
     * of `docSize.live` that live was never holding -- which is how docSize goes
     * negative.
     *
     * A zero size is not the same as no record. It says this element has been
     * released: charged to neither side, because its subtree was orphaned by a
     * restore and nothing will ever collect it. Anything that later charges it
     * again has to know live is not the side to take it from.
     *
     * The "exactly one of the two" rule covers whole-element moves only. Content
     * accumulated into an element that already sits in gc does not follow it:
     * `acc` and ``registerGCPair(_:)`` book against live regardless of this
     * ledger, so a Text or Tree edited inside an already-removed container keeps
     * that content charged to live (yorkie-js-sdk#1349).
     */
    private var sizeInGC: [String: GCCharge] = [:]
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
        self.rootObject.getDescendants(callback: { element, _ in
            if element.removedAt != nil {
                self.registerRemovedElement(element)
            }
            if let element = element as? CRDTGCPairContainable {
                for pair in element.getGCPairs() {
                    self.registerGCPair(pair)
                }
            }
            // NOTE(#1227): Register dead position nodes in CRDTArray as GC pairs so
            // they are collected once all peers have applied the winning move.
            if let array = element as? CRDTArray {
                for node in array.getAllRGANodes() {
                    if node.getElementEntry() == nil, node.getPositionRemovedAt() != nil {
                        self.registerGCPair(GCPair(parent: array.getRGATreeList(), child: node))
                    }
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

    /**
     * `findElementPairByCreatedAt` returns the element and its parent of the given creation time.
     *
     * Used by undo/redo to walk up the ancestor chain and detect whether any ancestor was removed.
     */
    func findElementPairByCreatedAt(_ createdAt: TimeTicket) -> CRDTElementPair? {
        return self.elementPairMapByCreatedAt[createdAt.toIDString]
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
     * `deregisterElement` deregister the given element and its descendants from hash table.
     */
    @discardableResult
    func deregisterElement(_ element: CRDTElement) -> Int {
        var count = 0

        let deregisterElementInternal: (CRDTElement) -> Void = { [unowned self] element in
            let createdAt = element.createdAt.toIDString
            // Subtract the size from wherever it is actually counted, and by the
            // amount actually charged. A descendant created inside an
            // already-removed container never passed through a removal, so it still
            // sits in live; subtracting it from gc would push gc below zero and
            // leave its cost in live forever.
            // A charge recorded against some other element that shares this
            // createdAt says nothing about this one, which is still in live.
            if let charged = self.sizeInGC[createdAt], charged.element === element {
                self.docSize.gc.subDataSize(others: charged.size)
                self.sizeInGC[createdAt] = nil
            } else {
                self.docSize.live.subDataSize(others: element.getDataSize())
            }

            // NOTE(hackerwins): Drop the index entries by identity, not by key. A
            // createdAt is meant to name one element, but undo breaks that: it
            // restores a `deepcopy` of a removed container, and the copy keeps every
            // descendant's createdAt while the original is still a tombstone. Only
            // the top level of an undone array set gets a fresh ticket, so the
            // descendants below it are answered by the live copy while the tombstone
            // is still the one being collected here. Deleting by key would evict the
            // live element's entry, and every later operation addressed at it throws
            // `fail to find` -- inside `applyChangePack`, which is the permanent
            // desync this release exists to stop.
            //
            // The tombstone loses nothing by it: it is already unlinked from the
            // tree, and whatever now owns the slot will clear it when its own turn
            // comes. `gcElementSetByCreatedAt` carries no element of its own, so the
            // pair map is what decides the identity for both.
            if self.elementPairMapByCreatedAt[createdAt]?.element === element {
                self.elementPairMapByCreatedAt[createdAt] = nil
                self.gcElementSetByCreatedAt.remove(createdAt)
            }
            count += 1
        }

        deregisterElementInternal(element)
        (element as? CRDTContainer)?.getDescendants { element, _ in
            deregisterElementInternal(element)
            return false
        }

        return count
    }

    /**
     * `registerRemovedElement` registers the given element to the hash set.
     */
    func registerRemovedElement(_ element: CRDTElement) {
        let moved = self.moveSizeToGC(element)

        // NOTE(hackerwins): registerElement books a container and every descendant
        // into live, and deregisterElement subtracts both when the tombstone is
        // collected. Removing a container therefore has to move its descendants as
        // well: booking only the container itself would strand their size in live
        // forever and drive gc negative once the collection subtracted them.
        if let element = element as? CRDTContainer {
            element.getDescendants { [unowned self] element, _ in
                _ = self.moveSizeToGC(element)
                return false
            }
        }

        // NOTE(hackerwins): When an element is removed, parent sets the removedAt
        // to mark the child as removed. That ticket is part of the size charged to
        // gc just now, but it was not part of what live held -- registerElement ran
        // before the removal -- so live gets it back. Only on the move that carried
        // it: a size already in gc, or one moved as a descendant while its own
        // removedAt is still unset, did not.
        //
        // This holds for the incremental path. Two known exceptions, both
        // pre-existing and both leaving the refund inexact:
        //
        // - The initializer registers an already-tombstoned element at its
        //   post-removal size, so live did hold the ticket and the refund
        //   over-credits by one per *outermost* tombstone (nested ones take the
        //   top-up path in `moveSizeToGC` and are not refunded).
        // - The born-removed branch in `SetOperation` (#1226) marks the LWW-losing
        //   value removed before `registerElement` books it, so live holds the
        //   ticket there too and the losing replica ends one ticket high
        //   (yorkie-js-sdk#1349).
        //
        // Use ``adoptRemovedElement(_:)`` for any new path that adopts an element
        // already booked at its post-removal size.
        if moved, element.removedAt != nil {
            self.docSize.live.meta += timeTicketSize
        }

        self.gcElementSetByCreatedAt.insert(element.createdAt.toIDString)
    }

    /**
     * `adoptRemovedElement` registers an element that was **already tombstoned when
     * it was registered**, so `registerElement` booked it at its post-removal size.
     *
     * Unlike ``registerRemovedElement(_:)`` this does not refund the tombstone
     * ticket to live: live never held a pre-removal size to get it back from. Use
     * it when a removed element is adopted wholesale, as when an undo restores a
     * deepcopy whose members carry `removedAt`.
     */
    func adoptRemovedElement(_ element: CRDTElement) {
        _ = self.moveSizeToGC(element)

        if let element = element as? CRDTContainer {
            element.getDescendants { [unowned self] element, _ in
                _ = self.moveSizeToGC(element)
                return false
            }
        }

        self.gcElementSetByCreatedAt.insert(element.createdAt.toIDString)
    }

    /**
     * `moveSizeToGC` moves the size of the given element from live to gc, and
     * reports whether it moved a size live was holding. A size already charged to
     * gc for this same element -- because it was removed before, because a
     * container above it was, or because a restore released it -- only has its
     * charge topped up: `getDataSize` grows by a ticket when `removedAt` is set,
     * which can happen after the move.
     *
     * A charge recorded against a different element that shares this createdAt is
     * not this element's: this one is still in live and moves in full. The record
     * it displaces is a released one (zero), so nothing charged is lost.
     */
    private func moveSizeToGC(_ element: CRDTElement) -> Bool {
        let createdAt = element.createdAt.toIDString
        let size = element.getDataSize()

        if let charged = self.sizeInGC[createdAt], charged.element === element {
            self.docSize.gc.addDataSizes(others: DataSize(data: size.data - charged.size.data,
                                                          meta: size.meta - charged.size.meta))
            self.sizeInGC[createdAt] = GCCharge(element: element, size: size)
            return false
        }

        self.docSize.gc.addDataSizes(others: size)
        self.docSize.live.subDataSize(others: size)
        self.sizeInGC[createdAt] = GCCharge(element: element, size: size)
        return true
    }

    /**
     * `unregisterRemovedElementPair` drops the collection entry registered under
     * the given createdAt, if there is one, and releases the charge it holds. It
     * reports whether an entry was dropped.
     *
     * It is the narrow counterpart of ``registerRemovedElement(_:)``, for the one
     * caller that has to retire a tombstone without collecting it: a `Set` that
     * restores an element under a createdAt a tombstone already answers to.
     * ``ElementRHT/set(key:value:)`` has by then re-pointed `nodeMapByCreatedAt` at
     * the restored copy, so the entry the removal left behind now resolves, through
     * that index, to live data -- and collection would purge it.
     *
     * Deliberately narrow. The obvious alternative, deregistering the tombstone
     * and its descendants outright, reaches past the entry that is stale: the
     * tombstone's descendant set can be a strict superset of the restored copy's
     * -- a peer may have added a child into the container after the undoing
     * replica took its copy -- and deregistering evicts those descendants from
     * `elementPairMapByCreatedAt` with nothing to put them back. A later change
     * addressed at one of them then throws inside `applyChangePack` on every
     * replica, and permanently on the server, which replays the same change log
     * to rebuild the document and its snapshots.
     *
     * What it still does reach is the accounting, and it has to. The subtree is
     * orphaned by the restore, so dropping the entry is dropping the only thing
     * that would ever have collected it. Its cost is released from wherever it
     * sits -- `docSize.gc` for anything a removal moved there, `docSize.live` for
     * a member a peer added into the container after it was already removed.
     *
     * - Parameter createdAt: The creation time whose collection entry is retired.
     * - Returns: `true` if an entry was dropped, `false` if there was none.
     */
    @discardableResult
    func unregisterRemovedElementPair(_ createdAt: TimeTicket) -> Bool {
        let key = createdAt.toIDString
        guard self.gcElementSetByCreatedAt.contains(key) else {
            return false
        }

        guard let element = self.elementPairMapByCreatedAt[key]?.element else {
            // The worklist carries no element of its own; with nothing to resolve it
            // through there is no charge to release and no identity to compare.
            // Dropping the entry is still right -- it can never be collected.
            self.gcElementSetByCreatedAt.remove(key)
            return true
        }

        self.release(element)
        (element as? CRDTContainer)?.getDescendants { [unowned self] element, _ in
            self.release(element)
            return false
        }

        self.gcElementSetByCreatedAt.remove(key)
        return true
    }

    /**
     * `release` forgets the cost of an element that has become unreachable
     * without being collected, and any collection entry naming it. It leaves
     * `elementPairMapByCreatedAt` alone: the slot may since have been taken over
     * by a live element restored under this same createdAt, and that element's
     * registration has to stand.
     */
    private func release(_ element: CRDTElement) {
        let createdAt = element.createdAt.toIDString

        // Subtract from whichever side is actually holding it, by the amount
        // actually charged -- the same split `deregisterElement` makes. A member
        // added into an already-removed container never passed through a removal,
        // so it still sits in live.
        if let charged = self.sizeInGC[createdAt], charged.element === element {
            self.docSize.gc.subDataSize(others: charged.size)
        } else {
            self.docSize.live.subDataSize(others: element.getDataSize())
        }

        // Record the release rather than forgetting it. This element stays
        // addressable -- that is the whole point of not deregistering it -- so a
        // peer that has not seen the restore can still remove something inside this
        // subtree, and `moveSizeToGC` would then take its size out of live for a
        // second time and drive docSize negative. A zero charge says live is not
        // holding it, and the identity says which element that is about, so a copy
        // restored under the same createdAt is still charged normally.
        self.sizeInGC[createdAt] = GCCharge(element: element, size: DataSize(data: 0, meta: 0))

        if self.elementPairMapByCreatedAt[createdAt]?.element === element {
            self.gcElementSetByCreatedAt.remove(createdAt)
        }
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

        if let gcOnlySize = pair.gcOnlySize {
            // NOTE: The child's size was never counted in docSize.live (it was
            // born removed, or it was registered by the snapshot-load scan where
            // live only counts visible nodes), so there is nothing to move out
            // of live. Only the given size is added to gc; purge subtracts the
            // child's size from gc as usual.
            self.docSize.gc.addDataSizes(others: gcOnlySize)
            return
        }

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
     * `unregisterGCPair` removes the given pair from the hash table. Called
     * when a tombstoned node is revived (un-tombstoned) by an
     * identity-preserving undo, so that a later re-registration (redo) is not
     * swallowed by the toggle in `registerGCPair`.
     *
     * NOTE: must be called AFTER the node's `removedAt` has been cleared, so
     * `getDataSize()` no longer includes the tombstone ticket.
     */
    func unregisterGCPair(_ pair: GCPair) {
        guard let childID = pair.child?.toIDString, self.gcPairMap[childID] != nil else {
            return
        }

        self.gcPairMap.removeValue(forKey: childID)

        guard let size = pair.child?.getDataSize() else {
            return
        }

        // Mirror registerGCPair's accounting: move the node's size back from
        // gc to live, and drop the tombstone ticket counted at register time.
        self.docSize.gc.subDataSize(others: size)
        self.docSize.live.addDataSizes(others: size)
        if !(pair.child is RHTNode) {
            self.docSize.gc.meta -= timeTicketSize
        }
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
    func getDocSize() -> DocSize {
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
            // NOTE(hackerwins): Neither lookup is guaranteed to hit. A document
            // written by an SDK that registered an element without its parent, or
            // that left two elements under one createdAt, holds a member of this set
            // that cannot be reached for purging.
            //
            // Skip it rather than drop it. The element is still in the document and
            // its size is still charged to `docSize.gc`, which only
            // `deregisterElement` releases; forgetting the member would leave that
            // charge counted against the size limit with nothing left reporting it
            // as garbage. ``garbageElementSetSize`` already guards the same lookup.
            guard let pair = self.elementPairMapByCreatedAt[createdAt], let parent = pair.parent else {
                continue
            }

            if let removedAt = pair.element.removedAt, minSyncedVersionVector.afterOrEqual(other: removedAt) {
                do {
                    try parent.purge(element: pair.element)
                } catch {
                    // A throw here now means a genuine mis-registration: both
                    // purge paths return quietly when the slot has merely been
                    // taken over by a restored copy. Skip rather than
                    // deregister -- deregistering an element the purge left
                    // linked in the tree drops its registration and releases
                    // its `docSize.gc` charge, which is exactly the charge with
                    // nothing reporting it as garbage that the guard above
                    // exists to prevent. Letting it throw is #1340.
                    Logger.error("garbageCollect: failed to purge \(createdAt)", error: error)
                    continue
                }
                count += self.deregisterElement(pair.element)
            }
        }

        for pair in self.gcPairMap.values {
            if let child = pair.child, child.removedAt == nil {
                // Node was revived but its pair was not unregistered. Reverse the
                // GC accounting (gc → live) and drop the stale entry via
                // unregisterGCPair so the registerGCPair toggle can't be tripped
                // later and docSize.gc/live stay consistent.
                self.unregisterGCPair(pair)
                continue
            }

            if let child = pair.child, let removedAt = child.removedAt, minSyncedVersionVector.afterOrEqual(other: removedAt) {
                pair.parent?.purge(node: child)
                if let datasize = pair.child?.getDataSize() {
                    self.docSize.gc.subDataSize(others: datasize)
                }
                self.gcPairMap.removeValue(forKey: child.toIDString)
                count += 1
            }
        }

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
    func acc(_ diff: DataSize) {
        self.docSize.live.addDataSizes(others: diff)
    }
}

extension CRDTRoot: CustomDebugStringConvertible {
    var debugDescription: String {
        self.toSortedJSON()
    }
}
