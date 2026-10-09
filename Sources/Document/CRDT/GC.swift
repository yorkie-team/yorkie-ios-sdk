/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

/**
 * `GCPair` is a structure that represents a pair of parent and child for garbage
 * collection.
 */
struct GCPair {
    var parent: GCParent?
    var child: GCChild?

    /**
     * `gcOnlySize` is set when the child's size was never counted in
     * `docSize.live`: a piece born removed by splitting an already-tombstoned
     * node, a tree node recreated already-tombstoned by a restore because its
     * parent has been removed since (see `CRDTTree.recreateFromSpan`), an
     * attribute tombstone duplicated by a value copy (a split, or a node
     * recreated from a span), or a tombstone registered when an element is
     * registered (live only counts visible nodes there). When present,
     * `registerGCPair` adds this size to `docSize.gc` and leaves
     * `docSize.live` untouched, instead of moving the child's size from live
     * to gc.
     */
    var gcOnlySize: DataSize?
}

/**
 * `GCParent` is an interface for the parent of the garbage collection target.
 */
protocol GCParent: AnyObject {
    func purge(node: GCChild)

    /**
     * `purgeBarrierAt` is an optional capability of a GC parent whose surviving
     * order is decided by which nodes are still linked.
     *
     * Every such container resolves a concurrent insert by walking forward from
     * the anchor and stopping at the first node whose positioning ticket does
     * not follow the insert: ``RGATreeList``'s `findNextBeforeExecutedAt`, the
     * skip in ``RGATreeSplit``'s `findNodeWithSplit`, and the sibling skip in
     * ``CRDTTree``'s `findNodesAndSplitText`. The walk reads the nodes currently
     * linked, tombstones included, so a tombstone with a small ticket is a hard
     * barrier that ends the walk. Purging it physically unlinks it, which means
     * collection mutates the input to the insertion rule: a replica that has
     * collected sends a still-in-flight insert past the node behind the
     * tombstone, a replica that has not does not, and the two orders never
     * reconverge.
     *
     * `removedAt` alone does not authorise the unlink. What does is the node
     * that would become the walk's new stopping point: once that node is
     * causally stable, every future insert carries a ticket after it, so every
     * future walk stops there whether or not the tombstone in front of it still
     * exists. This returns that successor's positioning ticket, which
     * ``CRDTRoot/garbageCollect(minSyncedVersionVector:)`` requires the version
     * vector to cover as well as `removedAt`, or `nil` when the child has no
     * successor (or is not a child of this kind) and unlinking it cannot move
     * anything.
     *
     * Mirrors Go's `crdt.GCBarrier` (yorkie `ba82ed91`). Declared as a
     * requirement (not only an extension default) so a conforming type's
     * override is still reached through a `GCParent` existential.
     */
    func purgeBarrierAt(node: GCChild) -> TimeTicket?
}

extension GCParent {
    /**
     * `purgeBarrierAt` defaults to no barrier. Only a parent whose `purge`
     * unlinks a node of an RGA order (``RGATreeList``, ``RGATreeSplit``,
     * ``CRDTTree``) overrides this; an attribute-RHT parent (``CRDTTreeNode``,
     * ``CRDTTextValue``) has no positional order for a purge to disturb.
     */
    func purgeBarrierAt(node: GCChild) -> TimeTicket? {
        return nil
    }
}

/**
 * `GCChild` is an interface for the child of the garbage collection target.
 */
protocol GCChild: AnyObject {
    var toIDString: String { get }
    var removedAt: TimeTicket? { get }
    func getDataSize() -> DataSize
}

protocol CRDTGCPairContainable: CRDTElement {
    func getGCPairs() -> [GCPair]
}
