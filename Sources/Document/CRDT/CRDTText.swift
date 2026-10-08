/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

import Combine
import Foundation

class TextChange {
    /**
     * `TextChangeType` is the type of TextChange.
     */
    enum TextChangeType {
        case content
        case style
    }

    let type: TextChangeType
    let actor: ActorID
    let from: Int
    let to: Int
    var content: String?
    var attributes: Codable?

    init(type: TextChangeType, actor: ActorID, from: Int, to: Int, content: String? = nil, attributes: Codable? = nil) {
        self.type = type
        self.actor = actor
        self.from = from
        self.to = to
        self.content = content
        self.attributes = attributes
    }
}

/**
 * `CRDTTextValue` is a value of Text
 * which has a attributes that expresses the text style.
 * Attributes are represented by RHT.
 *
 */
public final class CRDTTextValue: RGATreeSplitValue, CustomStringConvertible {
    required convenience init() {
        self.init("", RHT())
    }

    private var attributes: RHT
    /**
     * `content` returns content.
     */
    private(set) var content: NSString

    init(_ content: String, _ attributes: RHT = RHT()) {
        self.attributes = attributes
        self.content = content as NSString
    }

    /**
     * `length` returns the length of content.
     */
    public var count: Int {
        return self.content.length
    }

    /**
     * `substring` returns a sub-string value of the given range.
     */
    public func substring(from indexStart: Int, to indexEnd: Int) -> CRDTTextValue {
        let value = CRDTTextValue(self.content.substring(with: NSRange(location: indexStart, length: indexEnd - indexStart)), self.attributes.deepcopy())
        return value
    }

    /**
     * `truncate` shortens this value in place, keeping the object identity so
     * that GC pairs registered against it are not orphaned. See
     * ``RGATreeSplitValue/truncate(_:)``.
     */
    func truncate(_ offset: Int) {
        self.content = self.content.substring(to: offset) as NSString
    }

    /**
     * `setAttr` sets attribute of the given key, updated time and value.
     */
    @discardableResult
    func setAttr(key: String, value: String, updatedAt: TimeTicket) -> RHTWrite {
        self.attributes.set(key: key, value: value, executedAt: updatedAt)
    }

    /**
     * `toString` returns content.
     */
    public var toString: String {
        self.content as String
    }

    /**
     * `getDataSize` returns the data usage of this value.
     */
    func getDataSize() -> DataSize {
        var dataSize = DataSize(
            data: content.length * 2,
            meta: 0
        )
        // A removed attribute belongs to docSize.gc, not to live.
        // `CRDTTreeNode.getDataSize` makes the same exclusion; the two halves
        // have to answer this the same way or a document's size stops being a
        // function of its content.
        for node in self.attributes where !node.isRemoved {
            let size = node.getDataSize()
            dataSize.data += size.data
            dataSize.meta += size.meta
        }
        return dataSize
    }

    /**
     * `toJSON` returns the JSON encoding of this .
     */
    public var toJSON: String {
        let attrs = self.attributes.toObject()

        var attrsString = ""

        if attrs.isEmpty == false {
            var data = [String]()

            for (key, value) in attrs.sorted(by: { $0.key < $1.key }) {
                // A peer that stores values raw writes ones that do not parse as
                // JSON; quote those as strings rather than emitting invalid JSON.
                // A non-string is re-encoded, never interpolated, and the key
                // is escaped: a peer-chosen attribute must not be able to forge
                // structure in `Document.toJSON`.
                let parsed = value.value.toJSONObject
                let encoded = parsed is String ? convertToJSONString(logicalAttrValue(value.value)) : convertToJSONString(parsed)
                data.append("\(convertToJSONString(key)):\(encoded)")
            }

            attrsString = "\"attrs\":{\(data.joined(separator: ","))},"
        }

        let valString = self.toString.escaped()

        if attrsString.isEmpty && valString.isEmpty {
            return ""
        } else {
            return "{\(attrsString)\"val\":\"\(valString)\"}"
        }
    }

    /**
     * `getAttributes` returns the attributes of this value.
     */
    public func getAttributes() -> [String: (value: String, updatedAt: TimeTicket)] {
        self.attributes.toObject()
    }

    func getAttrs() -> RHT {
        return self.attributes
    }

