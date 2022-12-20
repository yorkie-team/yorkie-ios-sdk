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

protocol RGATreeSplitValue {
    var length: Int { get }
    func substring(indexStart: Int, indexEnd: Int?) -> Self
}

extension RGATreeSplitValue {
    // for make dummy instance.
    init() { }
}

/**
 * `RGATreeSplitNodeID` is an ID of RGATreeSplitNode.
 */
public class RGATreeSplitNodeID: Equatable, Comparable {
    public static let initial = RGATreeSplitNodeID(TimeTicket.initial, 0)
    
    /**
     * `createdAt` the creation time of this ID.
     */
    public let createdAt: TimeTicket
    /**
     * `offset` the offset of this ID.
     */
    public let offset: Int
    
    init(_ createdAt: TimeTicket, _ offset: Int) {
        self.createdAt = createdAt
        self.offset = offset
    }
        
    /**
     * `==` returns whether given ID equals to this ID or not.
     */
    public static func == (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.offset == rhs.offset
    }
    
    // TODO: see createComparator in RGATreeSplitNode!
    public static func < (lhs: RGATreeSplitNodeID, rhs: RGATreeSplitNodeID) -> Bool {
        lhs.createdAt < rhs.createdAt
    }

    /**
     * `hasSameCreatedAt` returns whether given ID has same creation time with this ID.
     */
    public func hasSameCreatedAt(other: RGATreeSplitNodeID) -> Bool {
        self.createdAt == other.createdAt
    }
    
    /**
     * `split` creates a new ID with an offset from this ID.
     */
    public func split(_ offset: Int) -> RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.createdAt, self.offset + offset)
    }
    
    /**
     * `structureAsString` returns a String containing
     * the meta data of the node id for debugging purpose.
     */
    public var structureAsString: String {
        "\(self.createdAt.structureAsString):\(self.offset)"
    }
}

/**
 * `RGATreeSplitNodePos` is the position of the text inside the node.
 */
public class RGATreeSplitNodePos: Equatable {
    public let id: RGATreeSplitNodeID
    public let relativeOffset: Int
    
    init(_ id: RGATreeSplitNodeID, _ relativeOffset: Int) {
        self.id = id
        self.relativeOffset = relativeOffset
    }

    /**
     * `absoluteID` returns the absolute id of this RGATreeSplitNodePos.
     */
    public var absoluteID: RGATreeSplitNodeID {
        RGATreeSplitNodeID(self.id.createdAt, self.id.offset + self.relativeOffset)
    }
    
    /**
     *`structureAsString` returns a String containing
     * the meta data of the position for debugging purpose.
     */
    public var structureAsString: String {
        "\(self.id.structureAsString):\(self.relativeOffset)"
    }
    
    /**
     * `==` returns whether given pos equal to this pos or not.
     */
    public static func == (lhs: RGATreeSplitNodePos, rhs: RGATreeSplitNodePos) -> Bool {
        lhs.id == rhs.id && lhs.relativeOffset == rhs.relativeOffset
    }
}

public typealias RGATreeSplitNodeRange = (RGATreeSplitNodePos, RGATreeSplitNodePos)

/**
 * `RGATreeSplitNode` is a node of RGATreeSplit.
 */
class RGATreeSplitNode<T: RGATreeSplitValue>: SplayNode<T> {
    /**
     * `id` returns the ID of this RGATreeSplitNode.
     */
    public let id: RGATreeSplitNodeID
    
    /**
     * `removedAt` returns the remove time of this node.
     */
    private(set) var removedAt: TimeTicket?
    
    /**
     * `prev` sets or returns a previous node of this node.
     */
    public var prev: RGATreeSplitNode<T>? {
        didSet {
            self.prev?.next = self
        }
    }
    
    /**
     * `next` sets or returns a next node of this node.
     */
    public var next: RGATreeSplitNode<T>? {
        didSet {
            self.next?.prev = self
        }
    }
    
    /**
     * `insPrev` sets or returns a previous node of this node insertion.
     */
    public var insPrev: RGATreeSplitNode<T>? {
        didSet {
            self.insPrev?.insNext = self
        }
    }
    
