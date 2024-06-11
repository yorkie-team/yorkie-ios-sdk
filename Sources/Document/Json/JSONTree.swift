/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

public protocol JSONTreeNode: Equatable {
    var type: TreeNodeType { get }
    var toJSONString: String { get }
}

struct TreeChangeWithPath {
    let actor: ActorID
    let type: TreeChangeType
    let from: [Int]
    let to: [Int]
    let fromPath: [Int]
    let toPath: [Int]
    let value: TreeChangeValue?
}

extension CRDTTreeNode {
    var toJSONTreeNode: any JSONTreeNode {
        if self.isText {
            return JSONTreeTextNode(value: self.value)
        } else {
            var attrs = [String: Any]()
            self.attrs?.forEach {
                attrs[$0.key] = $0.value.toJSONObject
            }

            return JSONTreeElementNode(type: self.type,
                                       children: self.children.compactMap { $0.toJSONTreeNode }, attributes: attrs)
        }
    }
}

/**
 * `ElementNode` is a node that has children.
 */
public struct JSONTreeElementNode: JSONTreeNode {
    public let type: TreeNodeType
    public let attributes: [String: String]
    public let children: [any JSONTreeNode]

    public static func == (lhs: JSONTreeElementNode, rhs: JSONTreeElementNode) -> Bool {
        if lhs.type != rhs.type {
            return false
        }

        if !(lhs.attributes == rhs.attributes) {
            return false
        }

        if lhs.children.count != rhs.children.count {
            return false
        }

        for (index, leftChild) in lhs.children.enumerated() {
            if let leftChild = leftChild as? JSONTreeElementNode, let rightChild = rhs.children[index] as? JSONTreeElementNode {
                return leftChild == rightChild
            } else if let leftChild = leftChild as? JSONTreeTextNode, let rightChild = rhs.children[index] as? JSONTreeTextNode {
                return leftChild == rightChild
            } else {
                return false
            }
        }

        return true
    }

    public init(type: TreeNodeType, children: [any JSONTreeNode] = [], attributes: [String: Any] = [:]) {
        self.type = type
        self.attributes = attributes.stringValueTypeDictionary
        self.children = children
    }

    public init(type: TreeNodeType, children: [any JSONTreeNode] = [], attributes: Codable) {
        self.type = type
        self.attributes = StringValueTypeDictionary.stringifyAttributes(attributes)
        self.children = children
    }

    public var toJSONString: String {
        var childrenString = ""
        if self.children.isEmpty == false {
            childrenString = self.children.compactMap { $0.toJSONString }.joined(separator: ",")
        }

        var resultString = "{\"type\":\(self.type.toJSONString),\"children\":[\(childrenString)]"

        if self.attributes.isEmpty == false {
            let sortedKeys = self.attributes.keys.sorted()

            let attrsString = sortedKeys.compactMap { key in
                if let value = self.attributes[key] {
                    let object = value.toJSONObject

                    if object is [String: Any] {
                        return "\(key.toJSONString):\(value)"
                    } else {
                        return "\(key.toJSONString):\(convertToJSONString(object))"
                    }
                } else {
                    return "\(key.toJSONString):null"
                }
            }.joined(separator: ",")

            resultString += ",\"attributes\":{\(attrsString)}"
        }

        resultString += "}"

        return resultString
    }
}

/**
 * `TextNode` is a node that has a value.
 */
public struct JSONTreeTextNode: JSONTreeNode {
    public let type = DefaultTreeNodeType.text.rawValue
    public let value: NSString

    public init(value: String) {
        self.value = value as NSString
    }

    public init(value: NSString) {
        self.value = value
    }

    public var toJSONString: String {
        return "{\"type\":\(self.type.toJSONString),\"value\":\((self.value as String).toJSONString)}"
    }
}

/**
 * `buildDescendants` builds descendants of the given tree node.
 */