    public var description: String {
        self.content as String
    }

    /**
     * `getGCPairs` returns the pairs of GC.
     *
     * Also satisfies `RGATreeSplitValue.getGCPairs`, through which
     * `RGATreeSplit.bookCopiedAttrTombstones` reaches this value's tombstoned
     * attributes whenever a split or a restore duplicates them into a copy.
     */
    func getGCPairs() -> [GCPair] {
        var pairs = [GCPair]()

        // `getDataSize` skips removed attributes, so a tombstoned attribute is
        // not part of the live size this root was built with. Registering it
        // without `gcOnlySize` would debit live for bytes it never held.
        for node in self.attributes where node.removedAt != nil {
            pairs.append(GCPair(parent: self, child: node, gcOnlySize: node.getDataSize()))
        }

        return pairs
    }
}

extension CRDTTextValue: GCParent {
    func purge(node: any GCChild) {
        if let node = node as? RHTNode {
            self.attributes.purge(node)
        }
    }
}

final class CRDTText: CRDTElement {
    /**
     * `getDataSize` returns the data usage of this element.
     */
    func getDataSize() -> DataSize {
        var data = 0
        var meta = self.getMetaUsage()

        // The sentinel head is skipped. `rga_tree_split.ts` starts its iterator at
        // `head.getNext()`, so the JS SDK never counts it; iOS's iterator yields it, and
        // counting its `createdAt` made an empty Text measure one `timeTicketSize` larger
        // here than in the JS SDK. The iterator itself is left alone -- the edit paths read
        // the head through it.
        for node in self.rgaTreeSplit where node !== self.rgaTreeSplit.head && node.isRemoved == false {
            let size = node.getDataSize()
            data += size.data
            meta += size.meta
        }
        return DataSize(
            data: data,
            meta: meta
        )
    }

    typealias TextVal = (attributes: Codable, content: String)

    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    /**
     * `rgaTreeSplit` returns rgaTreeSplit.
     *
     **/
    private(set) var rgaTreeSplit: RGATreeSplit<CRDTTextValue>
    private var remoteChangeLock: Bool

    init(rgaTreeSplit: RGATreeSplit<CRDTTextValue>, createdAt: TimeTicket) {
        self.rgaTreeSplit = rgaTreeSplit
        self.remoteChangeLock = false
        self.createdAt = createdAt
    }

    /**
     * `edit` edits the given range with the given content and attributes.
     */
    @discardableResult
    func edit(
        _ range: RGATreeSplitPosRange,
        _ content: String,
        _ editedAt: TimeTicket,
        _ attributes: [String: String]? = nil,
        _ versionVector: VersionVector? = nil
    ) throws -> ([TextChange], [GCPair], DataSize, RGATreeSplitPosRange, [CRDTTextValue], [RestoreSpan<CRDTTextValue>]) {
        let value = !content.isEmpty ? CRDTTextValue(content) : nil
        if !content.isEmpty, let attributes {
            for (key, jsonValue) in attributes {
                value?.setAttr(key: key, value: jsonValue, updatedAt: editedAt)
            }
        }

        let (caretPos, pairs, diff, contentChanges, removedValues, removedSpans) = try self.rgaTreeSplit.edit(
            range,
            editedAt,
            value,
            versionVector
        )

        let changes = contentChanges.compactMap { TextChange(type: .content, actor: $0.actor, from: $0.from, to: $0.to, content: $0.content?.toString) }

        if !content.isEmpty, let attributes {
            if let change = changes[safe: changes.count - 1] {
                change.attributes = attributes
            }
        }

        return (changes, pairs, diff, (caretPos, caretPos), removedValues, removedSpans)
    }