    /**
     * `insNext` sets, returns a next node of this node insertion.
     */
    public var insNext: RGATreeSplitNode<T>? {
        didSet {
            self.insNext?.insPrev = self
        }
    }
    
    init(_ id: RGATreeSplitNodeID, _ value: T? = nil, _ removedAt: TimeTicket? = nil) {
        super.init(value ?? T())
        
        self.id = id
        self.removedAt = removedAt
    }
    
    /**
     * `createdAt` returns creation time of the Id of RGATreeSplitNode.
     */
    public var createdAt: TimeTicket {
        self.id.createdAt
    }

    /**
     * `length` returns the length of this node.
     */
    public override var length: Int {
        guard self.removedAt != nil else {
            return 0
        }
        
        return self.contentLength
    }

    /**
     * `contentLength` returns the length of this value.
     */
    public var contentLength: Int {
        self.value.length
    }

    /**
     * `insPrevID` returns a ID of previous node insertion.
     */
    public var insPrevID: RGATreeSplitNodeID? {
        self.insPrev?.id
    }

    /**
     * `hasNext` checks if next node exists.
     */
    public var hasNext: Bool {
        self.next != nil
    }

    /**
     * `hasInsPrev` checks if previous insertion node exists.
     */
    public var hasInsPrev: Bool {
        self.insPrev != nil
    }

    /**
     * `isRemoved` checks if removed time exists.
     */
    public var isRemoved: Bool {
        self.removedAt != nil
    }

    /**
     * `split` creates a new split node of the given offset.
     */
    public func split(offset: Int) -> RGATreeSplitNode<T> {
        RGATreeSplitNode(
            self.id.split(offset),
            self.splitValue(offset),
            self.removedAt
        )
    }

    /**
     * `canDelete` checks if node is able to delete.
     */
    public func canDelete(_ editedAt: TimeTicket, _ latestCreatedAt: TimeTicket) -> Bool {
        guard self.createdAt.after(latestCreatedAt) else {
            return false
        }
        
        if let removedAt {
            return editedAt.after(removedAt)
        }
        
        return true
    }

    /**
     * `remove` removes node of given edited time.
     */
    public func remove(_ editedAt: TimeTicket?) {
        self.removedAt = editedAt
    }

    /**
     * `createRange` creates ranges of RGATreeSplitNodePos.
     */
    public var createRange: RGATreeSplitNodeRange {
        (RGATreeSplitNodePos(self.id, 0), RGATreeSplitNodePos(self.id, self.length))
    }

    /**
     * `deepcopy` returns a new instance of this RGATreeSplitNode without structural info.
     */
    public func deepcopy() -> RGATreeSplitNode<T> {
      RGATreeSplitNode(self.id, self.value, self.removedAt)
    }

    /**
     * `structureAsString` returns a String containing
     * the meta data of the node for debugging purpose.
     */
    public var structureAsString: String {
        "\(self.id.structureAsString) \(String(describing: self.value)))"
    }

    private func splitValue(_ offset: Int) -> T {
        self.value = value.substring(indexStart: 0, indexEnd: offset)
        return value.substring(indexStart: offset, indexEnd: value.length)
    }
}

/**
 * `RGATreeSplit` is a block-based list with improved index-based lookup in RGA.
 * The difference from RGATreeList is that it has data on a block basis to
 * reduce the size of CRDT metadata. When an edit occurs on a block,
 * the block is split.
 */
class RGATreeSplit<T: RGATreeSplitValue> {
    private var head: RGATreeSplitNode<T>
    private var treeByIndex: SplayTree<T>
    private var treeByID: RedBlackTree<RGATreeSplitNodeID, RGATreeSplitNode<T>>
    private var removedNodeMap = [String: RGATreeSplitNode<T>]()