func buildDescendants(treeNode: any JSONTreeNode, parent: CRDTTreeNode, context: ChangeContext) throws {
    let ticket = context.issueTimeTicket

    if let node = treeNode as? JSONTreeTextNode {
        try validateTextNode(node)

        let textNode = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticket, offset: 0), type: DefaultTreeNodeType.text.rawValue, value: node.value)

        try parent.append(contentsOf: [textNode])
    } else if let node = treeNode as? JSONTreeElementNode {
        let attrs = RHT()

        for (key, value) in node.attributes {
            attrs.set(key: key, value: value, executedAt: ticket)
        }

        let elementNode = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticket, offset: 0), type: node.type, attributes: attrs.size == 0 ? nil : attrs)

        try parent.append(contentsOf: [elementNode])

        for child in node.children {
            try buildDescendants(treeNode: child, parent: elementNode, context: context)
        }
    } else {
        preconditionFailure("Must not here!")
    }
}

/**
 * createCRDTTreeNode returns CRDTTreeNode by given TreeNode.
 */
func createCRDTTreeNode(context: ChangeContext, content: any JSONTreeNode) throws -> CRDTTreeNode {
    let ticket = context.issueTimeTicket

    let root: CRDTTreeNode
    if let node = content as? JSONTreeTextNode {
        root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticket, offset: 0), type: node.type, value: node.value)
    } else if let node = content as? JSONTreeElementNode {
        let attrs = RHT()

        for (key, value) in node.attributes {
            attrs.set(key: key, value: value, executedAt: ticket)
        }

        root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticket, offset: 0), type: node.type, attributes: attrs.size == 0 ? nil : attrs)

        for child in node.children {
            try buildDescendants(treeNode: child, parent: root, context: context)
        }
    } else {
        preconditionFailure("Must not here!")
    }

    return root
}

/**
 * `validateTextNode` ensures that a text node has a non-empty string value.
 */
func validateTextNode(_ textNode: JSONTreeTextNode) throws {
    if textNode.value.length == 0 {
        throw YorkieError.unexpected(message: "text node cannot have empty value")
    }
}

/**
 * `validateTreeNodes` ensures that treeNodes consists of only one type.
 */
func validateTreeNodes(_ treeNodes: [any JSONTreeNode]) throws {
    if treeNodes.isEmpty {
        return
    }

    if treeNodes[0] is JSONTreeTextNode {
        for node in treeNodes {
            if let node = node as? JSONTreeTextNode {
                try validateTextNode(node)
            } else {
                throw YorkieError.unexpected(message: "element node and text node cannot be passed together")
            }
        }
    } else {
        if treeNodes.first(where: { !($0 is JSONTreeElementNode) }) != nil {
            throw YorkieError.unexpected(message: "element node and text node cannot be passed together")
        }
    }
}

/**
 * `JSONTree` is a CRDT-based tree structure that is used to represent the document
 * tree of text-based editor such as ProseMirror.
 */
public class JSONTree {
    private let initialRoot: JSONTreeElementNode?
    private var context: ChangeContext?
    private var tree: CRDTTree?

    public init(initialRoot: JSONTreeElementNode? = nil) {
        self.initialRoot = initialRoot
    }

    /**
     * `initialize` initialize this text with context and internal text.
     */
    func initialize(context: ChangeContext?, tree: CRDTTree?) {
        self.context = context
        self.tree = tree
    }

    func deepcopy() -> JSONTree {
        let clone = JSONTree(initialRoot: self.initialRoot)

        clone.context = self.context?.deepcopy()
        clone.tree = self.tree?.deepcopy() as? CRDTTree

        return clone
    }

    /**
     * `id` returns the ID of this tree.
     */
    public var id: TimeTicket? {
        self.tree?.id
    }