    /**
     * `restore` re-establishes removed characters under their original
     * identities (identity-preserving undo of a deletion).
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
        _ spans: [RestoreSpan<CRDTTextValue>],
        _ executedAt: TimeTicket,
        _ fallbackAnchor: RGATreeSplitPos? = nil
    ) throws -> ([RGATreeSplitNode<CRDTTextValue>], [RGATreeSplitNode<CRDTTextValue>], [TextChange], DataSize, [GCPair]) {
        let (untombstoned, recreated, contentChanges, liveDiff, pendingGCPairs) = try self.rgaTreeSplit.restore(
            spans,
            executedAt,
            fallbackAnchor
        )

        return (untombstoned, recreated, self.toTextChanges(contentChanges), liveDiff, pendingGCPairs)
    }

    /**
     * `retombstone` re-deletes previously restored characters (redo).
     *
     * - Parameters:
     *   - spans: The identity-addressed runs to re-remove.
     *   - executedAt: The timestamp of the operation performing the removal.
     * - Returns: The GC pairs, resulting changes, and the live-bucket size delta.
     */
    func retombstone(
        _ spans: [RestoreSpan<CRDTTextValue>],
        _ executedAt: TimeTicket
    ) throws -> ([GCPair], [TextChange], DataSize) {
        let (pairs, contentChanges, diff) = try self.rgaTreeSplit.retombstone(spans, executedAt)

        return (pairs, self.toTextChanges(contentChanges), diff)
    }

    /**
     * `toTextChanges` wraps raw RGATreeSplit content changes into `TextChange`s,
     * mirroring the mapping used by `edit`.
     */
    private func toTextChanges(_ contentChanges: [ContentChange<CRDTTextValue>]) -> [TextChange] {
        contentChanges.compactMap {
            // Carry the revived node's attributes, not just its content: an editor
            // binding driven by these changes must re-insert restored text with its
            // original styling, otherwise the view diverges from the CRDT.
            let attributes = $0.content?.getAttributes().mapValues { $0.value }

            return TextChange(
                type: .content,
                actor: $0.actor,
                from: $0.from,
                to: $0.to,
                content: $0.content?.toString,
                attributes: (attributes?.isEmpty ?? true) ? nil : attributes
            )
        }
    }

    /**
     * `refinePos` remaps the given position to the current split chain.
     */
    func refinePos(_ pos: RGATreeSplitPos) throws -> RGATreeSplitPos {
        try self.rgaTreeSplit.refinePos(pos)
    }

    /**
     * `normalizePos` converts the given position into a single absolute offset from the head.
     */
    func normalizePos(_ pos: RGATreeSplitPos) throws -> RGATreeSplitPos {
        try self.rgaTreeSplit.normalizePos(pos)
    }

    /**
     * `posToIndex` converts the given position to an index.
     */
    func posToIndex(_ pos: RGATreeSplitPos, _ preferToLeft: Bool = false) throws -> Int {
        try self.rgaTreeSplit.posToIndex(pos, preferToLeft)
    }

    /**
     * `setStyle` applies the style of the given range.
     * 01. split nodes with from and to
     * 02. style nodes between from and to
     *
     * @param range - range of RGATreeSplitNode
     * @param attributes - style attributes
     * @param editedAt - edited time
     */
    @discardableResult
    func setStyle(
        _ range: RGATreeSplitPosRange,
        _ attributes: [String: String],
        _ editedAt: TimeTicket,
        _ versionVector: VersionVector? = nil
    ) throws -> ([GCPair], DocSize, [TextChange], [String: String], [String]) {
        var size = DocSize(live: DataSize(data: 0, meta: 0), gc: DataSize(data: 0, meta: 0))
        // 01. split nodes with from and to
        let (_, diffTo, toRight) = try self.rgaTreeSplit.findNodeWithSplit(range.1, editedAt)
        let (_, diffFrom, fromRight) = try self.rgaTreeSplit.findNodeWithSplit(range.0, editedAt)

        size.live.addDataSizes(others: diffTo, diffFrom)

        // 02. style nodes between from and to
        var changes = [TextChange]()
        let nodes = self.rgaTreeSplit.findBetween(fromRight, toRight)
        var toBeStyleds = [RGATreeSplitNode<CRDTTextValue>]()
        for node in nodes where node.canStyle(versionVector) {
            toBeStyleds.append(node)
        }

        // Capture previous attribute values from the first styled node for reverse op.
        var prevAttributes = [String: String]()
        var attributesToRemove = [String]()
        var capturedPrev = false

        // The reverse operation restores what the VISIBLE text held, so the prior
        // values come from the first LIVE node in the range. `canStyle` admits
        // tombstones, and the first node in the range can be one -- capturing
        // from it made an undo write an attribute onto text that never carried
        // it. The fallback to the first node keeps an all-tombstone range
        // undoable.
        let captureFrom = toBeStyleds.first { !$0.isRemoved } ?? toBeStyleds.first

        var pairs = [GCPair]()
        for node in toBeStyleds {
            // `canStyle` admits a node removed CONCURRENTLY with this style, which
            // has to be styled for the replicas to agree. It is not part of the
            // rendered text, though, so it reports no change to editors and its
            // bytes move through gc rather than live.
            let nodeIsLive = !node.isRemoved

            if !capturedPrev, node === captureFrom {
                let attrs = node.value.getAttrs()
                for key in attributes.keys {
                    if attrs.has(key: key) {
                        if let value = try? attrs.get(key: key) {
                            prevAttributes[key] = value
                        }
                    } else {
                        attributesToRemove.append(key)
                    }
                }
                capturedPrev = true
            }

            if nodeIsLive {
                let (fromIdx, toIdx) = try self.rgaTreeSplit.findIndexesFromRange(node.createPosRange)
                changes.append(TextChange(type: .style,
                                          actor: editedAt.actorID,
                                          from: fromIdx,
                                          to: toIdx,
                                          content: nil,
                                          attributes: attributes))
            }

            for (key, jsonValue) in attributes {
                accAttrWrite(node.value.setAttr(key: key, value: jsonValue, updatedAt: editedAt),
                             node.value,
                             nodeIsLive,
                             &pairs,
                             &size)
            }
        }

        pairs.append(contentsOf: self.rgaTreeSplit.drainPendingGCPairs())

        return (pairs, size, changes, prevAttributes, attributesToRemove)
    }