    init() {
        self.head = RGATreeSplitNode(RGATreeSplitNodeID.initial)
        self.treeByIndex = SplayTree()
        self.treeByID = LLR
        
    }
/*
    constructor() {
      this.head = RGATreeSplitNode.create(InitialRGATreeSplitNodeID);
      this.treeByIndex = new SplayTree();
      this.treeByID = new LLRBTree(RGATreeSplitNode.createComparator());
      this.removedNodeMap = new Map();

      this.treeByIndex.insert(this.head);
      this.treeByID.put(this.head.getID(), this.head);
    }

    /**
     * `create` creates a instance RGATreeSplit.
     */
    public static create<T extends RGATreeSplitValue>(): RGATreeSplit<T> {
      return new RGATreeSplit();
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
     * @param latestCreatedAtMapByActor - latestCreatedAtMapByActor
     * @returns `[RGATreeSplitNodePos, Map<string, TimeTicket>, Array<Change>]`
     */
    public edit(
      range: RGATreeSplitNodeRange,
      editedAt: TimeTicket,
      value?: T,
      latestCreatedAtMapByActor?: Map<string, TimeTicket>,
    ): [RGATreeSplitNodePos, Map<string, TimeTicket>, Array<TextChange>] {
      // 01. split nodes with from and to
      const [toLeft, toRight] = this.findNodeWithSplit(range[1], editedAt);
      const [fromLeft, fromRight] = this.findNodeWithSplit(range[0], editedAt);

      // 02. delete between from and to
      const nodesToDelete = this.findBetween(fromRight, toRight);
      const [changes, latestCreatedAtMap, removedNodeMapByNodeKey] =
        this.deleteNodes(nodesToDelete, editedAt, latestCreatedAtMapByActor);

      const caretID = toRight ? toRight.getID() : toLeft.getID();
      let caretPos = RGATreeSplitNodePos.of(caretID, 0);

      // 03. insert a new node
      if (value) {
        const idx = this.findIdxFromNodePos(fromLeft.createRange()[1], true);

        const inserted = this.insertAfter(
          fromLeft,
          RGATreeSplitNode.create(RGATreeSplitNodeID.of(editedAt, 0), value),
        );

        if (changes.length && changes[changes.length - 1].from === idx) {
          changes[changes.length - 1].content = value.toString();
        } else {
          changes.push({
            type: TextChangeType.Content,
            actor: editedAt.getActorID()!,
            from: idx,
            to: idx,
            content: value.toString(),
          });
        }

        caretPos = RGATreeSplitNodePos.of(
          inserted.getID(),
          inserted.getContentLength(),
        );
      }

      // 04. add removed node
      for (const [key, removedNode] of removedNodeMapByNodeKey) {
        this.removedNodeMap.set(key, removedNode);
      }

      return [caretPos, latestCreatedAtMap, changes];
    }

    /**
     * `findNodePos` finds RGATreeSplitNodePos of given offset.
     */
    public findNodePos(idx: number): RGATreeSplitNodePos {
      const [node, offset] = this.treeByIndex.find(idx);
      const splitNode = node as RGATreeSplitNode<T>;
      return RGATreeSplitNodePos.of(splitNode.getID(), offset);
    }

    /**
     * `findIndexesFromRange` finds indexes based on range.
     */
    public findIndexesFromRange(range: RGATreeSplitNodeRange): [number, number] {
      const [fromPos, toPos] = range;
      return [
        this.findIdxFromNodePos(fromPos, false),
        this.findIdxFromNodePos(toPos, true),
      ];
    }

    /**
     * `findIdxFromNodePos` finds index based on node position.
     */
    public findIdxFromNodePos(
      pos: RGATreeSplitNodePos,
      preferToLeft: boolean,
    ): number {
      const absoluteID = pos.getAbsoluteID();
      const node = preferToLeft
        ? this.findFloorNodePreferToLeft(absoluteID)
        : this.findFloorNode(absoluteID);
      if (!node) {
        logger.fatal(
          `the node of the given id should be found: ${absoluteID.getStructureAsString()}`,
        );
      }
      const index = this.treeByIndex.indexOf(node!);
      const offset = node!.isRemoved()
        ? 0
        : absoluteID.getOffset() - node!.getID().getOffset();
      return index + offset;
    }

    /**
     * `findNode` finds node of given id.
     */
    public findNode(id: RGATreeSplitNodeID): RGATreeSplitNode<T> {
      return this.findFloorNode(id)!;
    }

    /**
     * `length` returns size of RGATreeList.
     */
    public get length(): number {
      return this.treeByIndex.length;
    }

    /**
     * `checkWeight` returns false when there is an incorrect weight node.
     * for debugging purpose.
     */
    public checkWeight(): boolean {
      return this.treeByIndex.checkWeight();
    }

    /**
     * `toJSON` returns the JSON encoding of this Array.
     */
    public toJSON(): string {
      const json = [];

      for (const node of this) {
        if (!node.isRemoved()) {
          json.push(node.getValue());
        }
      }

      return json.join('');
    }

    // eslint-disable-next-line jsdoc/require-jsdoc
    public *[Symbol.iterator](): IterableIterator<RGATreeSplitNode<T>> {
      let node = this.head.getNext();
      while (node) {
        yield node;
        node = node.getNext();
      }
    }

    /**
     * `getHead` returns head of RGATreeSplitNode.
     */
    public getHead(): RGATreeSplitNode<T> {
      return this.head;
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    public deepcopy(): RGATreeSplit<T> {
      const clone = new RGATreeSplit<T>();

      let node = this.head.getNext();

      let prev = clone.head;
      let current;
      while (node) {
        current = clone.insertAfter(prev, node.deepcopy());
        if (node.hasInsPrev()) {
          const insPrevNode = clone.findNode(node.getInsPrevID());
          current.setInsPrev(insPrevNode);
        }

        prev = current;
        node = node.getNext();
      }

      return clone;
    }

    /**
     * `getStructureAsString` returns a String containing the meta data of the node
     * for debugging purpose.
     */
    public getStructureAsString(): string {
      const result = [];

      let node: RGATreeSplitNode<T> | undefined = this.head;
      while (node) {
        if (node.isRemoved()) {
          result.push(`{${node.getStructureAsString()}}`);
        } else {
          result.push(`[${node.getStructureAsString()}]`);
        }

        node = node.getNext();
      }

      return result.join('');
    }

    /**
     * `insertAfter` inserts the given node after the given previous node.
     */
    public insertAfter(
      prevNode: RGATreeSplitNode<T>,
      newNode: RGATreeSplitNode<T>,
    ): RGATreeSplitNode<T> {
      const next = prevNode.getNext();
      newNode.setPrev(prevNode);
      if (next) {
        next.setPrev(newNode);
      }

      this.treeByID.put(newNode.getID(), newNode);
      this.treeByIndex.insertAfter(prevNode, newNode);

      return newNode;
    }

    /**
     * `findNodeWithSplit` splits and return nodes of the given position.
     */
    public findNodeWithSplit(
      pos: RGATreeSplitNodePos,
      editedAt: TimeTicket,
    ): [RGATreeSplitNode<T>, RGATreeSplitNode<T>] {
      const absoluteID = pos.getAbsoluteID();
      let node = this.findFloorNodePreferToLeft(absoluteID);
      const relativeOffset = absoluteID.getOffset() - node.getID().getOffset();

      this.splitNode(node, relativeOffset);

      while (node.hasNext() && node.getNext()!.getCreatedAt().after(editedAt)) {
        node = node.getNext()!;
      }

      return [node, node.getNext()!];
    }

    private findFloorNodePreferToLeft(
      id: RGATreeSplitNodeID,
    ): RGATreeSplitNode<T> {
      let node = this.findFloorNode(id);
      if (!node) {
        logger.fatal(
          `the node of the given id should be found: ${id.getStructureAsString()}`,
        );
      }

      if (id.getOffset() > 0 && node!.getID().getOffset() == id.getOffset()) {
        // NOTE: InsPrev may not be present due to GC.
        if (!node!.hasInsPrev()) {
          return node!;
        }
        node = node!.getInsPrev();
      }

      return node!;
    }

    private findFloorNode(
      id: RGATreeSplitNodeID,
    ): RGATreeSplitNode<T> | undefined {
      const entry = this.treeByID.floorEntry(id);
      if (!entry) {
        return;
      }

      if (!entry.key.equals(id) && !entry.key.hasSameCreatedAt(id)) {
        return;
      }

      return entry.value;
    }

    /**
     * `findBetween` returns nodes between fromNode and toNode.
     */
    public findBetween(
      fromNode: RGATreeSplitNode<T>,
      toNode: RGATreeSplitNode<T>,
    ): Array<RGATreeSplitNode<T>> {
      const nodes = [];

      let current: RGATreeSplitNode<T> | undefined = fromNode;
      while (current && current !== toNode) {
        nodes.push(current);
        current = current.getNext();
      }

      return nodes;
    }

    private splitNode(
      node: RGATreeSplitNode<T>,
      offset: number,
    ): RGATreeSplitNode<T> | undefined {
      if (offset > node.getContentLength()) {
        logger.fatal('offset should be less than or equal to length');
      }

      if (offset === 0) {
        return node;
      } else if (offset === node.getContentLength()) {
        return node.getNext();
      }

      const splitNode = node.split(offset);
      this.treeByIndex.updateWeight(splitNode);
      this.insertAfter(node, splitNode);

      const insNext = node.getInsNext();
      if (insNext) {
        insNext.setInsPrev(splitNode);
      }
      splitNode.setInsPrev(node);

      return splitNode;
    }

    private deleteNodes(
      candidates: Array<RGATreeSplitNode<T>>,
      editedAt: TimeTicket,
      latestCreatedAtMapByActor?: Map<string, TimeTicket>,
    ): [
      Array<TextChange>,
      Map<string, TimeTicket>,
      Map<string, RGATreeSplitNode<T>>,
    ] {
      if (!candidates.length) {
        return [[], new Map(), new Map()];
      }

      // There are 2 types of nodes in `candidates`: should delete, should not delete.
      // `nodesToKeep` contains nodes should not delete,
      // then is used to find the boundary of the range to be deleted.
      const [nodesToDelete, nodesToKeep] = this.filterNodes(
        candidates,
        editedAt,
        latestCreatedAtMapByActor,
      );

      const createdAtMapByActor = new Map();
      const removedNodeMap = new Map();
      // First we need to collect indexes for change.
      const changes = this.makeChanges(nodesToKeep, editedAt);
      for (const node of nodesToDelete) {
        // Then make nodes be tombstones and map that.
        const actorID = node.getCreatedAt().getActorID();
        if (
          !createdAtMapByActor.has(actorID) ||
          node.getID().getCreatedAt().after(createdAtMapByActor.get(actorID))
        ) {
          createdAtMapByActor.set(actorID, node.getID().getCreatedAt());
        }
        removedNodeMap.set(node.getID().getStructureAsString(), node);
        node.remove(editedAt);
      }
      // Finally remove index nodes of tombstones.
      this.deleteIndexNodes(nodesToKeep);

      return [changes, createdAtMapByActor, removedNodeMap];
    }

    private filterNodes(
      candidates: Array<RGATreeSplitNode<T>>,
      editedAt: TimeTicket,
      latestCreatedAtMapByActor?: Map<string, TimeTicket>,
    ): [Array<RGATreeSplitNode<T>>, Array<RGATreeSplitNode<T> | undefined>] {
      const isRemote = !!latestCreatedAtMapByActor;
      const nodesToDelete: Array<RGATreeSplitNode<T>> = [];
      const nodesToKeep: Array<RGATreeSplitNode<T> | undefined> = [];

      const [leftEdge, rightEdge] = this.findEdgesOfCandidates(candidates);
      nodesToKeep.push(leftEdge);

      for (const node of candidates) {
        const actorID = node.getCreatedAt().getActorID();

        const latestCreatedAt = isRemote
          ? latestCreatedAtMapByActor!.has(actorID!)
            ? latestCreatedAtMapByActor!.get(actorID!)
            : InitialTimeTicket
          : MaxTimeTicket;

        if (node.canDelete(editedAt, latestCreatedAt!)) {
          nodesToDelete.push(node);
        } else {
          nodesToKeep.push(node);
        }
      }
      nodesToKeep.push(rightEdge);

      return [nodesToDelete, nodesToKeep];
    }

    /**
     * `findEdgesOfCandidates` finds the edges outside `candidates`,
     * (which has not already been deleted, or be undefined but not yet implemented)
     * right edge is undefined means `candidates` contains the end of text.
     */
    private findEdgesOfCandidates(
      candidates: Array<RGATreeSplitNode<T>>,
    ): [RGATreeSplitNode<T>, RGATreeSplitNode<T> | undefined] {
      return [
        candidates[0].getPrev()!,
        candidates[candidates.length - 1].getNext(),
      ];
    }

    private makeChanges(
      boundaries: Array<RGATreeSplitNode<T> | undefined>,
      editedAt: TimeTicket,
    ): Array<TextChange> {
      const changes: Array<TextChange> = [];
      let fromIdx: number, toIdx: number;

      for (let i = 0; i < boundaries.length - 1; i++) {
        const leftBoundary = boundaries[i];
        const rightBoundary = boundaries[i + 1];

        if (leftBoundary!.getNext() == rightBoundary) {
          continue;
        }

        [fromIdx] = this.findIndexesFromRange(
          leftBoundary!.getNext()!.createRange(),
        );
        if (rightBoundary) {
          [, toIdx] = this.findIndexesFromRange(
            rightBoundary.getPrev()!.createRange(),
          );
        } else {
          toIdx = this.treeByIndex.length;
        }

        if (fromIdx < toIdx) {
          changes.push({
            type: TextChangeType.Content,
            actor: editedAt.getActorID()!,
            from: fromIdx,
            to: toIdx,
          });
        }
      }

      return changes.reverse();
    }

    /**
     * `deleteIndexNodes` clears the index nodes of the given deletion boundaries.
     * The boundaries mean the nodes that will not be deleted in the range.
     */
    private deleteIndexNodes(
      boundaries: Array<RGATreeSplitNode<T> | undefined>,
    ): void {
      for (let i = 0; i < boundaries.length - 1; i++) {
        const leftBoundary = boundaries[i];
        const rightBoundary = boundaries[i + 1];
        // If there is no node to delete between boundaries, do notting.
        if (leftBoundary!.getNext() != rightBoundary) {
          this.treeByIndex.deleteRange(leftBoundary!, rightBoundary);
        }
      }
    }

    /**
     * `getRemovedNodesLen` returns size of removed nodes.
     */
    public getRemovedNodesLen(): number {
      return this.removedNodeMap.size;
    }

    /**
     * `purgeTextNodesWithGarbage` physically purges nodes that have been removed.
     */
    public purgeTextNodesWithGarbage(ticket: TimeTicket): number {
      let count = 0;
      for (const [, node] of this.removedNodeMap) {
        if (node.getRemovedAt() && ticket.compare(node.getRemovedAt()!) >= 0) {
          this.treeByIndex.delete(node);
          this.purge(node);
          this.treeByID.remove(node.getID());
          this.removedNodeMap.delete(node.getID().getStructureAsString());
          count++;
        }
      }

      return count;
    }

    /**
     * `purge` physically purges the given node from RGATreeSplit.
     */
    public purge(node: RGATreeSplitNode<T>): void {
      const prev = node.getPrev();
      const next = node.getNext();
      const insPrev = node.getInsPrev();
      const insNext = node.getInsNext();

      if (prev) {
        prev.setNext(next);
      }
      if (next) {
        next.setPrev(prev);
      }

      node.setPrev(undefined);
      node.setNext(undefined);

      if (insPrev) {
        insPrev.setInsNext(insNext);
      }

      if (insNext) {
        insNext.setInsPrev(insPrev);
      }

      node.setInsPrev(undefined);
      node.setInsNext(undefined);
    }
  }

  /**
   * `Selection` represents the selection of text range in the editor.
   */
  export class Selection {
    private from: RGATreeSplitNodePos;
    private to: RGATreeSplitNodePos;
    private updatedAt: TimeTicket;

    constructor(
      from: RGATreeSplitNodePos,
      to: RGATreeSplitNodePos,
      updatedAt: TimeTicket,
    ) {
      this.from = from;
      this.to = to;
      this.updatedAt = updatedAt;
    }

    /**
     * `of` creates a new instance of Selection.
     */
    public static of(
      range: RGATreeSplitNodeRange,
      updatedAt: TimeTicket,
    ): Selection {
      return new Selection(range[0], range[1], updatedAt);
    }

    /**
     * `getUpdatedAt` returns update time of this selection.
     */
    public getUpdatedAt(): TimeTicket {
      return this.updatedAt;
    }
*/
}