    /**
     * `buildRoot` returns the root node of this tree.
     */
    func buildRoot(_ context: ChangeContext) throws -> CRDTTreeNode {
        guard let initialRoot else {
            return CRDTTreeNode(id: CRDTTreeNodeID(createdAt: context.issueTimeTicket, offset: 0), type: DefaultTreeNodeType.root.rawValue)
        }

        // TODO(hackerwins): Need to use the ticket of operation of creating tree.
        let root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: context.issueTimeTicket, offset: 0), type: initialRoot.type)

        try self.initialRoot?.children.forEach { child in
            try buildDescendants(treeNode: child, parent: root, context: context)
        }

        return root
    }

    /**
     * `getSize` returns the size of this tree.
     */
    public func getSize() throws -> Int {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.size
    }

    /**
     * `getNodeSize` returns the node size of this tree.
     */
    public func getNodeSize() throws -> Int {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.nodeSize
    }

    /**
     * `getIndexTree` returns the index tree of this tree.
     */
    func getIndexTree() throws -> IndexTree<CRDTTreeNode> {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.indexTree
    }

    /**
     * `styleByPath` sets the attributes to the elements of the given path.
     */
    public func styleByPath(_ path: [Int], _ attributes: Codable) throws {
        try self.styleByPathInternal(path, StringValueTypeDictionary.stringifyAttributes(attributes))
    }

    public func styleByPath(_ path: [Int], _ attributes: [String: Any]) throws {
        try self.styleByPathInternal(path, attributes.stringValueTypeDictionary)
    }

    public func styleByPathInternal(_ path: [Int], _ stringAttrs: [String: String]) throws {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if path.isEmpty {
            throw YorkieError.unexpected(message: "path should not be empty")
        }

        let (fromPos, toPos) = try tree.pathToPosRange(path)

        try self.styleInternal(fromPos, toPos, stringAttrs)
    }

    /**
     * `style` sets the attributes to the elements of the given range.
     */
    public func style(_ fromIdx: Int, _ toIdx: Int, _ attributes: Codable) throws {
        try self.styleByIndexInternal(fromIdx, toIdx, StringValueTypeDictionary.stringifyAttributes(attributes))
    }

    public func style(_ fromIdx: Int, _ toIdx: Int, _ attributes: [String: Any]) throws {
        try self.styleByIndexInternal(fromIdx, toIdx, attributes.stringValueTypeDictionary)
    }

    func styleByIndexInternal(_ fromIdx: Int, _ toIdx: Int, _ stringAttrs: [String: String]) throws {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let fromPos = try tree.findPos(fromIdx)
        let toPos = try tree.findPos(toIdx)

        try self.styleInternal(fromPos, toPos, stringAttrs)
    }

    func styleInternal(_ fromPos: CRDTTreePos, _ toPos: CRDTTreePos, _ stringAttrs: [String: String]) throws {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let ticket = context.issueTimeTicket

        let (maxCreationMapByActor, pairs, _) = try tree.style((fromPos, toPos), stringAttrs, ticket)

        context.push(operation: TreeStyleOperation(parentCreatedAt: tree.createdAt,
                                                   fromPos: fromPos,
                                                   toPos: toPos,
                                                   maxCreatedAtMapByActor: maxCreationMapByActor,
                                                   attributes: stringAttrs,
                                                   attributesToRemove: [],
                                                   executedAt: ticket)
        )

        for pair in pairs {
            self.context?.registerGCPair(pair)
        }
    }

    /**
     * `remoteStyleByPath` removes the attributes to the elements of the given path.
     */
    public func removeStyleByPath(_ path: [Int], _ attributesToRemove: [String]) throws {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if path.isEmpty {
            throw YorkieError.unexpected(message: "path should not be empty")
        }

        let (fromPos, toPos) = try tree.pathToPosRange(path)

        try self.removeStyleInternal(fromPos, toPos, attributesToRemove)
    }

    /**
     * `removeStyle` removes the attributes to the elements of the given range.
     */
    public func removeStyle(_ fromIdx: Int, _ toIdx: Int, _ attributesToRemove: [String]) throws {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let fromPos = try tree.findPos(fromIdx)
        let toPos = try tree.findPos(toIdx)

        try self.removeStyleInternal(fromPos, toPos, attributesToRemove)
    }

    private func removeStyleInternal(_ fromPos: CRDTTreePos, _ toPos: CRDTTreePos, _ attributesToRemove: [String]) throws {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let ticket = context.issueTimeTicket

        let (maxCreationMapByActor, pairs, _) = try tree.removeStyle((fromPos, toPos), attributesToRemove, ticket)

        for pair in pairs {
            self.context?.registerGCPair(pair)
        }

        context.push(operation: TreeStyleOperation(parentCreatedAt: tree.createdAt,
                                                   fromPos: fromPos,
                                                   toPos: toPos,
                                                   maxCreatedAtMapByActor: maxCreationMapByActor,
                                                   attributes: [:],
                                                   attributesToRemove: attributesToRemove,
                                                   executedAt: ticket)
        )
    }

    private func editInternal(_ fromPos: CRDTTreePos, _ toPos: CRDTTreePos, _ contents: [any JSONTreeNode]?, _ splitLevel: Int32 = 0) throws -> Bool {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if let contents, contents.isEmpty == false {
            try validateTreeNodes(contents)

            if contents[0] is JSONTreeElementNode {
                for content in contents {
                    if let content = content as? JSONTreeElementNode {
                        try validateTreeNodes(content.children)
                    }
                }
            }
        }

        let ticket = context.lastTimeTicket
        let crdtNodes: [CRDTTreeNode]?

        if let contents = contents as? [JSONTreeTextNode] {
            var compVal = ""
            for content in contents {
                compVal += content.value as String
            }

            crdtNodes = try [createCRDTTreeNode(context: context, content: JSONTreeTextNode(value: compVal))]
        } else {
            crdtNodes = try contents?.compactMap { try createCRDTTreeNode(context: context, content: $0) }
        }

        let (_, pairs, maxCreatedAtMapByActor) = try tree.edit((fromPos, toPos), crdtNodes?.compactMap { $0.deepcopy() }, splitLevel, ticket) {
            context.issueTimeTicket
        }

        for pair in pairs {
            self.context?.registerGCPair(pair)
        }

        context.push(operation: TreeEditOperation(parentCreatedAt: tree.createdAt,
                                                  fromPos: fromPos,
                                                  toPos: toPos,
                                                  contents: crdtNodes,
                                                  splitLevel: splitLevel,
                                                  executedAt: ticket,
                                                  maxCreatedAtMapByActor: maxCreatedAtMapByActor)
        )

        return true
    }

    /**
     * `editByPath` edits this tree with the given node and path.
     */
    @discardableResult
    public func editByPath(_ fromPath: [Int], _ toPath: [Int], _ content: (any JSONTreeNode)? = nil, _ splitLevel: Int32 = 0) throws -> Bool {
        try self.editBulkByPath(fromPath, toPath, content != nil ? [content!] : nil, splitLevel)
    }

    /**
     * `editBulkByPath` edits this tree with the given node and path.
     */
    @discardableResult
    public func editBulkByPath(_ fromPath: [Int], _ toPath: [Int], _ contents: [any JSONTreeNode]? = nil, _ splitLevel: Int32 = 0) throws -> Bool {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromPath.count != toPath.count {
            throw YorkieError.unexpected(message: "path length should be equal")
        }

        if fromPath.isEmpty || toPath.isEmpty {
            throw YorkieError.unexpected(message: "path should not be empty")
        }

        let fromPos = try tree.pathToPos(fromPath)
        let toPos = try tree.pathToPos(toPath)

        return try self.editInternal(fromPos, toPos, contents, splitLevel)
    }

    /**
     * `edit` edits this tree with the given node.
     */
    @discardableResult
    public func edit(_ fromIdx: Int, _ toIdx: Int, _ content: (any JSONTreeNode)? = nil, _ splitLevel: Int32 = 0) throws -> Bool {
        try self.editBulk(fromIdx, toIdx, content != nil ? [content!] : nil, splitLevel)
    }

    /**
     * `editBulk` edits this tree with the given node.
     */
    @discardableResult
    public func editBulk(_ fromIdx: Int, _ toIdx: Int, _ contents: [any JSONTreeNode]? = nil, _ splitLevel: Int32 = 0) throws -> Bool {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let fromPos = try tree.findPos(fromIdx)
        let toPos = try tree.findPos(toIdx)

        return try self.editInternal(fromPos, toPos, contents != nil ? contents! : nil, splitLevel)
    }

    /**
     * `toXML` returns the XML string of this tree.
     */
    public func toXML() -> String {
        guard self.context != nil, let tree else {
            Logger.critical("it is not initialized yet")
            return ""
        }

        return tree.toXML()
    }

    /**
     * `toJSON` returns the JSON string of this tree.
     */
    public func toJSON() -> String {
        guard self.context != nil, let tree else {
            Logger.critical("it is not initialized yet")
            return ""
        }

        return tree.toJSON()
    }

    /**
     * `getRootTreeNode` returns JSONTreeNode of this tree.
     */
    public func getRootTreeNode() throws -> (any JSONTreeNode)? {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.root.toJSONTreeNode
    }

    /**
     * `indexToPath` returns the path of the given index.
     */
    public func indexToPath(_ index: Int) throws -> [Int] {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.indexToPath(index)
    }

    /**
     * `pathToIndex` returns the index of given path.
     */
    public func pathToIndex(_ path: [Int]) throws -> Int {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.pathToIndex(path)
    }

    /**
     * `pathRangeToPosRange` converts the path range into the position range.
     */
    public func pathRangeToPosRange(_ range: ([Int], [Int])) throws -> TreePosStructRange {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let indexRange = try (tree.pathToIndex(range.0), tree.pathToIndex(range.1))
        let posRange = try tree.indexRangeToPosRange(indexRange)

        return (posRange.0.toStruct, posRange.1.toStruct)
    }

    /**
     * `indexRangeToPosRange` converts the index range into the position range.
     */
    public func indexRangeToPosRange(_ range: (Int, Int)) throws -> TreePosStructRange {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.indexRangeToPosStructRange(range)
    }

    /**
     * `posRangeToIndexRange` converts the position range into the index range.
     */
    public func posRangeToIndexRange(_ range: TreePosStructRange) throws -> (Int, Int) {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let posRange = try (CRDTTreePos.fromStruct(range.0), CRDTTreePos.fromStruct(range.1))

        return try tree.posRangeToIndexRange(posRange)
    }

    /**
     * `posRangeToPathRange` converts the position range into the path range.
     */
    public func posRangeToPathRange(_ range: TreePosStructRange) throws -> ([Int], [Int]) {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let posRange = try (CRDTTreePos.fromStruct(range.0), CRDTTreePos.fromStruct(range.1))

        return try tree.posRangeToPathRange(posRange)
    }
}

// MARK: For Presence

/**
 * `TimeTicketStruct` is a structure represents the meta data of the ticket.
 * It is used to serialize and deserialize the ticket.
 */
struct TimeTicketStruct: Codable {
    let lamport: String
    let delimiter: UInt32
    let actorID: ActorID
}

/**
 * `TreeRangeStruct` represents the structure of TreeRange.
 * It is used to serialize and deserialize the TreeRange.
 */
typealias TreeRangeStruct = (CRDTTreePosStruct, CRDTTreePosStruct)

extension TimeTicket {
    /**
     * `fromStruct` creates a new instance of TimeTicket from the given struct.
     */
    static func fromStruct(_ value: TimeTicketStruct) throws -> TimeTicket {
        guard let lamport = Int64(value.lamport) else {
            throw YorkieError.unexpected(message: "Lamport is not a valid string representing Int64")
        }

        return TimeTicket(lamport: lamport, delimiter: value.delimiter, actorID: value.actorID)
    }

    /**
     * `toStruct` returns the structure of this Ticket.
     */
    var toStruct: TimeTicketStruct {
        TimeTicketStruct(lamport: String(self.lamport), delimiter: self.delimiter, actorID: self.actorID)
    }
}