    /**
     * `removeStyle` removes the style attributes of the given range.
     *
     * Returns previous attribute values (from the first styled node) for the reverse operation.
     */
    @discardableResult
    func removeStyle(
        _ range: RGATreeSplitPosRange,
        _ attributesToRemove: [String],
        _ editedAt: TimeTicket,
        _ versionVector: VersionVector? = nil
    ) throws -> ([GCPair], DocSize, [TextChange], [String: String]) {
        var size = DocSize(live: DataSize(data: 0, meta: 0), gc: DataSize(data: 0, meta: 0))
        // 01. split nodes with from and to
        let (_, diffTo, toRight) = try self.rgaTreeSplit.findNodeWithSplit(range.1, editedAt)
        let (_, diffFrom, fromRight) = try self.rgaTreeSplit.findNodeWithSplit(range.0, editedAt)

        size.live.addDataSizes(others: diffTo, diffFrom)

        // 02. find nodes to remove style from
        var changes = [TextChange]()
        let nodes = self.rgaTreeSplit.findBetween(fromRight, toRight)
        var toBeStyleds = [RGATreeSplitNode<CRDTTextValue>]()
        for node in nodes where node.canStyle(versionVector) {
            toBeStyleds.append(node)
        }

        // Capture previous attribute values from the first styled node for reverse op.
        var prevAttributes = [String: String]()
        var capturedPrev = false

        // See setStyle: the prior values come from the first LIVE node.
        let captureFrom = toBeStyleds.first { !$0.isRemoved } ?? toBeStyleds.first

        var pairs = [GCPair]()
        for node in toBeStyleds {
            // See setStyle: a node removed concurrently with this change is
            // styled but is not part of the rendered text.
            let nodeIsLive = !node.isRemoved

            if !capturedPrev, node === captureFrom {
                let attrs = node.value.getAttrs()
                for key in attributesToRemove where attrs.has(key: key) {
                    if let value = try? attrs.get(key: key) {
                        prevAttributes[key] = value
                    }
                }
                capturedPrev = true
            }

            if nodeIsLive {
                let (fromIdx, toIdx) = try self.rgaTreeSplit.findIndexesFromRange(node.createPosRange)

                // `nil` per key signals attribute removal to editors (e.g. Quill).
                var removedAttributes = [String: String?]()
                for key in attributesToRemove {
                    removedAttributes.updateValue(nil, forKey: key)
                }
                changes.append(TextChange(type: .style,
                                          actor: editedAt.actorID,
                                          from: fromIdx,
                                          to: toIdx,
                                          content: nil,
                                          attributes: removedAttributes))
            }

            for key in attributesToRemove {
                // `canStyle` admits a node removed concurrently with this change,
                // so the NODE holding the attribute may itself be a tombstone --
                // the third case `attrGCPair` asks about.
                var attrWasLive = node.value.getAttrs().has(key: key)
                let removal = node.value.getAttrs().remove(key: key, executedAt: editedAt)
                applyValueDropped(removal, nodeIsLive: nodeIsLive, to: &size)

                for rhtNode in removal.gcNodes {
                    pairs.append(attrGCPair(node.value, rhtNode, attrWasLive, nodeIsLive))
                    // Only the node that replaces the live value settles the live
                    // value's bytes; a second one in the same call is the
                    // tombstone it superseded, which was never in live.
                    attrWasLive = false
                }
            }
        }

        pairs.append(contentsOf: self.rgaTreeSplit.drainPendingGCPairs())

        return (pairs, size, changes, prevAttributes)
    }

