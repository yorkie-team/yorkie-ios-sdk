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
    public enum TextChangeType {
        case content
        case style
    }

    public let type: TextChangeType
    public let actor: ActorID
    public let from: Int
    public let to: Int
    public var content: String?
    public var attributes: Codable?

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
     * `setAttr` sets attribute of the given key, updated time and value.
     */
    @discardableResult
    func setAttr(key: String, value: String, updatedAt: TimeTicket) -> (RHTNode?, RHTNode?) {
        self.attributes.set(key: key, value: value, executedAt: updatedAt)
    }

    /**
     * `toString` returns content.
     */
    public var toString: String {
        self.content as String
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
                if value.value.count > 2, value.value.first == "\"", value.value.last == "\"" {
                    data.append("\"\(key)\":\(value.value)")
                } else {
                    data.append("\"\(key)\":\(value.value)")
                }
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

    public var description: String {
        self.content as String
    }

    /**
     * `getGCPairs` returns the pairs of GC.
     */
    func getGCPairs() -> [GCPair] {
        var pairs = [GCPair]()

        for node in self.attributes where node.removedAt != nil {
            pairs.append(GCPair(parent: self, child: node))
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
    public typealias TextVal = (attributes: Codable, content: String)

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
        _ maxCreatedAtMapByActor: [String: TimeTicket]? = nil,
        _ versionVector: VersionVector? = nil
    ) throws -> ([String: TimeTicket], [TextChange], [GCPair], RGATreeSplitPosRange)
    {
        let value = !content.isEmpty ? CRDTTextValue(content) : nil
        if !content.isEmpty, let attributes {
            for (key, jsonValue) in attributes {
                value?.setAttr(key: key, value: jsonValue, updatedAt: editedAt)
            }
        }

        let (caretPos, maxCreatedAtMap, pairs, contentChanges) = try self.rgaTreeSplit.edit(
            range,
            editedAt,
            value,
            maxCreatedAtMapByActor, versionVector
        )

        let changes = contentChanges.compactMap { TextChange(type: .content, actor: $0.actor, from: $0.from, to: $0.to, content: $0.content?.toString) }

        if !content.isEmpty, let attributes {
            if let change = changes[safe: changes.count - 1] {
                change.attributes = attributes
            }
        }

        return (maxCreatedAtMap, changes, pairs, (caretPos, caretPos))
    }

    /**
     * `setStyle` applies the style of the given range.
     * 01. split nodes with from and to
     * 02. style nodes between from and to
     *
     * @param range - range of RGATreeSplitNode
     * @param attributes - style attributes
     * @param editedAt - edited time
     * @param maxCreatedAtMapByActor - maxCreatedAtMapByActor
     */
    @discardableResult
    func setStyle(
        _ range: RGATreeSplitPosRange,
        _ attributes: [String: String],
        _ editedAt: TimeTicket,
        _ maxCreatedAtMapByActor: [String: TimeTicket]? = [:],
        _ versionVector: VersionVector? = nil
    ) throws -> ([String: TimeTicket], [GCPair], [TextChange])
    {
        // 01. split nodes with from and to
        let toRight = try self.rgaTreeSplit.findNodeWithSplit(range.1, editedAt).1
        let fromRight = try self.rgaTreeSplit.findNodeWithSplit(range.0, editedAt).1

        // 02. style nodes between from and to
        var changes = [TextChange]()
        let nodes = self.rgaTreeSplit.findBetween(fromRight, toRight)
        var createdAtMapByActor = [String: TimeTicket]()
        var toBeStyleds = [RGATreeSplitNode<CRDTTextValue>]()
        for node in nodes {
            let actorID = node.createdAt.actorID

            var maxCreatedAt: TimeTicket?
            var clientLamportAtChange: Int64 = .zero
                
            if versionVector == nil && maxCreatedAtMapByActor == nil {
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

            if node.canStyle(editedAt, maxCreatedAt, clientLamportAtChange: clientLamportAtChange) {
                let maxCreatedAt = createdAtMapByActor[actorID]
                let createdAt = node.createdAt

                if maxCreatedAt == nil || createdAt.after(maxCreatedAt!) {
                    createdAtMapByActor[actorID] = createdAt
                }
                toBeStyleds.append(node)
            }
        }

        var pairs = [GCPair]()
        for node in toBeStyleds {
            if node.isRemoved {
                continue
            }

            let (fromIdx, toIdx) = try self.rgaTreeSplit.findIndexesFromRange(node.createPosRange)
            changes.append(TextChange(type: .style,
                                      actor: editedAt.actorID,
                                      from: fromIdx,
                                      to: toIdx,
                                      content: nil,
                                      attributes: attributes))

            for (key, jsonValue) in attributes {
                let (prev, _) = node.value.setAttr(key: key, value: jsonValue, updatedAt: editedAt)
                if prev != nil {
                    pairs.append(GCPair(parent: node.value, child: prev))
                }
            }
        }

        return (createdAtMapByActor, pairs, changes)
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
        for node in self.rgaTreeSplit {
            if node.removedAt != nil {
                pairs.append(GCPair(parent: self.rgaTreeSplit, child: node))
            }

            for pair in node.value.getGCPairs() {
                pairs.append(pair)
            }
        }

        return pairs
    }
}
