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

/**
 * `ElementNode` is a node that has children.
 */
public struct JSONTreeElementNode: JSONTreeNode {
    public let type: TreeNodeType
    public let attributes: [String: Any]
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

    public init(type: TreeNodeType, attributes: [String: Any] = [:], children: [any JSONTreeNode] = []) {
        self.type = type
        self.attributes = attributes
        self.children = children
    }
}

/**
 * `TextNode` is a node that has a value.
 */
public struct JSONTreeTextNode: JSONTreeNode {
    public let type = DefaultTreeNodeType.text.rawValue
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/**
 * `buildDescendants` builds descendants of the given tree node.
 */
func buildDescendants(treeNode: any JSONTreeNode, parent: CRDTTreeNode, context: ChangeContext) throws {
    let ticket = context.issueTimeTicket

    if let node = treeNode as? JSONTreeTextNode {
        try validateTextNode(node)

        let textNode = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: DefaultTreeNodeType.text.rawValue, value: node.value)

        try parent.append(contentsOf: [textNode])
    } else if let node = treeNode as? JSONTreeElementNode {
        let attrs = RHT()

        node.attributes.stringValueTypeDictionary.forEach { key, value in
            attrs.set(key: key, value: value, executedAt: ticket)
        }

        let elementNode = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: node.type, attributes: attrs.size == 0 ? nil : attrs)

        try parent.append(contentsOf: [elementNode])

        try node.children.forEach { child in
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
        root = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: node.type, value: node.value)
    } else if let node = content as? JSONTreeElementNode {
        let attrs = RHT()

        node.attributes.stringValueTypeDictionary.forEach { key, value in
            attrs.set(key: key, value: value, executedAt: ticket)
        }

        root = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: node.type, attributes: attrs.size == 0 ? nil : attrs)

        try node.children.forEach { child in
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
    if textNode.value.isEmpty {
        throw YorkieError.unexpected(message: "text node cannot have empty value")
    }
}

/**
 * `validateTreeNodes` ensures that treeNodes consists of only one type.
 */