    /**
     * `hasRemoteChangeLock` checks whether remoteChangeLock has.
     */
    var hasRemoteChangeLock: Bool {
        self.remoteChangeLock
    }

    /**
     * `indexRangeToPosRange` returns the position range of the given index range.
     */
    func indexRangeToPosRange(_ fromIdx: Int, _ toIdx: Int) throws -> RGATreeSplitPosRange {
        let fromPos = try self.rgaTreeSplit.indexToPos(fromIdx)
        if fromIdx == toIdx {
            return (fromPos, fromPos)
        }

        return try (fromPos, self.rgaTreeSplit.indexToPos(toIdx))
    }

    /**
     * `createRange` returns the position range of the given index range for a local edit or
     * style. Unlike ``indexRangeToPosRange(_:_:)``, it rejects an index that splits a UTF-16
     * surrogate pair.
     *
     * `content` is given for an edit and omitted for a style. It is checked for lone
     * surrogates: storing one diverges across SDKs on its own, and the half then pairs with
     * whatever code unit it is stored next to, which would turn the index at that seam into
     * one `validateUTF16Boundary` refuses for the lifetime of the text. A peer running an SDK
     * without this check can still send such content -- the guard is a local-edit contract,
     * not a trust boundary -- but nothing a client of this SDK does can create it.
     */
    func createRange(_ fromIdx: Int, _ toIdx: Int, _ content: String? = nil) throws -> RGATreeSplitPosRange {
        if let content, !content.isEmpty {
            try ensureNoLoneSurrogate(content)
        }

        let range = try self.indexRangeToPosRange(fromIdx, toIdx)
        try self.validateUTF16Boundary(range.0)
        if fromIdx != toIdx {
            try self.validateUTF16Boundary(range.1)
        }

        return range
    }

    /**
     * `indexedContent` returns the text the given node contributes to the index: empty for a
     * tombstone, whose text the index no longer counts (and empty for the head node, which
     * never holds content).
     */
    private func indexedContent(_ node: RGATreeSplitNode<CRDTTextValue>) -> NSString {
        node.isRemoved ? "" : node.value.content
    }

    /**
     * `neighborContent` returns the content of the nearest node on the given side that still
     * contributes text, or an empty string when there is none.
     */
    private func neighborContent(
        _ node: RGATreeSplitNode<CRDTTextValue>,
        _ step: (RGATreeSplitNode<CRDTTextValue>) -> RGATreeSplitNode<CRDTTextValue>?
    ) -> NSString {
        var current = step(node)
        while let candidate = current {
            let content = self.indexedContent(candidate)
            if content.length > 0 {
                return content
            }
            current = step(candidate)
        }

        return ""
    }

