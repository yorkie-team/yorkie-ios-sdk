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

/**
 * `TextPosStruct` represents the structure of RGATreeSplitPos.
 * It is used to serialize and deserialize the RGATreeSplitPos.
 */
public typealias TextPosStruct = RGATreeSplitPosStruct

/**
 * `TextPosStructRange` represents the structure of RGATreeSplitPosRange.
 * It is used to serialize and deserialize the RGATreeSplitPosRange.
 */
public typealias TextPosStructRange = (TextPosStruct, TextPosStruct)

public class JSONText {
    private var context: ChangeContext?
    private var text: CRDTText?

    public convenience init() {
        self.init(context: nil, text: nil)
    }

    init(context: ChangeContext? = nil, text: CRDTText? = nil) {
        self.context = context
        self.text = text
    }

    /**
     * `initialize` initialize this text with context and internal text.
     */
    func initialize(context: ChangeContext, text: CRDTText) {
        self.context = context
        self.text = text
    }

    /**
     * `id` returns the ID of this text.
     */
    public var id: TimeTicket? {
        self.text?.id
    }

    /**
     * `edit` edits this text with the given content.
     */
    @discardableResult
    public func edit(_ fromIdx: Int, _ toIdx: Int, _ content: String, _ attributes: Codable? = nil) -> (Int, Int)? {
        guard let context, let text else {
            Logger.critical("it is not initialized yet")
            return nil
        }

        if fromIdx > toIdx {
            Logger.critical("from should be less than or equal to to")
            return nil
        }

        guard let range = try? text.indexRangeToPosRange(fromIdx, toIdx) else {
            Logger.critical("can't create range")
            return nil
        }

        Logger.debug("EDIT: f:\(fromIdx)->\(range.0.toTestString), t:\(toIdx)->\(range.1.toTestString) c:\(content)")

        let ticket = context.issueTimeTicket

        var attrs: [String: String]?
        if let attributes {
            attrs = StringValueTypeDictionary.stringifyAttributes(attributes)
        }

        guard let (maxCreatedAtMapByActor, _, pairs, rangeAfterEdit) = try? text.edit(range, content, ticket, attrs) else {
            Logger.critical("can't edit Text")
            return nil
        }

        for pair in pairs {
            self.context?.registerGCPair(pair)
        }

        context.push(
            operation: EditOperation(parentCreatedAt: text.createdAt,
                                     fromPos: range.0,
                                     toPos: range.1,
                                     maxCreatedAtMapByActor: maxCreatedAtMapByActor,
                                     content: content,
                                     attributes: attrs,
                                     executedAt: ticket)
        )

        return try? self.text?.findIndexesFromRange(rangeAfterEdit)
    }

    /**
     * `delete` deletes the text in the given range.
     */
    @discardableResult
    public func delete(_ fromIdx: Int, _ toIdx: Int) -> (Int, Int)? {
        self.edit(fromIdx, toIdx, "")
    }

    /**
     * `empty` makes the text empty.
     */
    @discardableResult
    public func empty() -> (Int, Int)? {
        self.edit(0, self.length, "")
    }

    /**
     * `setStyle` styles this text with the given attributes.
     */
    @discardableResult
    public func setStyle(_ fromIdx: Int, _ toIdx: Int, _ attributes: Codable) -> Bool {
        guard let context, let text else {
            Logger.critical("it is not initialized yet")
            return false
        }

        if fromIdx > toIdx {
            Logger.critical("from should be less than or equal to to")
            return false
        }

        guard let range = try? text.indexRangeToPosRange(fromIdx, toIdx) else {
            Logger.critical("can't create range")
            return false
        }

        Logger.debug("STYL: f:\(fromIdx)->\(range.0.toTestString), t:\(toIdx)->\(range.1.toTestString) a:\(attributes)")

        let ticket = context.issueTimeTicket
        let maxCreatedAtMapByActor: [String: TimeTicket]
        let pairs: [GCPair]
        let stringAttrs = StringValueTypeDictionary.stringifyAttributes(attributes)
        do {
            (maxCreatedAtMapByActor, pairs, _) = try text.setStyle(range, stringAttrs, ticket)
        } catch {
            Logger.critical("can't set Style")
            return false
        }

        context.push(operation: StyleOperation(parentCreatedAt: text.createdAt,
                                               fromPos: range.0,
                                               toPos: range.1,
                                               maxCreatedAtMapByActor: maxCreatedAtMapByActor,
                                               attributes: stringAttrs,
                                               executedAt: ticket))

        for pair in pairs {
            self.context?.registerGCPair(pair)
        }

        return true
    }

    /**
     * `indexRangeToPosRange` returns TextPosStructRange of the given index range.
     */
    public func indexRangeToPosRange(_ range: (Int, Int)) throws -> TextPosStructRange {
        guard self.context != nil, let text else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let textRange = try text.indexRangeToPosRange(range.0, range.1)
        return (textRange.0.toStruct, textRange.1.toStruct)
    }

    /**
     * `posRangeToIndexRange` returns indexes of the given TextPosStructRange.
     */
    public func posRangeToIndexRange(_ range: TextPosStructRange) throws -> (Int, Int) {
        guard self.context != nil, let text else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let textRange = try text.findIndexesFromRange((RGATreeSplitPos.fromStruct(range.0), RGATreeSplitPos.fromStruct(range.1)))
        return (textRange.0, textRange.1)
    }

    /**
     * `toTestString` returns a String containing the meta data of the node
     * for debugging purpose.
     */
    public var toTestString: String {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return ""
        }

        return text.toTestString
    }

    /**
     * `toString` returns the string representation of this text.
     */
    public var toString: String {
        self.text?.toString ?? ""
    }

    /**
     * `toSortedJSON` returns the JSON string of this tree.
     */
    public func toSortedJSON() -> String {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return ""
        }

        return text.toSortedJSON()
    }

    /**
     * `values` returns values of this text.
     */
    public var values: [CRDTTextValue]? {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return nil
        }

        return text.values
    }

    /**
     * `length` returns size of RGATreeList.
     */
    public var length: Int {
        self.text?.length ?? 0
    }

    /**
     * `getTreeByIndex` returns the tree by index for debugging.
     */
    func getTreeByIndex() -> SplayTree<CRDTTextValue>? {
        return self.text?.getTreeByIndex()
    }

    /**
     * `getTreeByID` returns the tree by ID for debugging.
     */
    func getTreeByID() -> LLRBTree<RGATreeSplitNodeID, RGATreeSplitNode<CRDTTextValue>>? {
        return self.text?.getTreeByID()
    }

    /**
     * `createRangeForTest` returns pair of RGATreeSplitNodePos of the given indexes
     * for testing purpose.
     */
    func createRangeForTest(_ fromIdx: Int, _ toIdx: Int) -> RGATreeSplitPosRange? {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return nil
        }

        return try? text.indexRangeToPosRange(fromIdx, toIdx)
    }
}
