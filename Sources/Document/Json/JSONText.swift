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
    public func edit(_ fromIdx: Int, _ toIdx: Int, _ content: String, _ attributes: TextAttributes? = nil) -> Bool {
        guard let context, let text else {
            Logger.critical("it is not initialized yet")
            return false
        }

        if fromIdx > toIdx {
            Logger.critical("from should be less than or equal to to")
            return false
        }

        guard let range = try? text.createRange(fromIdx, toIdx) else {
            Logger.critical("can't create range")
            return false
        }

        Logger.debug("EDIT: f:\(fromIdx)->\(range.0.structureAsString), t:\(toIdx)->\(range.1.structureAsString) c:\(content)")

        let ticket = context.issueTimeTicket()
        guard let maxCreatedAtMapByActor = try? text.edit(range, content, ticket, attributes) else {
            Logger.critical("can't edit Text")
            return false
        }

        context.push(
            operation: EditOperation(parentCreatedAt: text.createdAt,
                                     fromPos: range.0,
                                     toPos: range.1,
                                     maxCreatedAtMapByActor: maxCreatedAtMapByActor,
                                     content: content,
                                     attributes: attributes != nil ? stringifyAttributes(attributes!) : nil,
                                     executedAt: ticket)
        )

        if range.0 != range.1 {
            context.registerRemovedNodeTextElement(text)
        }

        return true
    }

    /**
     * `setStyle` styles this text with the given attributes.
     */
    @discardableResult
    public func setStyle(fromIdx: Int, toIdx: Int, attributes: TextAttributes) -> Bool {
        guard let context, let text else {
            Logger.critical("it is not initialized yet")
            return false
        }

        if fromIdx > toIdx {
            Logger.critical("from should be less than or equal to to")
            return false
        }

        guard let range = try? text.createRange(fromIdx, toIdx) else {
            Logger.critical("can't create range")
            return false
        }

        Logger.debug("STYL: f:\(fromIdx)->\(range.0.structureAsString), t:\(toIdx)->\(range.1.structureAsString) a:\(attributes)")

        let ticket = context.issueTimeTicket()
        do {
            try text.setStyle(range, attributes, ticket)
        } catch {
            Logger.critical("can't set Style")
            return false
        }

        context.push(operation: StyleOperation(parentCreatedAt: text.createdAt,
                                               fromPos: range.0,
                                               toPos: range.1,
                                               attributes: stringifyAttributes(attributes),
                                               executedAt: ticket))

        return true
    }

    /**
     * `select` selects the given range.
     */
    @discardableResult
    public func select(_ fromIdx: Int, _ toIdx: Int) -> Bool {
        guard let context, let text else {
            Logger.critical("it is not initialized yet")
            return false
        }

        guard let range = try? text.createRange(fromIdx, toIdx) else {
            Logger.critical("can't create range")
            return false
        }

        Logger.debug("SELT: f:\(fromIdx)->\(range.0.structureAsString), t:\(toIdx)->\(range.1.structureAsString)")

        let ticket = context.issueTimeTicket()
        do {
            try text.select(range, ticket)
        } catch {
            Logger.critical("\(error.localizedDescription)")
            return false
        }

        context.push(operation: SelectOperation(parentCreatedAt: text.createdAt, fromPos: range.0, toPos: range.1, executedAt: ticket))

        return true
    }

    /**
     * `structureAsString` returns a String containing the meta data of the node
     * for debugging purpose.
     */
    public var structureAsString: String {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return ""
        }

        return text.structureAsString
    }

    public var plainText: String {
        self.text?.plainText ?? ""
    }

    /**
     * `values` returns values of this text.
     */
    public var values: [TextValue]? {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return nil
        }

        return text.values
    }

    /**
     * `setEventStream` registers a event Stream of TextChange events.
     */
    public func setEventStream(eventStream: PassthroughSubject<[TextChange], Never>?) {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return
        }
        text.eventStream = eventStream
    }

    /**
     * `createRange` returns pair of RGATreeSplitNodePos of the given integer offsets.
     */
    func createRange(_ fromIdx: Int, _ toIdx: Int) -> RGATreeSplitNodeRange? {
        guard self.context != nil, let text else {
            Logger.critical("it is not initialized yet")
            return nil
        }

        return try? text.createRange(fromIdx, toIdx)
    }
}