func validateTreeNodes(_ treeNodes: [any JSONTreeNode]) throws {
    if treeNodes.isEmpty == false {
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
            return CRDTTreeNode(pos: CRDTTreePos(createdAt: context.issueTimeTicket, offset: 0), type: DefaultTreeNodeType.root.rawValue)
        }

        // TODO(hackerwins): Need to use the ticket of operation of creating tree.
        let root = CRDTTreeNode(pos: CRDTTreePos(createdAt: context.issueTimeTicket, offset: 0), type: initialRoot.type)

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
    public func styleByPath(_ path: [Int], _ attributes: [String: Any]) throws {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if path.isEmpty {
            throw YorkieError.unexpected(message: "path should not be empty")
        }

        let (fromPos, toPos) = try tree.pathToPosRange(path)
        let ticket = context.issueTimeTicket

        let stringAttrs = attributes.stringValueTypeDictionary

        try tree.style((fromPos, toPos), stringAttrs, ticket)

        // TreeStyleOperation
        context.push(operation: TreeStyleOperation(parentCreatedAt: tree.createdAt,
                                                   fromPos: fromPos,
                                                   toPos: toPos,
                                                   attributes: stringAttrs,
                                                   executedAt: ticket)
        )
    }

    /**
     * `style` sets the attributes to the elements of the given range.
     */
    public func style(_ fromIdx: Int, _ toIdx: Int, _ attributes: [String: Any]) throws {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let fromPos = try tree.findPos(fromIdx)
        let toPos = try tree.findPos(toIdx)
        let ticket = context.issueTimeTicket

        let stringAttrs = attributes.stringValueTypeDictionary

        try tree.style((fromPos, toPos), stringAttrs, ticket)

        context.push(operation: TreeStyleOperation(parentCreatedAt: tree.createdAt,
                                                   fromPos: fromPos,
                                                   toPos: toPos,
                                                   attributes: stringAttrs,
                                                   executedAt: ticket)
        )
    }

    private func editInternal(_ fromPos: CRDTTreePos, _ toPos: CRDTTreePos, contents: [any JSONTreeNode]?) throws -> Bool {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if let contents, contents.isEmpty == false {
            try validateTreeNodes(contents)

            if let contents = contents as? [JSONTreeElementNode] {
                try contents.forEach {
                    try validateTreeNodes($0.children)
                }
            }
        }

        let ticket = context.lastTimeTicket
        let crdtNodes: [CRDTTreeNode]?

        if let contents = contents as? [JSONTreeTextNode] {
            var compVal = ""
            for content in contents {
                compVal += content.value
            }

            crdtNodes = try [createCRDTTreeNode(context: context, content: JSONTreeTextNode(value: compVal))]
        } else {
            crdtNodes = try contents?.compactMap { try createCRDTTreeNode(context: context, content: $0) }
        }

        try tree.edit((fromPos, toPos), crdtNodes?.compactMap { $0.deepcopy() }, ticket)

        context.push(operation: TreeEditOperation(parentCreatedAt: tree.createdAt,
                                                  fromPos: fromPos,
                                                  toPos: toPos,
                                                  contents: crdtNodes,
                                                  executedAt: ticket)
        )

        if fromPos != toPos {
            context.registerElementHasRemovedNodes(tree)
        }

        return true
    }

    /**
     * `editByPath` edits this tree with the given node and path.
     */
    @discardableResult
    public func editByPath(_ fromPath: [Int], _ toPath: [Int], _ contents: [any JSONTreeNode]?) throws -> Bool {
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

        return try self.editInternal(fromPos, toPos, contents: contents)
    }

    /**
     * `edit` edits this tree with the given node.
     */
    @discardableResult
    public func edit(_ fromIdx: Int, _ toIdx: Int, _ contents: [any JSONTreeNode]? = nil) throws -> Bool {
        guard let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let fromPos = try tree.findPos(fromIdx)
        let toPos = try tree.findPos(toIdx)

        return try self.editInternal(fromPos, toPos, contents: contents)
    }

    /**
     * `split` splits this tree at the given index.
     */
    public func split(_ index: Int, _ depth: Int) throws -> Bool {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        try tree.split(index, depth)
        return true
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
     * `createRange` returns pair of CRDTTreePos of the given integer offsets.
     */
    func createRange(_ fromIdx: Int, _ toIdx: Int) throws -> TreeRange? {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.createRange(fromIdx, toIdx)
    }

    /**
     * `createRangeByPath` returns pair of CRDTTreePos of the given integer offsets.
     */
    func createRangeByPath(_ fromPath: [Int], _ toPath: [Int]) throws -> TreeRange? {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let fromIdx = try tree.pathToIndex(fromPath)
        let toIdx = try tree.pathToIndex(toPath)

        return try tree.createRange(fromIdx, toIdx)
    }

    /**
     * `toPosRange` converts the integer index range into the Tree position range structure.
     */
    func toPosRange(_ range: (Int, Int)) throws -> TreeRangeStruct {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let range = try tree.toPosRange(range)

        return (range.0.toStructure, range.1.toStructure)
    }

    /**
     * `toIndexRange` converts the Tree position range into the integer index range.
     */
    func toIndexRange(_ range: TreeRangeStruct) throws -> (Int, Int) {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.toIndexRange((CRDTTreePos.fromStruct(range.0), CRDTTreePos.fromStruct(range.1)))
    }

    /**
     * `rangeToPath` returns the path of the given range.
     */
    func rangeToPath(_ range: TreeRange) throws -> ([Int], [Int]) {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.rangeToPath(range)
    }
}

extension JSONTree: Sequence {
    public func makeIterator() -> JSONTreeListIterator {
        return JSONTreeListIterator(self.tree)
    }
}

public class JSONTreeListIterator: IteratorProtocol {
    private var treeIterator: CRDTTreeListIterator?

    init(_ firstNode: CRDTTree?) {
        self.treeIterator = firstNode?.makeIterator()
    }

    public func next() -> (any JSONTreeNode)? {
        guard let node = self.treeIterator?.next() else {
            return nil
        }

        return node.toJSONTreeNode
    }
}

// MARK: For Presence

/**
 * `TimeTicketStruct` is a structure represents the meta data of the ticket.
 * It is used to serialize and deserialize the ticket.
 */
struct TimeTicketStruct {
    let lamport: String
    let delimiter: UInt32
    let actorID: ActorID?
}

/**
 * `CRDTTreePosStruct` represents the structure of CRDTTreePos.
 * It is used to serialize and deserialize the CRDTTreePos.
 */
struct CRDTTreePosStruct {
    let createdAt: TimeTicketStruct
    let offset: Int32
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
     * `toStructure` returns the structure of this Ticket.
     */
    var toStructure: TimeTicketStruct {
        TimeTicketStruct(lamport: String(self.lamport), delimiter: self.delimiter, actorID: self.actorID)
    }
}

extension CRDTTreePos {
    /**
     * `fromStruct` creates a new instance of CRDTTreePos from the given struct.
     */
    static func fromStruct(_ value: CRDTTreePosStruct) throws -> CRDTTreePos {
        try CRDTTreePos(createdAt: TimeTicket.fromStruct(value.createdAt), offset: value.offset)
    }

    /**
     * `toStructure` returns the structure of this position.
     */
    var toStructure: CRDTTreePosStruct {
        CRDTTreePosStruct(createdAt: self.createdAt.toStructure, offset: self.offset)
    }
}
