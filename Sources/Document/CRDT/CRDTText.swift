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

public typealias TextAttributes = Codable

/**
 * `stringifyAttributes` makes values of attributes to JSON parsable string.
 */
func stringifyAttributes(_ attributes: TextAttributes) -> [String: String] {
    guard let jsonData = try? JSONEncoder().encode(attributes),
          let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: .fragmentsAllowed) as? [String: Any]
    else {
        return [:]
    }

    return jsonObject.mapValues {
        if let result = try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) {
            return String(data: result, encoding: .utf8) ?? ""
        } else {
            return ""
        }
    }
}

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
    public var attributes: TextAttributes?

    init(type: TextChangeType, actor: ActorID, from: Int, to: Int, content: String? = nil, attributes: TextAttributes? = nil) {
        self.type = type
        self.actor = actor
        self.from = from
        self.to = to
        self.content = content
        self.attributes = attributes
    }
}

/**
 * `TextValue` is a value of Text
 * which has a attributes that expresses the text style.
 */
public final class TextValue: RGATreeSplitValue, CustomStringConvertible {
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
    public func substring(from indexStart: Int, to indexEnd: Int) -> TextValue {
        let value = TextValue(self.content.substring(with: NSRange(location: indexStart, length: indexEnd - indexStart)), self.attributes.deepcopy())
        return value
    }