    /**
     * `validateUTF16Boundary` throws when the given position splits a surrogate pair. At
     * either end of the node it reads the neighbouring node: an edit or a style carrying a
     * mid-pair offset splits the node there, so a pair can sit in two nodes on this replica
     * while it is one node on every other, and an index at that seam is still inside it.
     * ``RGATreeSplit/indexToPos(_:)`` resolves a seam to the node on its left, so the
     * `offset == content.length` side is the one an index normally reaches.
     */
    private func validateUTF16Boundary(_ pos: RGATreeSplitPos) throws {
        guard let node = self.rgaTreeSplit.findNode(pos.id) else {
            return
        }

        let offset = Int(pos.relativeOffset)
        let content = self.indexedContent(node)

        var before: unichar? = (offset - 1 >= 0 && offset - 1 < content.length) ? content.character(at: offset - 1) : nil
        var after: unichar? = (offset >= 0 && offset < content.length) ? content.character(at: offset) : nil
        if offset == 0 {
            let prevContent = self.neighborContent(node) { $0.prev }
            before = prevContent.length > 0 ? prevContent.character(at: prevContent.length - 1) : nil
        }
        if offset == content.length {
            let nextContent = self.neighborContent(node) { $0.next }
            after = nextContent.length > 0 ? nextContent.character(at: 0) : nil
        }

        try ensureUTF16Boundary(before, after)
    }

    /**
     * `length` returns size of RGATreeList.
     */
    var length: Int {
        self.rgaTreeSplit.length
    }

    /**
     * `getTreeByIndex` returns the tree by index for debugging.
     */
    func getTreeByIndex() -> SplayTree<CRDTTextValue> {
        return self.rgaTreeSplit.getTreeByIndex()
    }

    /**
     * `getTreeByID` returns the tree by ID for debugging.
     */
    func getTreeByID() -> LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<CRDTTextValue>> {
        return self.rgaTreeSplit.getTreeByID()
    }

    /**
     * `toJSON` returns the JSON encoding of this rich text.
     */
    func toJSON() -> String {
        var json = [String]()

        for item in self.rgaTreeSplit where !item.isRemoved {
            let nodeValue = item.value.toJSON
            if nodeValue.isEmpty == false {
                json.append(nodeValue)
            }
        }

        return "[\(json.joined(separator: ","))]"
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this rich text.
     */
    func toSortedJSON() -> String {
        self.toJSON()
    }

    /**
     * `toTestString` returns a String containing the meta data of this value
     * for debugging purpose.
     */
    var toTestString: String {
        self.rgaTreeSplit.toTestString
    }

    var toString: String {
        self.rgaTreeSplit.compactMap { $0.isRemoved ? nil : $0.value.toString }.joined(separator: "")
    }

    var values: [CRDTTextValue]? {
        self.rgaTreeSplit.compactMap { $0.isRemoved ? nil : $0.value }
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    func deepcopy() -> CRDTElement {
        let text = CRDTText(rgaTreeSplit: self.rgaTreeSplit.deepcopy(), createdAt: self.createdAt)
        text.remove(self.removedAt)
        // `movedAt` has to survive the copy, as it does in `text.ts`. It is what
        // `getPositionedAt()` reports, which `ElementRHT.set` now resolves LWW on, and it is
        // charged to the element's meta size -- so dropping it lets a clone resolve a
        // concurrent set differently from the root and measure smaller than it.
        text.setMovedAt(self.movedAt)
        return text
    }

    /**
     * `findIndexesFromRange` returns pair of integer offsets of the given range.
     */
    func findIndexesFromRange(_ range: RGATreeSplitPosRange) throws -> (Int, Int) {
        try self.rgaTreeSplit.findIndexesFromRange(range)
    }
}

extension CRDTText: CRDTGCPairContainable {
    /**
     * `getGCPairs` returns the pairs of GC.
     */
    func getGCPairs() -> [GCPair] {
        var pairs = [GCPair]()
        // NOTE: Only called when a root is built from a snapshot, where
        // docSize.live counted visible nodes only. Tombstoned nodes (and the
        // attribute tombstones inside them) were never part of live, so their
        // pairs carry `gcOnlySize`. So do the attribute tombstones of visible
        // nodes: `CRDTTextValue.getDataSize` skips removed attributes, matching
        // the tree half, so those bytes are not in live either.
        for node in self.rgaTreeSplit {
            let isRemoved = node.removedAt != nil
            if isRemoved {
                pairs.append(GCPair(parent: self.rgaTreeSplit, child: node, gcOnlySize: node.getDataSize()))
            }

            for pair in node.value.getGCPairs() {
                if isRemoved {
                    pairs.append(GCPair(parent: pair.parent, child: pair.child, gcOnlySize: pair.child?.getDataSize()))
                } else {
                    pairs.append(pair)
                }
            }
        }

        return pairs
    }
}