    /**
     * `setAttr` sets attribute of the given key, updated time and value.
     */
    public func setAttr(key: String, value: String, updatedAt: TimeTicket) {
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
        let attrs = self.attributes.toJSON()
        let attrsString = attrs.isEmpty ? "" : "\"attrs\":\(self.attributes.toJSON()),"
        let valString = self.toString.escaped()

        if attrs.isEmpty && valString.isEmpty {
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
}

final class CRDTText: CRDTGCElement {
    public typealias TextVal = (attributes: TextAttributes, content: String)

    var createdAt: TimeTicket
    var movedAt: TimeTicket?
    var removedAt: TimeTicket?

    /**
     * `rgaTreeSplit` returns rgaTreeSplit.
     *
     **/
    private(set) var rgaTreeSplit: RGATreeSplit<TextValue>
    private var remoteChangeLock: Bool

    init(rgaTreeSplit: RGATreeSplit<TextValue>, createdAt: TimeTicket) {
        self.rgaTreeSplit = rgaTreeSplit
        self.remoteChangeLock = false
        self.createdAt = createdAt
    }

    /**
     * `edit` edits the given range with the given content and attributes.
     */
    @discardableResult
    func edit(_ range: RGATreeSplitPosRange,
              _ content: String,
              _ editedAt: TimeTicket,
              _ attributes: [String: String]? = nil,
              _ latestCreatedAtMapByActor: [String: TimeTicket]? = nil) throws -> ([String: TimeTicket], [TextChange], RGATreeSplitPosRange)
    {
        let value = !content.isEmpty ? TextValue(content) : nil
        if !content.isEmpty, let attributes {
            attributes.forEach { key, jsonValue in
                value?.setAttr(key: key, value: jsonValue, updatedAt: editedAt)
            }
        }

        let (caretPos, latestCreatedAtMap, contentChanges) = try self.rgaTreeSplit.edit(
            range,
            editedAt,
            value,
            latestCreatedAtMapByActor
        )

        let changes = contentChanges.compactMap { TextChange(type: .content, actor: $0.actor, from: $0.from, to: $0.to, content: $0.content?.toString) }

        if !content.isEmpty, let attributes {
            if let change = changes[safe: changes.count - 1] {
                change.attributes = attributes
            }
        }

        return (latestCreatedAtMap, changes, (caretPos, caretPos))
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
    public func setStyle(_ range: RGATreeSplitPosRange,
                         _ attributes: TextAttributes,
                         _ editedAt: TimeTicket) throws
    {
        try self.setStyle(range, stringifyAttributes(attributes), editedAt)
    }

    @discardableResult
    func setStyle(_ range: RGATreeSplitPosRange,
                  _ attributes: [String: String],
                  _ editedAt: TimeTicket) throws -> [TextChange]
    {
        // 01. split nodes with from and to
        let toRight = try self.rgaTreeSplit.findNodeWithSplit(range.1, editedAt).1
        let fromRight = try self.rgaTreeSplit.findNodeWithSplit(range.0, editedAt).1

        // 02. style nodes between from and to
        var changes = [TextChange]()
        let nodes = self.rgaTreeSplit.findBetween(fromRight, toRight)
        for node in nodes {
            if node.isRemoved {
                continue
            }

            let (fromIdx, toIdx) = try self.rgaTreeSplit.findIndexesFromRange(node.createPosRange)
            changes.append(TextChange(type: .style,
                                      actor: editedAt.actorID!,
                                      from: fromIdx,
                                      to: toIdx,
                                      content: nil,
                                      attributes: attributes))

            attributes.forEach { key, jsonValue in
                node.value.setAttr(key: key, value: jsonValue, updatedAt: editedAt)
            }
        }

        return changes
    }

    /**
     * `hasRemoteChangeLock` checks whether remoteChangeLock has.
     */
    public var hasRemoteChangeLock: Bool {
        self.remoteChangeLock
    }

    /**
     * `indexRangeToPosRange` returns the position range of the given index range.
     */
    public func indexRangeToPosRange(_ fromIdx: Int, _ toIdx: Int) throws -> RGATreeSplitPosRange {
        let fromPos = try self.rgaTreeSplit.indexToPos(fromIdx)
        if fromIdx == toIdx {
            return (fromPos, fromPos)
        }

        return try (fromPos, self.rgaTreeSplit.indexToPos(toIdx))
    }

    /**
     * `length` returns size of RGATreeList.
     */
    public var length: Int {
        self.rgaTreeSplit.length
    }

    /**
     * `checkWeight` returns false when there is an incorrect weight node.
     * for debugging purpose.
     */
    public func checkWeight() -> Bool {
        self.rgaTreeSplit.checkWeight()
    }

    /**
     * `toJSON` returns the JSON encoding of this rich text.
     */
    public func toJSON() -> String {
        var json = [String]()

        self.rgaTreeSplit.forEach {
            if !$0.isRemoved {
                let nodeValue = $0.value.toJSON
                if nodeValue.isEmpty == false {
                    json.append(nodeValue)
                }
            }
        }

        return "[\(json.joined(separator: ","))]"
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this rich text.
     */
    public func toSortedJSON() -> String {
        self.toJSON()
    }

    /**
     * `toTestString` returns a String containing the meta data of this value
     * for debugging purpose.
     */
    public var toTestString: String {
        self.rgaTreeSplit.toTestString
    }

    public var plainText: String {
        self.rgaTreeSplit.compactMap { $0.isRemoved ? nil : $0.value.toString }.joined(separator: "")
    }

    public var values: [TextValue]? {
        self.rgaTreeSplit.compactMap { $0.isRemoved ? nil : $0.value }
    }

    /**
     * `removedNodesLen` returns length of removed nodes
     */
    public var removedNodesLength: Int {
        self.rgaTreeSplit.removedNodesLength
    }

    /**
     * `purgeRemovedNodesBefore` purges removed nodes before the given time.
     */
    public func purgeRemovedNodesBefore(ticket: TimeTicket) -> Int {
        self.rgaTreeSplit.purgeRemovedNodesBefore(ticket)
    }

    /**
     * `deepcopy` copies itself deeply.
     */
    public func deepcopy() -> CRDTElement {
        let text = CRDTText(rgaTreeSplit: self.rgaTreeSplit.deepcopy(), createdAt: self.createdAt)
        text.remove(self.removedAt)
        return text
    }

    /**
     * `findIndexesFromRange` returns pair of integer offsets of the given range.
     */
    public func findIndexesFromRange(_ range: RGATreeSplitPosRange) throws -> (Int, Int) {
        try self.rgaTreeSplit.findIndexesFromRange(range)
    }
}
